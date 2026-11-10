// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EpochHall} from "./EpochHall.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PoolCurve, FEE_CEILING} from "./PoolCurve.sol";
import {PoolConfig, Roles, Terms, FeePolicy} from "./PoolTypes.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// The fee desk, as the pool sees it.
interface IFeeDesk {
    function open(FeePolicy calldata f, uint256 feeWad, uint256 cutWad) external returns (uint256 reviewAt);
    function reviewCut(uint256 cutWad, uint256 feeValue, uint256 elapsed, uint256 poolValue)
        external
        view
        returns (uint256 cut, uint256 nextAt, uint256 grossAprWad);
}

/// Says whether an outside reference has been off its peg for long enough.
interface IDepegWatch {
    function depegged() external view returns (bool);
}

/// @title V5Pool
/// @notice A two-token pool whose liquidity is held as seasoned positions
/// (spec v1.16 §3). The curve is weighted for general pairs, or amplified for
/// peg pairs; everything else is the same in both.
///
/// - Swap fees never enter the reserves. The LP share goes to the hall's fee
///   ledger and is paid by seasoned weight; the venue cut is set aside.
/// - There is no fungible LP token. Joining opens a position in the hall.
/// - The swap arithmetic lives in `PoolCurve`, a contract that keeps nothing
///   and that the pool only reads from.
/// - The pool keeps its own record of its price, written by its own swaps,
///   for anything that needs an average nobody else can lean on.
/// - The pool holds the fee terms it charges by and reads them on every swap.
///   The rules they are set by (bounds, delays, the weekly review of the venue
///   cut) live in the `FeeDesk`, the only address that may set them, and the
///   pool refuses any term above its own ceilings whoever asks.
/// - A guardian can pause joins and swaps. A pause never blocks an exit, and
///   during one every exit is free of forfeits and tolls.
///
/// Everything is a setting for now, held by the `configurer`. A change to the
/// hall's settings reaches only positions opened afterwards. Handing the
/// configurer role to the zero address freezes the settings for good.
///
/// First cut, for shaping. Not audited. Known gaps are listed in src/README.md.
contract V5Pool is EpochHall {
    using FixedPointMathLib for uint256;

    address public immutable token0;
    address public immutable token1;
    /// Weights, in WAD, summing to one.
    uint256 public immutable weight0;
    uint256 public immutable weight1;
    /// Amplification for a peg pair. Zero means the weighted curve.
    uint256 public immutable amp;
    /// What each token's amounts are multiplied by to reach 18 decimals. Used by the amplified curve.
    uint256 internal immutable _scale0;
    uint256 internal immutable _scale1;
    /// Where the swap arithmetic is done. Read from, never written to.
    PoolCurve public immutable curve;

    Roles internal _roles;
    Terms internal _terms;

    /// A swap may bring in at most this share of the reserve it adds to.
    uint256 internal constant MAX_IN_RATIO = 0.3e18;
    /// Shares locked for good on the first join, so the pool can never be emptied to a rounding trap.
    uint256 internal constant DEAD_SHARES = 1000;

    uint256[2] public reserves;
    uint256 public totalShares;
    /// Fees inside the hall, not yet paid out: this epoch's, held, and unclaimed.
    uint256[2] public feesInHall;
    uint256[2] public venueOwed;
    uint256[2] public polOwed;

    /// When the venue cut is next reviewed, when it last was, and the gross
    /// fees since then valued in token0.
    struct Review {
        uint64 at;
        uint64 last;
        uint128 feeValue;
    }

    Review public review;

    /// The price record: the natural logarithm of the price, times the
    /// seconds it stood, summed since the pool opened, and the time it runs to.
    struct Record {
        int192 logSum;
        uint64 at;
    }

    Record internal _record;

    bool public paused;
    /// Most of token0 the reserves may hold. Raise-only.
    uint256 public depositCap;

    uint256 private _lock = 1;

    event Joined(uint256 indexed id, address indexed owner, uint256 amount0, uint256 amount1, uint256 shares);
    event Left(uint256 indexed id, address indexed to, uint256 amount0, uint256 amount1, uint256 toll0, uint256 toll1);
    event Swapped(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, uint256 fee);
    event PauseSet(bool paused);
    event CapRaised(uint256 cap);
    event TermsSet(Terms terms);
    event VenueCutSet(uint256 cutWad, uint256 grossAprWad);
    event RolesSet(Roles roles);

    error Paused();
    error Reentered();
    error NotAllowed();
    error UnknownToken();
    error TooLittle();
    error TooMuchIn();
    error OverCap();

    constructor(PoolConfig memory c, Roles memory r, HallConfig memory h, FeePolicy memory f)
        EpochHall(c.epochLength, h)
    {
        if (
            c.token0 == c.token1 || c.token0 == address(0) || c.token1 == address(0) || c.weight0 == 0
                || c.weight0 >= WAD || r.venue == address(0) || r.pol == address(0) || c.curve.code.length == 0
                || r.desk.code.length == 0 || c.feeWad > FEE_CEILING || c.venueCutWad > WAD || f.lockBudgetWad > WAD
        ) revert BadConfig();
        curve = PoolCurve(c.curve);
        token0 = c.token0;
        token1 = c.token1;
        weight0 = c.weight0;
        weight1 = WAD - c.weight0;
        amp = c.amp;
        if (c.amp != 0) {
            uint256 d0 = IDecimals(c.token0).decimals();
            uint256 d1 = IDecimals(c.token1).decimals();
            if (c.weight0 != WAD / 2 || c.amp > 100_000 || d0 > 18 || d1 > 18) revert BadConfig();
            _scale0 = 10 ** (18 - d0);
            _scale1 = 10 ** (18 - d1);
        }
        _roles = r;
        // The desk checks the policy and the opening fee and cut against it.
        uint256 reviewAt = IFeeDesk(r.desk).open(f, c.feeWad, c.venueCutWad);
        _terms = Terms(uint64(c.feeWad), 0, 0, uint64(c.venueCutWad), uint64(f.lockBudgetWad), f.feeModel);
        review = Review(uint64(reviewAt), uint64(block.timestamp), 0);
        depositCap = c.depositCap;
    }

    modifier guarded() {
        if (_lock != 1) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier only(address who) {
        if (msg.sender != who || who == address(0)) revert NotAllowed();
        _;
    }

    function roles() external view returns (Roles memory) {
        return _roles;
    }

    function terms() external view returns (Terms memory) {
        return _terms;
    }

    /// The swap fee in force right now. A change on its way lands by itself.
    function feeWad() public view returns (uint256) {
        Terms storage t = _terms;
        return t.nextFeeAt != 0 && block.timestamp >= t.nextFeeAt ? t.nextFeeWad : t.feeWad;
    }

    /// The venue's share of each fee (WAD).
    function venueCutWad() external view returns (uint256) {
        return _terms.venueCutWad;
    }

    // ------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------

    /// Add liquidity in the pool's current proportions and open a position.
    /// At most `max0` and `max1` are taken. `tier` is 0 (unlocked) or 1 (hard lock).
    function join(uint256 max0, uint256 max1, uint256 minShares, uint8 tier, address to)
        external
        guarded
        returns (uint256 id, uint256 shares)
    {
        if (paused) revert Paused();
        _current();
        uint256 total = totalShares;
        uint256 in0;
        uint256 in1;
        if (total == 0) {
            (in0, in1) = (max0, max1);
            shares = FixedPointMathLib.sqrt(in0 * in1);
            if (shares <= DEAD_SHARES) revert TooLittle();
            shares -= DEAD_SHARES;
            total = DEAD_SHARES;
            _record.at = uint64(block.timestamp); // the price exists from here
        } else {
            uint256 by0 = max0 * total / reserves[0];
            uint256 by1 = max1 * total / reserves[1];
            shares = by0 < by1 ? by0 : by1;
            // Round what is taken up, so a join can never dilute those already in.
            in0 = shares.mulDivUp(reserves[0], total);
            in1 = shares.mulDivUp(reserves[1], total);
        }
        if (shares == 0 || shares < minShares) revert TooLittle();
        if (reserves[0] + in0 > depositCap) revert OverCap();

        reserves[0] += in0;
        reserves[1] += in1;
        totalShares = total + shares;
        id = _open(to, shares, tier);

        SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), in0);
        SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), in1);
        emit Joined(id, to, in0, in1, shares);
    }

    /// Close a position and withdraw its liquidity. Always available, paused or not.
    function exit(uint256 id, uint256 min0, uint256 min1, address to)
        external
        guarded
        returns (uint256 out0, uint256 out1)
    {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _current();
        (, uint256 shares, uint256 toll) = _close(id, paused || _depegged());

        uint256 total = totalShares;
        out0 = (shares - toll) * reserves[0] / total;
        out1 = (shares - toll) * reserves[1] / total;
        // The toll's share of the reserves leaves with the position's shares.
        uint256 toll0 = toll * reserves[0] / total;
        uint256 toll1 = toll * reserves[1] / total;
        if (out0 < min0 || out1 < min1) revert TooLittle();

        reserves[0] -= out0 + toll0;
        reserves[1] -= out1 + toll1;
        totalShares = total - shares;
        _shareOutToll(0, toll0);
        _shareOutToll(1, toll1);

        SafeTransferLib.safeTransfer(token0, to, out0);
        SafeTransferLib.safeTransfer(token1, to, out1);
        emit Left(id, to, out0, out1, toll0, toll1);
    }

    /// A lock's exit toll: a share to protocol-owned liquidity, the rest to the
    /// LPs still locked. If nobody is locked it goes to every LP by weight.
    function _shareOutToll(uint256 k, uint256 amount) private {
        if (amount == 0) return;
        uint256 toPol = amount * _hallConfig.tollPolShareWad / WAD;
        polOwed[k] += toPol;
        uint256 rest = amount - toPol;
        if (!_payLockers(k, rest)) pending[k] += rest;
        feesInHall[k] += rest;
    }

    /// Put a position's unlocked fees back into the pool as liquidity, at the
    /// position's current age. Only fees the hall has released can be used, and
    /// only as much as fits the pool's proportions; the rest stays collectable.
    function compound(uint256 id, uint256 minShares) external guarded returns (uint256 shares) {
        if (paused) revert Paused();
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _current();
        Position storage p = _positions[id];
        uint256[2] memory have = _available(p);

        uint256 total = totalShares;
        uint256 by0 = have[0] * total / reserves[0];
        uint256 by1 = have[1] * total / reserves[1];
        shares = by0 < by1 ? by0 : by1;
        if (shares == 0 || shares < minShares) revert TooLittle();
        uint256 used0 = shares.mulDivUp(reserves[0], total);
        uint256 used1 = shares.mulDivUp(reserves[1], total);

        _spend(p, 0, used0);
        _spend(p, 1, used1);
        feesInHall[0] -= used0;
        feesInHall[1] -= used1;
        reserves[0] += used0;
        reserves[1] += used1;
        totalShares = total + shares;
        _grow(p, shares);
        emit Compounded(id, used0, used1, shares);
    }

    /// Add fees for the LPs from outside: the venue returning part of its cut,
    /// a partner's incentive, anything. They are paid by seasoned weight like any other fee.
    function donate(uint256 amount0, uint256 amount1) external guarded {
        _current();
        pending[0] += amount0;
        pending[1] += amount1;
        feesInHall[0] += amount0;
        feesInHall[1] += amount1;
        if (amount0 != 0) SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), amount0);
        if (amount1 != 0) SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), amount1);
    }

    /// Called by the escrow when it banks part of this pool's venue cut.
    function recordBanked(uint256 amount) external only(_roles.bank) {
        _current();
        _recordBanked(amount);
    }

    /// Collect a position's unlocked fees.
    function collect(uint256 id) external guarded returns (uint256[2] memory) {
        if (ownerOf(id) != msg.sender) revert NotOwner();
        _current();
        return _collect(id);
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------

    /// What `amountIn` of `tokenIn` buys right now. The swap pays exactly this.
    function quote(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        (amountOut,,) = _quote(_index(tokenIn), amountIn);
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        guarded
        returns (uint256 amountOut)
    {
        if (paused) revert Paused();
        _current();
        if (block.timestamp >= review.at) _reviewCut();
        uint256 i = _index(tokenIn);
        uint256 o = 1 - i;
        uint256 fee;
        int256 logPrice;
        (amountOut, fee, logPrice) = _quote(i, amountIn);
        if (amountOut == 0 || amountOut < minOut) revert TooLittle();

        // The price this trade found has stood since the last trade. Write it
        // into the record before moving it. Once a block is enough.
        Record memory rec = _record;
        if (block.timestamp > rec.at) {
            rec.logSum += int192(logPrice * int256(block.timestamp - rec.at));
            rec.at = uint64(block.timestamp);
            _record = rec;
        }

        _takeFee(i, fee);
        reserves[i] += amountIn - fee;
        reserves[o] -= amountOut;

        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(o == 0 ? token0 : token1, to, amountOut);
        emit Swapped(msg.sender, tokenIn, amountIn, amountOut, fee);
    }

    /// Split a fee. It never touches the reserves.
    function _takeFee(uint256 i, uint256 fee) private {
        // Remember what the pool has earned, in token0, for the next review of the cut.
        uint256 value = review.feeValue + (i == 0 ? fee : _inToken0(fee));
        review.feeValue = value > type(uint128).max ? type(uint128).max : uint128(value);

        uint256 toVenue = fee * _terms.venueCutWad / WAD;
        uint256 toLockers = toVenue * _terms.lockBudgetWad / WAD;
        uint256 toLps = fee - toVenue;
        if (toLockers != 0) {
            // Paid to locked LPs if there are any; otherwise to every LP.
            if (!_payLockers(i, toLockers)) toLps += toLockers;
            else feesInHall[i] += toLockers;
            toVenue -= toLockers;
        }
        venueOwed[i] += toVenue;
        pending[i] += toLps;
        feesInHall[i] += toLps;
    }

    /// An amount of token1 valued in token0: at the peg for a peg pair, at the pool's price otherwise.
    function _inToken0(uint256 amount1) private view returns (uint256) {
        if (amp != 0) return amount1 * _scale1 / _scale0;
        return amount1.mulDiv(reserves[0] * weight1, reserves[1] * weight0);
    }

    function _index(address token) private view returns (uint256) {
        if (token == token0) return 0;
        if (token == token1) return 1;
        revert UnknownToken();
    }

    function _shape() private view returns (PoolCurve.Shape memory) {
        return PoolCurve.Shape(weight0, amp, _scale0, _scale1);
    }

    function _quote(uint256 i, uint256 amountIn)
        private
        view
        returns (uint256 amountOut, uint256 fee, int256 logPrice)
    {
        if (amountIn > reserves[i].mulWad(MAX_IN_RATIO)) {
            revert TooMuchIn();
        }
        return curve.quote(_shape(), reserves[0], reserves[1], i, amountIn, feeWad(), _terms.feeModel);
    }

    /// The pool's price now: token1 per token0, scaled by 1e18. A peg pair's
    /// price is in a common 18-decimal scale, so it reads 1e18 at the peg.
    function price() external view returns (uint256 p) {
        (p,) = curve.spot(_shape(), reserves[0], reserves[1]);
    }

    /// The pool's price record, brought up to this moment: the natural
    /// logarithm of the price (token1 per token0, scaled by 1e18) times the
    /// seconds it stood, summed since the pool opened.
    ///
    /// Take two readings some time apart; their difference divided by the
    /// seconds between them is the logarithm of the average price over that
    /// time, and its negative is the logarithm of the average the other way
    /// round. Only the pool's own swaps write the record, each at the price it
    /// found before it traded, so whoever takes the readings chooses when the
    /// average starts and ends and nothing else.
    function logPriceSum() external view returns (int256) {
        Record memory rec = _record;
        if (rec.at == 0) return 0;
        (, int256 logPrice) = curve.spot(_shape(), reserves[0], reserves[1]);
        return rec.logSum + logPrice * int256(block.timestamp - rec.at);
    }

    /// True while the depeg watch, if there is one, reports a depeg. A watch
    /// that fails to answer counts as no depeg; it can never block an exit.
    function _depegged() private view returns (bool) {
        address watch = _roles.depegWatch;
        if (watch == address(0)) return false;
        try IDepegWatch(watch).depegged() returns (bool yes) {
            return yes;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------
    // The fee terms
    // ------------------------------------------------------------------

    /// Set the terms the pool charges by, and when the venue cut is next
    /// reviewed. Only the desk may, and only inside the pool's own ceilings.
    function setTerms(Terms calldata t, uint256 reviewAt) external only(_roles.desk) {
        if (
            t.feeWad > FEE_CEILING || t.nextFeeWad > FEE_CEILING || t.venueCutWad > WAD || t.lockBudgetWad > WAD
                || reviewAt > type(uint64).max
        ) revert BadConfig();
        _terms = t;
        review.at = uint64(reviewAt);
        emit TermsSet(t);
    }

    /// Review the venue cut if a review is due. Anyone may call; swaps do it themselves.
    function reviewCut() external {
        if (block.timestamp >= review.at) _reviewCut();
    }

    /// Ask the desk what the venue cut should be now. A desk that fails to
    /// answer, or answers with more than the whole, changes nothing and is
    /// asked again in a day. It can never stop a swap.
    function _reviewCut() private {
        Review memory rv = review;
        // Both sides are valued in token0.
        uint256 poolValue = amp != 0 ? reserves[0] + _inToken0(reserves[1]) : reserves[0].divWad(weight0);
        try IFeeDesk(_roles.desk)
            .reviewCut(_terms.venueCutWad, rv.feeValue, block.timestamp - rv.last, poolValue) returns (
            uint256 cut, uint256 nextAt, uint256 grossAprWad
        ) {
            if (cut <= WAD && nextAt > block.timestamp) {
                if (cut != _terms.venueCutWad) {
                    _terms.venueCutWad = uint64(cut);
                    emit VenueCutSet(cut, grossAprWad);
                }
                review =
                    Review(nextAt > type(uint64).max ? type(uint64).max : uint64(nextAt), uint64(block.timestamp), 0);
                return;
            }
        } catch {}
        review.at = uint64(block.timestamp + 1 days);
    }

    // ------------------------------------------------------------------
    // Hall hooks
    // ------------------------------------------------------------------

    function _payFee(uint256 k, address to, uint256 amount) internal override {
        feesInHall[k] -= amount;
        SafeTransferLib.safeTransfer(k == 0 ? token0 : token1, to, amount);
    }

    function _creditPol(uint256 k, uint256 amount) internal override {
        feesInHall[k] -= amount;
        polOwed[k] += amount;
    }

    // ------------------------------------------------------------------
    // Venue, guardian, cap
    // ------------------------------------------------------------------

    /// Send the venue and protocol-owned-liquidity balances to their addresses. Anyone may call.
    function sweep() external guarded {
        for (uint256 k; k < TOKENS; ++k) {
            address token = k == 0 ? token0 : token1;
            uint256 v = venueOwed[k];
            uint256 p = polOwed[k];
            venueOwed[k] = 0;
            polOwed[k] = 0;
            if (v != 0) SafeTransferLib.safeTransfer(token, _roles.venue, v);
            if (p != 0) SafeTransferLib.safeTransfer(token, _roles.pol, p);
        }
    }

    /// Stop or restart joins and swaps. Exits always work, and are free while paused.
    function setPaused(bool on) external only(_roles.guardian) {
        paused = on;
        emit PauseSet(on);
    }

    function raiseCap(uint256 cap) external only(_roles.capRaiser) {
        if (cap <= depositCap) revert NotAllowed();
        depositCap = cap;
        emit CapRaised(cap);
    }

    // ------------------------------------------------------------------
    // Settings
    // ------------------------------------------------------------------

    /// Change the hall's settings. Positions already open keep the terms they opened under.
    function setHallConfig(HallConfig calldata c) external only(_roles.configurer) {
        _setHallConfig(c);
    }

    function setRoles(Roles calldata r) external only(_roles.configurer) {
        if (r.venue == address(0) || r.pol == address(0) || r.desk.code.length == 0) revert BadConfig();
        _roles = r;
        emit RolesSet(r);
    }
}

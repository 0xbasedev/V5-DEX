// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EpochHall} from "./EpochHall.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {StableMath} from "./StableMath.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// A fee that depends on where the trade takes the price. The pool hands it
/// the fee in force and the pool's price before the trade, half way through
/// it and after it, and charges whatever rate comes back, up to the ceiling.
/// It is consulted on swaps only and can never stand in the way of an exit.
interface IFeeModel {
    function feeFor(uint256 baseFeeWad, uint256 priceBefore, uint256 priceMid, uint256 priceAfter)
        external
        view
        returns (uint256);
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
/// - The fee moves inside bounds, quickly downward and slowly upward.
/// - The venue cut can set itself each week from the pool's own yield.
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

    struct Roles {
        address venue; // receives the venue cut
        address pol; // receives protocol-owned liquidity credits
        address guardian; // may pause and unpause
        address capRaiser; // may raise the deposit cap
        address configurer; // may change settings
        address feeSetter; // may queue a fee change inside the bounds
        address bank; // the escrow; may record what it has banked for this pool
        address depegWatch; // optional; while it reports a depeg, exits are free
    }

    struct FeePolicy {
        /// Bounds on the swap fee (WAD of the amount paid in).
        uint256 feeMinWad;
        uint256 feeMaxWad;
        /// How long a decrease and an increase wait before taking effect, in seconds.
        uint256 feeDownDelay;
        uint256 feeUpDelay;
        /// The venue cut sets itself: each review it aims to take `cutOfExcessWad`
        /// of whatever the pool's fees yield above `referenceAprWad`.
        bool autoCut;
        uint256 cutOfExcessWad;
        uint256 referenceAprWad;
        /// Bounds on the venue cut (WAD of the fee), the most it moves per review, and seconds between reviews.
        uint256 cutMinWad;
        uint256 cutMaxWad;
        uint256 cutStepWad;
        uint256 cutReview;
        /// Share of the venue cut paid to locked LPs (WAD).
        uint256 lockBudgetWad;
        /// An optional fee model, such as the tuning fork. Zero means the plain fee.
        address feeModel;
    }

    Roles internal _roles;
    FeePolicy internal _feePolicy;

    /// A swap may bring in at most this share of the reserve it adds to.
    uint256 internal constant MAX_IN_RATIO = 0.3e18;
    /// Shares locked for good on the first join, so the pool can never be emptied to a rounding trap.
    uint256 internal constant DEAD_SHARES = 1000;
    /// No fee policy may allow a fee above this.
    uint256 internal constant FEE_CEILING = 0.1e18;

    uint256[2] public reserves;
    uint256 public totalShares;
    /// Fees inside the hall, not yet paid out: this epoch's, held, and unclaimed.
    uint256[2] public feesInHall;
    uint256[2] public venueOwed;
    uint256[2] public polOwed;

    uint256 internal _feeWad;
    /// A fee change waiting out its delay, and when it takes effect (0 = none).
    uint256 public queuedFeeWad;
    uint256 public queuedFeeAt;

    /// The venue's share of each fee (WAD).
    uint256 public venueCutWad;
    uint256 public lastCutReview;
    /// Gross fees since the last review, valued in token0.
    uint256 public feeValueSinceReview;

    bool public paused;
    /// Most of token0 the reserves may hold. Raise-only.
    uint256 public depositCap;

    uint256 private _lock = 1;

    event Joined(uint256 indexed id, address indexed owner, uint256 amount0, uint256 amount1, uint256 shares);
    event Left(uint256 indexed id, address indexed to, uint256 amount0, uint256 amount1, uint256 toll0, uint256 toll1);
    event Swapped(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, uint256 fee);
    event PauseSet(bool paused);
    event CapRaised(uint256 cap);
    event FeeQueued(uint256 feeWad, uint256 effectiveAt);
    event VenueCutSet(uint256 cutWad, uint256 grossAprWad);
    event FeePolicySet(FeePolicy policy);
    event ConfigurerSet(address configurer);

    error Paused();
    error Reentered();
    error NotAllowed();
    error UnknownToken();
    error TooLittle();
    error TooMuchIn();
    error OverCap();

    struct PoolConfig {
        address token0;
        address token1;
        uint256 weight0;
        uint256 epochLength;
        uint256 feeWad;
        uint256 venueCutWad;
        uint256 depositCap;
        /// Zero for a weighted pool. For a peg pair, the amplification; weights must then be equal.
        uint256 amp;
    }

    constructor(PoolConfig memory c, Roles memory r, HallConfig memory h, FeePolicy memory f)
        EpochHall(c.epochLength, h)
    {
        if (
            c.token0 == c.token1 || c.token0 == address(0) || c.token1 == address(0) || c.weight0 == 0
                || c.weight0 >= WAD || r.venue == address(0) || r.pol == address(0)
        ) revert BadConfig();
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
        _setFeePolicy(f);
        if (c.feeWad < f.feeMinWad || c.feeWad > f.feeMaxWad) revert BadConfig();
        if (c.venueCutWad < f.cutMinWad || c.venueCutWad > f.cutMaxWad) revert BadConfig();
        _feeWad = c.feeWad;
        venueCutWad = c.venueCutWad;
        lastCutReview = block.timestamp;
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

    function feePolicy() external view returns (FeePolicy memory) {
        return _feePolicy;
    }

    /// The swap fee in force right now.
    function feeWad() public view returns (uint256) {
        return queuedFeeAt != 0 && block.timestamp >= queuedFeeAt ? queuedFeeWad : _feeWad;
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
        (amountOut,) = _quote(_index(tokenIn), amountIn);
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        guarded
        returns (uint256 amountOut)
    {
        if (paused) revert Paused();
        _current();
        _reviewCutIfDue();
        uint256 i = _index(tokenIn);
        uint256 o = 1 - i;
        uint256 fee;
        (amountOut, fee) = _quote(i, amountIn);
        if (amountOut == 0 || amountOut < minOut) revert TooLittle();

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
        feeValueSinceReview += i == 0 ? fee : _inToken0(fee);

        uint256 toVenue = fee * venueCutWad / WAD;
        uint256 toLockers = toVenue * _feePolicy.lockBudgetWad / WAD;
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

    function _quote(uint256 i, uint256 amountIn) private view returns (uint256 amountOut, uint256 fee) {
        if (amountIn > reserves[i].mulWad(MAX_IN_RATIO)) revert TooMuchIn();
        uint256 rate = feeWad();
        address model = _feePolicy.feeModel;
        if (model != address(0)) {
            // Where the trade would take the price, measured without the fee.
            uint256 half = amountIn / 2;
            rate = IFeeModel(model)
                .feeFor(
                    rate,
                    _price(i, 0, 0),
                    _price(i, half, _curveOut(i, half)),
                    _price(i, amountIn, _curveOut(i, amountIn))
                );
            if (rate > FEE_CEILING) rate = FEE_CEILING;
        }
        fee = amountIn.mulWadUp(rate);
        amountOut = _curveOut(i, amountIn - fee);
    }

    /// What `net` of token `i` buys from the curve, before any fee. Rounded against the trader.
    function _curveOut(uint256 i, uint256 net) private view returns (uint256 amountOut) {
        uint256 rIn = reserves[i];
        uint256 rOut = reserves[1 - i];
        (uint256 wIn, uint256 wOut) = i == 0 ? (weight0, weight1) : (weight1, weight0);
        if (amp != 0) {
            // The amplified curve works in a common 18-decimal scale.
            (uint256 sIn, uint256 sOut) = i == 0 ? (_scale0, _scale1) : (_scale1, _scale0);
            amountOut = StableMath.amountOut(rIn * sIn, rOut * sOut, net * sIn, amp) / sOut;
        } else if (wIn == wOut) {
            amountOut = rOut * net / (rIn + net);
        } else {
            // out = rOut * (1 - (rIn / (rIn + net)) ^ (wIn / wOut)), rounded against the trader.
            uint256 base = rIn.divWadUp(rIn + net);
            uint256 power = uint256(FixedPointMathLib.powWad(int256(base), int256(wIn.divWad(wOut))));
            power += power / 1e14 + 1; // more than the power function's error
            amountOut = power >= WAD ? 0 : rOut.mulWad(WAD - power);
        }
    }

    /// The pool's price, token1 per token0 scaled by 1e18, as it would stand
    /// after `added` of token `i` came in and `removed` of the other went out.
    /// A peg pair's price is in a common 18-decimal scale, so it reads 1e18 at the peg.
    function _price(uint256 i, uint256 added, uint256 removed) private view returns (uint256) {
        (uint256 r0, uint256 r1) =
            i == 0 ? (reserves[0] + added, reserves[1] - removed) : (reserves[0] - removed, reserves[1] + added);
        if (amp != 0) return StableMath.price(r0 * _scale0, r1 * _scale1, amp);
        return FixedPointMathLib.fullMulDiv(r1 * weight0, WAD, r0 * weight1);
    }

    /// The pool's price now: token1 per token0, scaled by 1e18.
    function price() external view returns (uint256) {
        return _price(0, 0, 0);
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
    // The fee
    // ------------------------------------------------------------------

    /// Ask for a new swap fee, inside the bounds. A decrease takes effect after
    /// the short delay and an increase after the long one.
    function queueFee(uint256 newFeeWad) external only(_roles.feeSetter) {
        FeePolicy memory f = _feePolicy;
        if (newFeeWad < f.feeMinWad || newFeeWad > f.feeMaxWad) revert BadConfig();
        uint256 current = feeWad();
        _feeWad = current; // a change that had already matured is now simply the fee
        queuedFeeWad = newFeeWad;
        queuedFeeAt = block.timestamp + (newFeeWad < current ? f.feeDownDelay : f.feeUpDelay);
        emit FeeQueued(newFeeWad, queuedFeeAt);
    }

    // ------------------------------------------------------------------
    // The venue cut
    // ------------------------------------------------------------------

    /// Review the venue cut if a review is due. Anyone may call; swaps do it themselves.
    function reviewCut() external {
        _reviewCutIfDue();
    }

    function _reviewCutIfDue() private {
        FeePolicy memory f = _feePolicy;
        uint256 elapsed = block.timestamp - lastCutReview;
        if (!f.autoCut || elapsed < f.cutReview || reserves[0] == 0) return;

        // What the pool's fees yielded on its own depth since the last review,
        // as a yearly rate. Both sides are valued in token0.
        uint256 poolValue = amp != 0 ? reserves[0] + _inToken0(reserves[1]) : reserves[0].divWad(weight0);
        uint256 grossApr = feeValueSinceReview.mulDiv(365 days * WAD, elapsed * poolValue);

        // Take a set share of the yield above the reference rate, none of the yield below it.
        uint256 want =
            grossApr > f.referenceAprWad ? f.cutOfExcessWad.mulDiv(grossApr - f.referenceAprWad, grossApr) : 0;
        if (want < f.cutMinWad) want = f.cutMinWad;
        if (want > f.cutMaxWad) want = f.cutMaxWad;

        uint256 cut = venueCutWad;
        if (want > cut) cut = want - cut > f.cutStepWad ? cut + f.cutStepWad : want;
        else cut = cut - want > f.cutStepWad ? cut - f.cutStepWad : want;

        venueCutWad = cut;
        lastCutReview = block.timestamp;
        feeValueSinceReview = 0;
        emit VenueCutSet(cut, grossApr);
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

    /// Change the fee policy. The fee and the cut in force are pulled inside the new bounds.
    function setFeePolicy(FeePolicy calldata f) external only(_roles.configurer) {
        _feeWad = feeWad();
        queuedFeeAt = 0;
        _setFeePolicy(f);
        if (_feeWad < f.feeMinWad) _feeWad = f.feeMinWad;
        if (_feeWad > f.feeMaxWad) _feeWad = f.feeMaxWad;
        if (venueCutWad < f.cutMinWad) venueCutWad = f.cutMinWad;
        if (venueCutWad > f.cutMaxWad) venueCutWad = f.cutMaxWad;
    }

    /// Set the venue cut by hand, inside its bounds. Only while it is not setting itself.
    function setVenueCut(uint256 cutWad) external only(_roles.configurer) {
        FeePolicy memory f = _feePolicy;
        if (f.autoCut || cutWad < f.cutMinWad || cutWad > f.cutMaxWad) revert BadConfig();
        venueCutWad = cutWad;
        emit VenueCutSet(cutWad, 0);
    }

    function setRoles(Roles calldata r) external only(_roles.configurer) {
        if (r.venue == address(0) || r.pol == address(0)) revert BadConfig();
        _roles = r;
        emit ConfigurerSet(r.configurer);
    }

    function _setFeePolicy(FeePolicy memory f) private {
        if (
            f.feeMinWad > f.feeMaxWad || f.feeMaxWad > FEE_CEILING || f.cutMinWad > f.cutMaxWad || f.cutMaxWad > WAD
                || f.cutOfExcessWad > WAD || f.lockBudgetWad > WAD || (f.autoCut && f.cutReview == 0)
        ) revert BadConfig();
        _feePolicy = f;
        emit FeePolicySet(f);
    }
}

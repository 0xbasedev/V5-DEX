// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EpochHall} from "./EpochHall.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title V5Pool
/// @notice A two-token weighted pool whose liquidity is held as seasoned
/// positions (spec v1.16 §3).
///
/// - Swap fees never enter the reserves. The LP share goes to the hall's fee
///   ledger and is paid by seasoned weight; the venue cut is set aside.
/// - There is no fungible LP token. Joining opens a position in the hall.
/// - A guardian can pause joins and swaps. A pause never blocks an exit, and
///   during one every exit is free of forfeits and tolls.
/// - Nothing here can be changed after deployment except the pause and a
///   deposit cap that can only be raised.
///
/// First cut, for shaping. Not audited. Known gaps are listed in src/README.md.
contract V5Pool is EpochHall {
    using FixedPointMathLib for uint256;

    address public immutable token0;
    address public immutable token1;
    /// Weights, in WAD, summing to one.
    uint256 public immutable weight0;
    uint256 public immutable weight1;
    /// Fee on the amount paid in (WAD), and the venue's share of that fee (WAD).
    uint256 public immutable feeWad;
    uint256 public immutable venueCutWad;
    address public immutable venue;
    address public immutable pol;
    address public immutable guardian;
    address public immutable capRaiser;

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

    bool public paused;
    /// Most of token0 the reserves may hold. Raise-only.
    uint256 public depositCap;

    uint256 private _lock = 1;

    event Joined(uint256 indexed id, address indexed owner, uint256 amount0, uint256 amount1, uint256 shares);
    event Left(uint256 indexed id, address indexed to, uint256 amount0, uint256 amount1, uint256 toll0, uint256 toll1);
    event Swapped(address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, uint256 fee);
    event PauseSet(bool paused);
    event CapRaised(uint256 cap);

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
        uint256 feeWad;
        uint256 venueCutWad;
        address venue;
        address pol;
        address guardian;
        address capRaiser;
        uint256 depositCap;
    }

    constructor(PoolConfig memory c, HallConfig memory h) EpochHall(h) {
        if (
            c.token0 == c.token1 || c.token0 == address(0) || c.token1 == address(0) || c.weight0 == 0
                || c.weight0 >= WAD || c.feeWad >= WAD / 10 || c.venueCutWad > WAD || c.venue == address(0)
                || c.pol == address(0)
        ) revert BadConfig();
        token0 = c.token0;
        token1 = c.token1;
        weight0 = c.weight0;
        weight1 = WAD - c.weight0;
        feeWad = c.feeWad;
        venueCutWad = c.venueCutWad;
        venue = c.venue;
        pol = c.pol;
        guardian = c.guardian;
        capRaiser = c.capRaiser;
        depositCap = c.depositCap;
    }

    modifier guarded() {
        if (_lock != 1) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
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
        (, uint256 shares, uint256 toll) = _close(id, paused);

        uint256 total = totalShares;
        out0 = (shares - toll) * reserves[0] / total;
        out1 = (shares - toll) * reserves[1] / total;
        // The toll's share of the reserves leaves with the position's shares:
        // a share to protocol-owned liquidity, the rest to the LPs who stay.
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

    function _shareOutToll(uint256 k, uint256 amount) private {
        if (amount == 0) return;
        uint256 toPol = amount * polShareWad / WAD;
        polOwed[k] += toPol;
        pending[k] += amount - toPol;
        feesInHall[k] += amount - toPol;
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
        uint256 i = _index(tokenIn);
        uint256 o = 1 - i;
        uint256 fee;
        (amountOut, fee) = _quote(i, amountIn);
        if (amountOut == 0 || amountOut < minOut) revert TooLittle();

        // The fee never touches the reserves.
        uint256 toVenue = fee * venueCutWad / WAD;
        venueOwed[i] += toVenue;
        pending[i] += fee - toVenue;
        feesInHall[i] += fee - toVenue;
        reserves[i] += amountIn - fee;
        reserves[o] -= amountOut;

        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(o == 0 ? token0 : token1, to, amountOut);
        emit Swapped(msg.sender, tokenIn, amountIn, amountOut, fee);
    }

    function _index(address token) private view returns (uint256) {
        if (token == token0) return 0;
        if (token == token1) return 1;
        revert UnknownToken();
    }

    function _quote(uint256 i, uint256 amountIn) private view returns (uint256 amountOut, uint256 fee) {
        fee = amountIn.mulWadUp(feeWad);
        uint256 net = amountIn - fee;
        uint256 rIn = reserves[i];
        uint256 rOut = reserves[1 - i];
        if (net > rIn.mulWad(MAX_IN_RATIO)) revert TooMuchIn();
        (uint256 wIn, uint256 wOut) = i == 0 ? (weight0, weight1) : (weight1, weight0);
        if (wIn == wOut) {
            amountOut = rOut * net / (rIn + net);
        } else {
            // out = rOut * (1 - (rIn / (rIn + net)) ^ (wIn / wOut)), rounded against the trader.
            uint256 base = rIn.divWadUp(rIn + net);
            uint256 power = uint256(FixedPointMathLib.powWad(int256(base), int256(wIn.divWad(wOut))));
            power += power / 1e14 + 1; // more than the power function's error
            amountOut = power >= WAD ? 0 : rOut.mulWad(WAD - power);
        }
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

    /// Send the venue and protocol-owned-liquidity balances to their fixed addresses. Anyone may call.
    function sweep() external guarded {
        for (uint256 k; k < TOKENS; ++k) {
            address token = k == 0 ? token0 : token1;
            uint256 v = venueOwed[k];
            uint256 p = polOwed[k];
            venueOwed[k] = 0;
            polOwed[k] = 0;
            if (v != 0) SafeTransferLib.safeTransfer(token, venue, v);
            if (p != 0) SafeTransferLib.safeTransfer(token, pol, p);
        }
    }

    /// Stop or restart joins and swaps. Exits always work, and are free while paused.
    function setPaused(bool on) external {
        if (msg.sender != guardian) revert NotAllowed();
        paused = on;
        emit PauseSet(on);
    }

    function raiseCap(uint256 cap) external {
        if (msg.sender != capRaiser || cap <= depositCap) revert NotAllowed();
        depositCap = cap;
        emit CapRaised(cap);
    }
}

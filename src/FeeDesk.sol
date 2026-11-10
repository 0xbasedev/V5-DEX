// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Roles, Terms, FeePolicy} from "./PoolTypes.sol";
import {FEE_CEILING} from "./PoolCurve.sol";

interface IPoolForDesk {
    function roles() external view returns (Roles memory);
    function terms() external view returns (Terms memory);
    function review() external view returns (uint64 at, uint64 last, uint128 feeValue);
    function setTerms(Terms calldata t, uint256 reviewAt) external;
}

/// @title FeeDesk
/// @notice Decides what each pool charges; the pool does the charging.
///
/// A pool holds its fee terms itself: the fee, a change on its way, the venue
/// cut. It reads them on every swap without asking anyone. This contract holds
/// the rules those terms are set by, pool by pool, and is the only address a
/// pool lets set them:
///
///  - the fee moves inside bounds, a decrease after a short delay and an
///    increase after a long one;
///  - the venue cut can set itself at each review, taking a set share of what
///    the pool's fees yield above a reference rate, a step at a time;
///  - or the cut is flat and set by hand.
///
/// It keeps no roles of its own. It asks the pool who its configurer and its
/// fee setter are, so a pool whose configurer has been handed to the zero
/// address has a policy frozen for good. One deployment serves every pool.
///
/// What the desk cannot do: the pool refuses any fee above its own ceiling and
/// any share above the whole, whoever asks. And nothing here is on the path
/// of an exit. A desk that fails to answer a review leaves the cut where it
/// was and never stops a swap.
contract FeeDesk {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant NEVER = type(uint64).max;

    mapping(address pool => FeePolicy) internal _policy;

    event PolicySet(address indexed pool, FeePolicy policy);
    event FeeQueued(address indexed pool, uint256 feeWad, uint256 effectiveAt);
    event VenueCutSet(address indexed pool, uint256 cutWad);

    error NotAllowed();
    error BadPolicy();

    function policyOf(address pool) external view returns (FeePolicy memory) {
        return _policy[pool];
    }

    /// Called by a pool as it is deployed, with the policy it opens under and
    /// the fee and cut it opens at. Returns when its first review falls due.
    /// A caller only ever writes its own entry.
    function open(FeePolicy calldata f, uint256 feeWad, uint256 cutWad) external returns (uint256 reviewAt) {
        _check(f);
        if (feeWad < f.feeMinWad || feeWad > f.feeMaxWad || cutWad < f.cutMinWad || cutWad > f.cutMaxWad) {
            revert BadPolicy();
        }
        _policy[msg.sender] = f;
        emit PolicySet(msg.sender, f);
        return f.autoCut ? block.timestamp + f.cutReview : NEVER;
    }

    /// Ask for a new swap fee, inside the bounds. A decrease takes effect after
    /// the short delay and an increase after the long one. It lands by itself.
    function queueFee(address pool, uint256 newFeeWad) external {
        if (msg.sender != IPoolForDesk(pool).roles().feeSetter) revert NotAllowed();
        FeePolicy storage f = _policy[pool];
        if (newFeeWad < f.feeMinWad || newFeeWad > f.feeMaxWad) revert BadPolicy();
        Terms memory t = IPoolForDesk(pool).terms();
        uint256 current = _feeInForce(t);
        uint256 at = block.timestamp + (newFeeWad < current ? f.feeDownDelay : f.feeUpDelay);
        t.feeWad = uint64(current); // a change that had already landed is now simply the fee
        t.nextFeeWad = uint64(newFeeWad);
        t.nextFeeAt = uint64(at);
        _push(pool, t, NEVER + 1);
        emit FeeQueued(pool, newFeeWad, at);
    }

    /// Change a pool's policy. The fee and the cut in force are pulled inside
    /// the new bounds, and any fee change on its way is dropped.
    function setPolicy(address pool, FeePolicy calldata f) external {
        if (msg.sender != IPoolForDesk(pool).roles().configurer) revert NotAllowed();
        _check(f);
        _policy[pool] = f;
        emit PolicySet(pool, f);

        Terms memory t = IPoolForDesk(pool).terms();
        t.feeWad = uint64(_clamp(_feeInForce(t), f.feeMinWad, f.feeMaxWad));
        t.nextFeeWad = 0;
        t.nextFeeAt = 0;
        t.venueCutWad = uint64(_clamp(t.venueCutWad, f.cutMinWad, f.cutMaxWad));
        t.lockBudgetWad = uint64(f.lockBudgetWad);
        t.feeModel = f.feeModel;
        (, uint64 last,) = IPoolForDesk(pool).review();
        _push(pool, t, f.autoCut ? last + f.cutReview : NEVER);
    }

    /// Set the venue cut by hand, inside its bounds. Only while it is not setting itself.
    function setVenueCut(address pool, uint256 cutWad) external {
        if (msg.sender != IPoolForDesk(pool).roles().configurer) revert NotAllowed();
        FeePolicy storage f = _policy[pool];
        if (f.autoCut || cutWad < f.cutMinWad || cutWad > f.cutMaxWad) revert BadPolicy();
        Terms memory t = IPoolForDesk(pool).terms();
        t.venueCutWad = uint64(cutWad);
        _push(pool, t, NEVER + 1);
        emit VenueCutSet(pool, cutWad);
    }

    /// Asked by a pool when its review falls due: what the venue cut should
    /// be now, and when to ask again.
    ///
    /// `cutWad` is the cut in force. `feeValue` is what the pool's fees came
    /// to since the last review and `poolValue` what the pool holds, both in
    /// the same token; `elapsed` is the seconds since the last review.
    function reviewCut(uint256 cutWad, uint256 feeValue, uint256 elapsed, uint256 poolValue)
        external
        view
        returns (uint256 cut, uint256 nextAt, uint256 grossAprWad)
    {
        FeePolicy memory f = _policy[msg.sender];
        if (!f.autoCut) return (cutWad, NEVER, 0);
        nextAt = block.timestamp + f.cutReview;
        if (elapsed == 0 || poolValue == 0) return (cutWad, nextAt, 0);

        // What the pool's fees yielded on its own depth since the last review, as a yearly rate.
        grossAprWad = feeValue.mulDiv(365 days * WAD, elapsed * poolValue);

        // Take a set share of the yield above the reference rate, none of the yield below it.
        uint256 want =
            grossAprWad > f.referenceAprWad ? f.cutOfExcessWad.mulDiv(grossAprWad - f.referenceAprWad, grossAprWad) : 0;
        want = _clamp(want, f.cutMinWad, f.cutMaxWad);

        if (want > cutWad) cut = want - cutWad > f.cutStepWad ? cutWad + f.cutStepWad : want;
        else cut = cutWad - want > f.cutStepWad ? cutWad - f.cutStepWad : want;
    }

    /// Hand a pool its terms. A review time past the largest a pool can hold means "leave it as it is".
    function _push(address pool, Terms memory t, uint256 reviewAt) private {
        if (reviewAt > NEVER) (reviewAt,,) = IPoolForDesk(pool).review();
        IPoolForDesk(pool).setTerms(t, reviewAt);
    }

    function _feeInForce(Terms memory t) private view returns (uint256) {
        return t.nextFeeAt != 0 && block.timestamp >= t.nextFeeAt ? t.nextFeeWad : t.feeWad;
    }

    function _clamp(uint256 x, uint256 low, uint256 high) private pure returns (uint256) {
        return x < low ? low : x > high ? high : x;
    }

    function _check(FeePolicy calldata f) private pure {
        if (
            f.feeMinWad > f.feeMaxWad || f.feeMaxWad > FEE_CEILING || f.cutMinWad > f.cutMaxWad || f.cutMaxWad > WAD
                || f.cutOfExcessWad > WAD || f.lockBudgetWad > WAD || (f.autoCut && f.cutReview == 0)
                || f.feeUpDelay > 365 days || f.feeDownDelay > 365 days || f.cutReview > 365 days
        ) revert BadPolicy();
    }
}

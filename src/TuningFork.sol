// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// A price from outside the pool: a fixed peg, a rate provider, an oracle.
interface IPriceSource {
    function priceWad() external view returns (uint256);
}

/// @title TuningFork
/// @notice The directional fee for peg and target pools (spec v1.16 §3).
///
/// The pool has a pitch: the price it is meant to sit at. A trade that moves
/// the price toward the pitch is cheap. A trade that moves it away is dearer
/// the further from the pitch it goes, up to a cap.
///
/// The fee is charged over the whole move, not on where the trade starts or
/// ends. At each point along the way a sliver of the trade has its own rate:
///
///   - heading toward the pitch:   the base fee times `towardWad` (a floor, never zero)
///   - heading away from it:       the base fee plus `slopeWad` per unit of detune, at most `capWad`
///
/// where detune is how far the price is from the pitch, as a share of the
/// pitch. The trade's rate is the average of that along its path, weighted by
/// how much of the trade happens at each price. The pool supplies the price at
/// three points (before, half way, after) and the average is taken by
/// Simpson's rule. Because the weighting is by amount traded, cutting a trade
/// into pieces changes the total very little; a rate that looked only at the
/// start and the end could be dodged that way.
///
/// The pitch is a fixed number or an outside source. It is never the pool's
/// own price, which would let a long depeg quietly become the new target.
///
/// One fork per pool. Its settings are changeable by its configurer and
/// frozen by handing that role to the zero address. First cut. Not audited.
contract TuningFork {
    uint256 internal constant WAD = 1e18;

    struct Policy {
        /// The pitch, token1 per token0 scaled by 1e18. Used when `pitchSource` is zero.
        uint256 pitchWad;
        /// Optional outside source for the pitch.
        address pitchSource;
        /// Share of the base fee charged when heading toward the pitch (WAD). Must be above zero.
        uint256 towardWad;
        /// Fee added per unit of detune when heading away (WAD per WAD): 1e18 adds 1% of fee per 1% of detune.
        uint256 slopeWad;
        /// The most a sliver heading away can be charged (WAD).
        uint256 capWad;
    }

    Policy internal _policy;
    address public configurer;

    event PolicySet(Policy policy);
    event ConfigurerSet(address configurer);

    error NotAllowed();
    error BadPolicy();

    constructor(Policy memory p, address configurer_) {
        configurer = configurer_;
        _setPolicy(p);
    }

    function policy() external view returns (Policy memory) {
        return _policy;
    }

    /// The pitch in force.
    function pitch() public view returns (uint256) {
        Policy storage p = _policy;
        return p.pitchSource == address(0) ? p.pitchWad : IPriceSource(p.pitchSource).priceWad();
    }

    /// The rate for a trade that takes the pool's price from `priceBefore`
    /// through `priceMid` (half the trade done) to `priceAfter`.
    function feeFor(uint256 baseFeeWad, uint256 priceBefore, uint256 priceMid, uint256 priceAfter)
        external
        view
        returns (uint256)
    {
        Policy memory p = _policy;
        uint256 target = pitch();
        bool rising = priceAfter >= priceBefore;
        uint256 atStart = _sliver(p, target, baseFeeWad, priceBefore, rising);
        uint256 atMid = _sliver(p, target, baseFeeWad, priceMid, rising);
        uint256 atEnd = _sliver(p, target, baseFeeWad, priceAfter, rising);
        return (atStart + 4 * atMid + atEnd) / 6;
    }

    /// The rate for a sliver of trade at price `at`, with the price moving up or down.
    function _sliver(Policy memory p, uint256 target, uint256 base, uint256 at, bool rising)
        internal
        pure
        returns (uint256)
    {
        bool above = at > target;
        // At the pitch itself, any move is a move away. Otherwise a move is
        // away when it goes further in the direction the price already sits.
        if (at != target && above != rising) return base * p.towardWad / WAD;
        uint256 detune = (above ? at - target : target - at) * WAD / target;
        uint256 rate = base + p.slopeWad * detune / WAD;
        uint256 cap = p.capWad > base ? p.capWad : base;
        return rate > cap ? cap : rate;
    }

    function setPolicy(Policy calldata p) external {
        if (msg.sender != configurer) revert NotAllowed();
        _setPolicy(p);
    }

    function setConfigurer(address next) external {
        if (msg.sender != configurer) revert NotAllowed();
        configurer = next;
        emit ConfigurerSet(next);
    }

    function _setPolicy(Policy memory p) internal {
        if (p.towardWad == 0 || p.towardWad > WAD || (p.pitchSource == address(0) && p.pitchWad == 0)) {
            revert BadPolicy();
        }
        _policy = p;
        emit PolicySet(p);
    }
}

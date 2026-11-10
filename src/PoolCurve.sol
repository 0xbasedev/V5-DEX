// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StableMath} from "./StableMath.sol";

/// A fee that depends on where the trade takes the price. It is handed the
/// fee in force and the pool's price before the trade, half way through it and
/// after it, and whatever rate comes back is charged, up to the ceiling.
/// It is consulted on swaps only and can never stand in the way of an exit.
interface IFeeModel {
    function feeFor(uint256 baseFeeWad, uint256 priceBefore, uint256 priceMid, uint256 priceAfter)
        external
        view
        returns (uint256);
}

// No pool may charge more than this, whatever its policy or fee model says.
uint256 constant FEE_CEILING = 0.1e18;

/// @title PoolCurve
/// @notice The swap arithmetic for every V5 pool: the weighted curve, the
/// amplified curve, the fee on a trade and the price.
///
/// It keeps nothing and holds nothing. One deployment serves every pool. A
/// pool passes in its shape and its reserves and gets numbers back; because
/// the pool only ever reads from it, nothing here can move a pool's money or
/// touch its books. It exists so that this arithmetic does not count against
/// the pool's own code size.
///
/// A pool trusts the answers, so a pool must only ever be pointed at the
/// audited deployment. The address is fixed when the pool is deployed.
contract PoolCurve {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;

    /// What makes one pool's curve different from another's.
    struct Shape {
        /// Weight of token0 (WAD). Token1 has the rest.
        uint256 weight0;
        /// Amplification for a peg pair. Zero means the weighted curve.
        uint256 amp;
        /// What each token's amounts are multiplied by to reach 18 decimals. Used by the amplified curve.
        uint256 scale0;
        uint256 scale1;
    }

    /// One trade's view of the pool: everything turned to face the token coming in.
    struct Side {
        uint256 rIn;
        uint256 rOut;
        uint256 wIn;
        uint256 wOut;
        uint256 sIn;
        uint256 sOut;
        uint256 amp;
        /// The amplified curve's invariant before the trade. Zero on the weighted curve.
        uint256 d;
        /// True when the token coming in is token0.
        bool zeroIn;
    }

    /// What `amountIn` of token `i` buys, and the fee taken from it.
    ///
    /// `rate` is the pool's fee in force. If `model` is set it may replace the
    /// rate, having been shown where the trade would take the price, measured
    /// without the fee. `logPrice` is the natural logarithm of the price before
    /// the trade, for the pool's price record.
    function quote(Shape calldata s, uint256 r0, uint256 r1, uint256 i, uint256 amountIn, uint256 rate, address model)
        external
        view
        returns (uint256 amountOut, uint256 fee, int256 logPrice)
    {
        Side memory c = _side(s, r0, r1, i);
        uint256 before = _price(c, 0, 0);
        logPrice = _ln(before);
        if (model != address(0)) {
            uint256 half = amountIn / 2;
            rate = IFeeModel(model)
                .feeFor(rate, before, _price(c, half, _out(c, half)), _price(c, amountIn, _out(c, amountIn)));
            if (rate > FEE_CEILING) rate = FEE_CEILING;
        }
        fee = amountIn.mulWadUp(rate);
        amountOut = _out(c, amountIn - fee);
    }

    /// The price, token1 per token0 scaled by 1e18, and its natural logarithm.
    /// A peg pair's price is in a common 18-decimal scale, so it reads 1e18 at the peg.
    function spot(Shape calldata s, uint256 r0, uint256 r1) external pure returns (uint256 price, int256 logPrice) {
        price = _price(_side(s, r0, r1, 0), 0, 0);
        logPrice = _ln(price);
    }

    function _side(Shape calldata s, uint256 r0, uint256 r1, uint256 i) private pure returns (Side memory c) {
        c.zeroIn = i == 0;
        (c.rIn, c.rOut) = c.zeroIn ? (r0, r1) : (r1, r0);
        (c.wIn, c.wOut) = c.zeroIn ? (s.weight0, WAD - s.weight0) : (WAD - s.weight0, s.weight0);
        (c.sIn, c.sOut) = c.zeroIn ? (s.scale0, s.scale1) : (s.scale1, s.scale0);
        c.amp = s.amp;
        // Solved once. Every point this trade can reach lies on the same curve.
        if (s.amp != 0) c.d = StableMath.invariant(c.rIn * c.sIn, c.rOut * c.sOut, s.amp);
    }

    /// What `net` of the token coming in buys from the curve, before any fee. Rounded against the trader.
    function _out(Side memory c, uint256 net) private pure returns (uint256 amountOut) {
        if (c.amp != 0) {
            // The amplified curve works in a common 18-decimal scale.
            amountOut = StableMath.amountOutAt(c.rIn * c.sIn, c.rOut * c.sOut, net * c.sIn, c.d, c.amp) / c.sOut;
        } else if (c.wIn == c.wOut) {
            amountOut = c.rOut * net / (c.rIn + net);
        } else {
            // out = rOut * (1 - (rIn / (rIn + net)) ^ (wIn / wOut)), rounded against the trader.
            uint256 base = c.rIn.divWadUp(c.rIn + net);
            uint256 power = uint256(FixedPointMathLib.powWad(int256(base), int256(c.wIn.divWad(c.wOut))));
            power += power / 1e14 + 1; // more than the power function's error
            amountOut = power >= WAD ? 0 : c.rOut.mulWad(WAD - power);
        }
    }

    /// The price as it would stand after `added` of the token coming in had
    /// arrived and `removed` of the other had left.
    function _price(Side memory c, uint256 added, uint256 removed) private pure returns (uint256) {
        uint256 rIn = c.rIn + added;
        uint256 rOut = c.rOut - removed;
        if (c.amp != 0) {
            rIn *= c.sIn;
            rOut *= c.sOut;
            return c.zeroIn ? StableMath.priceAt(rIn, rOut, c.d, c.amp) : StableMath.priceAt(rOut, rIn, c.d, c.amp);
        }
        (uint256 r0, uint256 r1, uint256 w0, uint256 w1) =
            c.zeroIn ? (rIn, rOut, c.wIn, c.wOut) : (rOut, rIn, c.wOut, c.wIn);
        return FixedPointMathLib.fullMulDiv(r1 * w0, WAD, r0 * w1);
    }

    /// Natural logarithm of a price, scaled by 1e18. A price too small to
    /// write down is treated as the smallest that can be, so that the record
    /// can never be the reason a swap fails.
    function _ln(uint256 price) private pure returns (int256) {
        if (price == 0) price = 1;
        if (price > uint256(type(int256).max)) price = uint256(type(int256).max);
        return FixedPointMathLib.lnWad(int256(price));
    }
}

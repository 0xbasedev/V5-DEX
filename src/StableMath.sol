// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title StableMath
/// @notice The amplified invariant for a two-token peg pair (spec v1.16 §3, "curve modes").
///
/// The invariant is the StableSwap one,
///
///     2A(x + y) + D = 2AD + D^3 / (4xy)
///
/// which trades almost one for one while the pool is balanced and bends
/// toward a constant-product curve as it is drained. `amp` is A in the convention
/// the original two-token pools use; a larger A
/// keeps the price flat for longer. Balances are passed in a common
/// 18-decimal scale.
///
/// Both functions solve by Newton's method on integers, the same steps the
/// original uses. `test/StableMath.t.sol` checks them against vectors computed
/// independently, and checks that every swap leaves the invariant no smaller.
library StableMath {
    error DidNotConverge();

    /// Units, in the 18-decimal scale, held back from every amount out.
    uint256 internal constant ROUNDING = 4;

    /// The invariant D for balances x and y.
    function invariant(uint256 x, uint256 y, uint256 amp) internal pure returns (uint256 d) {
        uint256 sum = x + y;
        if (sum == 0) return 0;
        uint256 ann = amp * 2;
        d = sum;
        for (uint256 i; i < 255; ++i) {
            uint256 dp = d * d / (x * 2) * d / (y * 2);
            uint256 prev = d;
            d = (ann * sum + dp * 2) * d / ((ann - 1) * d + 3 * dp);
            if (d > prev ? d - prev <= 1 : prev - d <= 1) return d;
        }
        revert DidNotConverge();
    }

    /// The other balance, given one balance `x` and the invariant `d`.
    function otherBalance(uint256 x, uint256 d, uint256 amp) internal pure returns (uint256 y) {
        uint256 ann = amp * 2;
        uint256 c = d * d / (x * 2) * d / (ann * 2);
        uint256 b = x + d / ann;
        y = d;
        for (uint256 i; i < 255; ++i) {
            uint256 prev = y;
            y = (y * y + c) / (2 * y + b - d);
            if (y > prev ? y - prev <= 1 : prev - y <= 1) return y;
        }
        revert DidNotConverge();
    }

    /// The marginal price of x in units of y, scaled by 1e18: how much y the
    /// next sliver of x buys. It is the ratio of the invariant's two slopes,
    /// (2A + D^3/(4x^2 y)) / (2A + D^3/(4x y^2)).
    function price(uint256 x, uint256 y, uint256 amp) internal pure returns (uint256) {
        return priceAt(x, y, invariant(x, y, amp), amp);
    }

    /// The same price, for a caller that already knows the invariant `d`.
    function priceAt(uint256 x, uint256 y, uint256 d, uint256 amp) internal pure returns (uint256) {
        uint256 ann = amp * 2;
        uint256 dp = d * d / (x * 2) * d / (y * 2);
        return FixedPointMathLib.fullMulDiv((ann * x + dp) * y, 1e18, (ann * y + dp) * x);
    }

    /// What `amountIn` buys, with both balances and the result in the common scale.
    /// Rounded against the trader.
    function amountOut(uint256 balanceIn, uint256 balanceOut, uint256 amountIn, uint256 amp)
        internal
        pure
        returns (uint256)
    {
        return amountOutAt(balanceIn, balanceOut, amountIn, invariant(balanceIn, balanceOut, amp), amp);
    }

    /// The same amount, for a caller that already knows the invariant `d` of the two balances.
    function amountOutAt(uint256 balanceIn, uint256 balanceOut, uint256 amountIn, uint256 d, uint256 amp)
        internal
        pure
        returns (uint256)
    {
        uint256 y = otherBalance(balanceIn + amountIn, d, amp);
        // Each solve is only good to its last unit, so take a few units off:
        // enough that no sequence of trades can come out ahead on rounding.
        return balanceOut > y + ROUNDING ? balanceOut - y - ROUNDING : 0;
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Base, Token} from "./Base.sol";
import {PoolSetup} from "./V5Pool.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {PoolConfig, FeePolicy} from "../src/PoolTypes.sol";
import {StableMath} from "../src/StableMath.sol";

contract StableMathTest is Base {
    /// Balance in, balance out, amount in, amplification, the invariant, the amount out.
    /// Computed outside Solidity with the same integer steps; the invariant itself was
    /// checked against the curve's equation to better than one part in 10^24. The
    /// amounts out are those values less the contract's rounding margin.
    function test_matchesValuesComputedIndependently() public pure {
        uint256[6][7] memory v = [
            [uint256(1000000e18), 1000000e18, 1000e18, 100, 2000000000000000000000000, 999990099098224001846],
            [uint256(1000000e18), 1000000e18, 200000e18, 100, 2000000000000000000000000, 199588686229240349615915],
            [uint256(1500000e18), 500000e18, 10000e18, 100, 1996715821544259128824509, 9823724986636652627986],
            [uint256(500000e18), 1500000e18, 10000e18, 100, 1996715821544259128824509, 10171346685503814940767],
            [uint256(1000000e18), 1000000e18, 200000e18, 10, 2000000000000000000000000, 196311413706126685268896],
            [uint256(1000000e18), 1000000e18, 200000e18, 2000, 2000000000000000000000000, 199979180220857635065814],
            [
                uint256(123456789e18),
                987654321e18,
                5000000e18,
                50,
                1095133388282184616509326443,
                5892830743035061084953195
            ]
        ];
        for (uint256 i; i < 7; ++i) {
            vm.assertEq(StableMath.invariant(v[i][0], v[i][1], v[i][3]), v[i][4], "invariant");
            vm.assertEq(StableMath.amountOut(v[i][0], v[i][1], v[i][2], v[i][3]), v[i][5], "amount out");
        }
    }

    function test_aBalancedPegPairTradesAlmostOneForOne() public pure {
        uint256 out = StableMath.amountOut(1_000_000e18, 1_000_000e18, 1000e18, 100);
        vm.assertGt(out, 999.9e18, "far closer to one for one than a constant-product pool's 999.0");
        vm.assertLt(out, 1000e18, "but never better than one for one");
    }

    /// A swap never leaves the invariant smaller, and a round trip never pays.
    function testFuzz_swapsNeverShrinkTheInvariant(uint256 x, uint256 y, uint256 amountIn, uint256 amp) public pure {
        x = bound(x, 1e18, 1e27);
        y = bound(y, x / 20, x * 20); // within twenty to one of each other
        amp = bound(amp, 1, 5000);
        amountIn = bound(amountIn, 1e12, x / 3);

        uint256 before = StableMath.invariant(x, y, amp);
        uint256 out = StableMath.amountOut(x, y, amountIn, amp);
        vm.assertLt(out, y, "it cannot empty the other side");
        uint256 afterSwap = StableMath.invariant(x + amountIn, y - out, amp);
        vm.assertGe(afterSwap + 2, before, "the invariant does not fall, to within the solver's last unit");

        uint256 back = StableMath.amountOut(y - out, x + amountIn, out, amp);
        vm.assertLe(back, amountIn, "there and back never returns more than was put in");
    }
}

contract StablePoolTest is PoolSetup {
    function setUp() public {
        a = new Token("USD-A");
        b = new Token("USD-B");
    }

    function _stable(uint256 amp) internal returns (V5Pool p) {
        p = new V5Pool(
            PoolConfig(address(a), address(b), 0.5e18, EPOCH, 0.0005e18, 0.1e18, type(uint256).max, amp, curve),
            _roles(),
            _hallConfig(),
            _feePolicyFor(0.0005e18)
        );
        _fund(alice, p);
        _fund(trader, p);
    }

    function _feePolicyFor(uint256 fee) internal pure returns (FeePolicy memory f) {
        f = _feePolicy();
        f.feeMinWad = fee * 4 / 10;
        f.feeMaxWad = fee;
    }

    function test_aPegPoolPaysFarMoreThanAWeightedOneForTheSameTrade() public {
        V5Pool peg = _stable(100);
        V5Pool plain = _stable(0);
        vm.startPrank(alice);
        peg.join(1_000_000e18, 1_000_000e18, 0, 0, alice);
        plain.join(1_000_000e18, 1_000_000e18, 0, 0, alice);
        vm.stopPrank();

        uint256 fromPeg = peg.quote(address(a), 200_000e18);
        uint256 fromPlain = plain.quote(address(a), 200_000e18);
        vm.assertGt(fromPeg, 199_000e18, "a fifth of the pool trades within half a percent of the peg");
        vm.assertLt(fromPlain, 167_000e18, "where a constant-product pool gives up a sixth");

        vm.prank(trader);
        vm.assertEq(peg.swap(address(a), 200_000e18, 0, trader), fromPeg, "and the swap pays exactly the quote");
        vm.assertEq(peg.feesInHall(0), 90e18, "with the LP share of the fee in the hall, not the reserves");
    }

    function test_tokensWithDifferentDecimalsTradeAtThePeg() public {
        a.setDecimals(6); // like USDC
        V5Pool peg = _stable(100);
        vm.prank(alice);
        peg.join(1_000_000e6, 1_000_000e18, 0, 0, alice);
        // 1,000 of the six-decimal token should buy just under 1,000 of the eighteen-decimal one.
        uint256 out = peg.quote(address(a), 1000e6);
        vm.assertGt(out, 999.4e18, "close to the peg, less the 0.05% fee");
        vm.assertLt(out, 999.5e18, "and not better than it");
        uint256 back = peg.quote(address(b), 1000e18);
        vm.assertGt(back, 999.4e6, "the same the other way");
        vm.assertLt(back, 999.5e6, "in the other token's units");
    }

    function test_aPegPoolMustBeBalancedByWeight() public {
        vm.expectRevert();
        new V5Pool(
            PoolConfig(address(a), address(b), 0.8e18, EPOCH, 0.0005e18, 0.1e18, type(uint256).max, 100, curve),
            _roles(),
            _hallConfig(),
            _feePolicyFor(0.0005e18)
        );
    }

    function test_seasoningWorksTheSameOnAPegPool() public {
        V5Pool peg = _stable(100);
        vm.prank(alice);
        (uint256 id,) = peg.join(1_000_000e18, 1_000_000e18, 0, 0, alice);
        vm.prank(trader);
        peg.swap(address(a), 100_000e18, 0, trader); // fee 50, of which 45 is the LPs'
        for (uint256 i; i < 4; ++i) {
            _nextEpoch();
        }
        vm.prank(alice);
        vm.assertApproxEqAbs(peg.collect(id)[0], 45e18, 1e6, "fees reach the LP through the hall as on any pool");
    }
}

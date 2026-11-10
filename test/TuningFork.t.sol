// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Token} from "./Base.sol";
import {PoolSetup} from "./V5Pool.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {EpochHall} from "../src/EpochHall.sol";
import {TuningFork} from "../src/TuningFork.sol";
import {DepegWatch} from "../src/DepegWatch.sol";

contract PretendFeed {
    uint256 public priceWad = 1e18;
    bool public broken;

    function set(uint256 p) external {
        priceWad = p;
    }
}

contract BrokenWatch {
    function depegged() external pure returns (bool) {
        revert("down");
    }
}

abstract contract ForkSetup is PoolSetup {
    uint256 constant BASE = 0.0005e18; // 0.05%
    TuningFork fork;
    PretendFeed feed;

    /// Pitch at the peg. Half the base fee toward it. Away from it, 0.1% of
    /// fee for each 1% of detune, at most 1%.
    function _policy() internal pure returns (TuningFork.Policy memory) {
        return TuningFork.Policy(1e18, address(0), 0.5e18, 0.1e18, 0.01e18);
    }

    function _pegPool(address model) internal returns (V5Pool p) {
        V5Pool.FeePolicy memory f = _feePolicy();
        f.feeMinWad = BASE * 4 / 10;
        f.feeMaxWad = BASE;
        f.feeModel = model;
        p = new V5Pool(
            V5Pool.PoolConfig(address(a), address(b), 0.5e18, EPOCH, BASE, 0.1e18, type(uint256).max, 100),
            _roles(),
            _hallConfig(),
            f
        );
        _fund(alice, p);
        _fund(bob, p);
        _fund(trader, p);
    }

    function _feesTaken(V5Pool p, uint256 k) internal view returns (uint256) {
        return p.feesInHall(k) + p.venueOwed(k);
    }
}

contract TuningForkTest is ForkSetup {
    function setUp() public {
        a = new Token("USD-A");
        b = new Token("USD-B");
        fork = new TuningFork(_policy(), configurer);
        feed = new PretendFeed();
    }

    // ------------------------------------------------------------------
    // The rate itself
    // ------------------------------------------------------------------

    function test_towardThePitchPaysTheFloor() public view {
        vm.assertEq(fork.feeFor(BASE, 0.98e18, 0.985e18, 0.99e18), BASE / 2, "rising toward the pitch from below");
        vm.assertEq(fork.feeFor(BASE, 1.03e18, 1.02e18, 1.01e18), BASE / 2, "falling toward it from above");
    }

    function test_awayFromThePitchPaysMoreTheFurtherItGoes() public view {
        // From the pitch to 1% above it: slivers at 0, 0.5% and 1% of detune.
        uint256 rate = fork.feeFor(BASE, 1e18, 1.005e18, 1.01e18);
        vm.assertEq(rate, BASE + 0.0005e18, "the base fee plus the average surcharge along the way");
        vm.assertGt(fork.feeFor(BASE, 1.01e18, 1.015e18, 1.02e18), rate, "the same move from further out costs more");
        vm.assertEq(fork.feeFor(BASE, 1.2e18, 1.25e18, 1.3e18), 0.01e18, "up to the cap");
    }

    function test_aTradeThatCrossesThePitchIsChargedForEachPartOfTheWay() public view {
        // From 1% below to 1% above: cheap until the pitch, dearer after it.
        uint256 rate = fork.feeFor(BASE, 0.99e18, 1e18, 1.01e18);
        vm.assertEq(rate, (BASE / 2 + 4 * BASE + BASE + 0.001e18) / 6, "floor, then base, then base plus the surcharge");
    }

    function test_thePitchCanComeFromOutside() public {
        TuningFork.Policy memory p = _policy();
        p.pitchSource = address(feed);
        vm.prank(configurer);
        fork.setPolicy(p);
        feed.set(1.05e18);
        vm.assertEq(fork.pitch(), 1.05e18, "the pitch follows the source");
        vm.assertEq(fork.feeFor(BASE, 1e18, 1.01e18, 1.02e18), BASE / 2, "so a rise from 1.00 is now a move toward it");
    }

    function test_theFloorCanNeverBeZeroAndOnlyTheConfigurerSetsThePolicy() public {
        TuningFork.Policy memory p = _policy();
        p.towardWad = 0;
        vm.prank(configurer);
        vm.expectRevert(TuningFork.BadPolicy.selector);
        fork.setPolicy(p);
        p.towardWad = 0.25e18;
        vm.prank(alice);
        vm.expectRevert(TuningFork.NotAllowed.selector);
        fork.setPolicy(p);
        vm.prank(configurer);
        fork.setPolicy(p);
        vm.assertEq(fork.policy().towardWad, 0.25e18, "set");
    }

    // ------------------------------------------------------------------
    // In a pool
    // ------------------------------------------------------------------

    function test_inAPoolRestoringThePegIsCheapAndWorseningItIsDear() public {
        V5Pool p = _pegPool(address(fork));
        vm.prank(alice);
        p.join(1_500_000e18, 500_000e18, 0, 0, alice); // off balance: token0 is cheap, the price is below the pitch
        vm.assertLt(p.price(), 0.99e18, "the pool starts below its pitch");

        uint256 before1 = _feesTaken(p, 1);
        vm.startPrank(trader);
        uint256 quoted = p.quote(address(b), 10_000e18);
        vm.assertEq(
            p.swap(address(b), 10_000e18, 0, trader), quoted, "the swap pays exactly the quote, fork or no fork"
        );
        uint256 restoring = _feesTaken(p, 1) - before1;
        vm.assertEq(
            restoring, 10_000e18 * BASE / 2 / WAD, "bringing token1 in moves toward the pitch: half the base fee"
        );

        uint256 before0 = _feesTaken(p, 0);
        p.swap(address(a), 10_000e18, 0, trader);
        uint256 worsening = _feesTaken(p, 0) - before0;
        vm.stopPrank();
        vm.assertGt(worsening, 10_000e18 * BASE / WAD, "bringing more token0 in moves away: more than the base fee");
        vm.assertLe(worsening, 10_000e18 * 0.01e18 / WAD, "and never more than the cap");
    }

    function test_withoutAFeeModelThePoolChargesThePlainFee() public {
        V5Pool p = _pegPool(address(0));
        vm.prank(alice);
        p.join(1_500_000e18, 500_000e18, 0, 0, alice);
        vm.prank(trader);
        p.swap(address(a), 10_000e18, 0, trader);
        vm.assertEq(_feesTaken(p, 0), 10_000e18 * BASE / WAD, "the base fee, whichever way it goes");
    }

    /// Cutting a trade in two must not be a way round the fee.
    function testFuzz_splittingATradeDoesNotDodgeTheFee(uint256 size, uint256 cut, bool away) public {
        size = bound(size, 1_000e18, 150_000e18);
        cut = bound(cut, 10, 90); // the first piece is this percent of the whole
        V5Pool whole = _pegPool(address(fork));
        V5Pool pieces = _pegPool(address(fork));
        vm.startPrank(alice);
        whole.join(1_300_000e18, 700_000e18, 0, 0, alice);
        pieces.join(1_300_000e18, 700_000e18, 0, 0, alice);
        vm.stopPrank();
        (address tokenIn, uint256 k) = away ? (address(a), 0) : (address(b), 1);

        vm.startPrank(trader);
        uint256 outWhole = whole.swap(tokenIn, size, 0, trader);
        uint256 first = size * cut / 100;
        uint256 outPieces = pieces.swap(tokenIn, first, 0, trader) + pieces.swap(tokenIn, size - first, 0, trader);
        vm.stopPrank();

        uint256 feeWhole = _feesTaken(whole, k);
        uint256 feePieces = _feesTaken(pieces, k);
        // The two totals agree to within a thousandth of the fee...
        vm.assertApproxEqAbs(feePieces, feeWhole, feeWhole / 1000 + 2, "fee paid in pieces against fee paid whole");
        // ...and the trader who split is no better off by more than a millionth of the trade.
        vm.assertLe(outPieces, outWhole + size / 1_000_000, "splitting buys no meaningful extra");
    }
}

contract DepegWatchTest is ForkSetup {
    DepegWatch watch;

    function setUp() public {
        a = new Token("USD-A");
        b = new Token("USD-B");
        feed = new PretendFeed();
        // On the peg within 2%. A depeg needs a full day outside, with readings no more than six hours apart.
        watch = new DepegWatch(DepegWatch.Settings(address(feed), 1e18, 0.02e18, 1 days, 6 hours), configurer);
    }

    function _observeFor(uint256 hours_) internal {
        for (uint256 i; i < hours_; i += 4) {
            _skip(4 hours);
            watch.observe();
        }
    }

    function test_aSingleBadReadingIsNotADepeg() public {
        feed.set(0.9e18);
        watch.observe();
        vm.assertTrue(!watch.depegged(), "one reading proves nothing");
        _skip(12 hours);
        watch.observe();
        vm.assertTrue(!watch.depegged(), "nor does half the window");
    }

    function test_aDayOutsideWithRegularReadingsIsADepeg() public {
        feed.set(0.9e18);
        watch.observe();
        _observeFor(24);
        vm.assertTrue(watch.depegged(), "a full window outside, watched throughout");
        feed.set(0.99e18);
        vm.assertTrue(!watch.depegged(), "and it ends the moment the price is back");
    }

    function test_aReadingBackInsideStartsTheClockOver() public {
        feed.set(0.9e18);
        watch.observe();
        _observeFor(20);
        feed.set(1e18);
        watch.observe(); // back on the peg
        feed.set(0.9e18);
        watch.observe(); // and off again
        _observeFor(8);
        vm.assertTrue(!watch.depegged(), "only eight hours into the new run");
    }

    function test_aLongSilenceStartsTheClockOver() public {
        feed.set(0.9e18);
        watch.observe();
        _skip(2 days); // nobody looked for two days
        vm.assertTrue(!watch.depegged(), "an unwatched stretch is not evidence");
        watch.observe();
        vm.assertTrue(!watch.depegged(), "and the next reading starts a new run");
        _observeFor(24);
        vm.assertTrue(watch.depegged(), "which has to last the whole window itself");
    }

    function test_withinToleranceIsNotOutside() public {
        vm.assertTrue(!watch.isOutside(0.98e18), "2% off is still on the peg");
        vm.assertTrue(watch.isOutside(0.9799e18), "a hair more is not");
        vm.assertTrue(watch.isOutside(1.03e18), "above counts as well as below");
    }

    function _poolWith(address depegWatch) internal returns (V5Pool p, uint256 locked) {
        p = _pegPool(address(0));
        V5Pool.Roles memory r = _roles();
        r.depegWatch = depegWatch;
        vm.prank(configurer);
        p.setRoles(r);
        vm.prank(alice);
        p.join(1_000_000e18, 1_000_000e18, 0, 0, alice);
        vm.prank(bob);
        (locked,) = p.join(1_000_000e18, 1_000_000e18, 0, 1, bob);
        vm.prank(trader);
        p.swap(address(a), 10_000e18, 0, trader);
        _nextEpoch();
    }

    function test_duringADepegALockedPositionLeavesFree() public {
        (V5Pool p, uint256 locked) = _poolWith(address(watch));
        vm.assertGt(p.tollOf(locked), 0, "in ordinary times leaving this lock costs something");
        feed.set(0.9e18);
        watch.observe();
        _observeFor(24);

        uint256 r0 = p.reserves(0);
        vm.prank(bob);
        (uint256 out0,) = p.exit(locked, 0, 0, bob);
        vm.assertApproxEqAbs(out0, r0 / 2, 1e6, "bob takes his full half: no toll");
        vm.assertEq(p.polOwed(0), 0, "and none of his held fees were forfeited");
    }

    function test_withoutADepegTheTollStands() public {
        (V5Pool p, uint256 locked) = _poolWith(address(watch));
        uint256 r0 = p.reserves(0);
        vm.prank(bob);
        (uint256 out0,) = p.exit(locked, 0, 0, bob);
        vm.assertLt(out0, r0 / 2 - 1e18, "he pays the toll");
    }

    function test_aWatchThatFailsCannotBlockAnExit() public {
        (V5Pool p, uint256 locked) = _poolWith(address(new BrokenWatch()));
        vm.prank(bob);
        (uint256 out0,) = p.exit(locked, 0, 0, bob);
        vm.assertGt(out0, 0, "the exit goes through, on ordinary terms");
    }
}

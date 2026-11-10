// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Token} from "./Base.sol";
import {PoolSetup} from "./V5Pool.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {PoolConfig, Roles, Terms, FeePolicy} from "../src/PoolTypes.sol";
import {EpochHall} from "../src/EpochHall.sol";
import {PoolCurve} from "../src/PoolCurve.sol";
import {FeeDesk} from "../src/FeeDesk.sol";
import {StableMath} from "../src/StableMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// A fee model that asks for half of every trade.
contract GreedyModel {
    function feeFor(uint256, uint256, uint256, uint256) external pure returns (uint256) {
        return 0.5e18;
    }
}

/// A desk that hands a pool whatever terms it is told to, and answers a
/// review however it is told to: with a fixed cut, or not at all.
contract LooseDesk {
    bool public broken;
    uint256 public answer;

    function open(FeePolicy calldata, uint256, uint256) external pure returns (uint256) {
        return type(uint64).max;
    }

    function push(V5Pool pool, Terms calldata t, uint256 reviewAt) external {
        pool.setTerms(t, reviewAt);
    }

    function set(bool broken_, uint256 answer_) external {
        (broken, answer) = (broken_, answer_);
    }

    function reviewCut(uint256, uint256, uint256, uint256) external view returns (uint256, uint256, uint256) {
        require(!broken, "down");
        return (answer, block.timestamp + 7 days, 0);
    }
}

abstract contract SplitSetup is PoolSetup {
    function _ready(V5Pool p) internal returns (V5Pool) {
        _fund(alice, p);
        _fund(bob, p);
        _fund(trader, p);
        return p;
    }

    function _swap(V5Pool p, Token tokenIn, uint256 amount) internal returns (uint256) {
        vm.prank(trader);
        return p.swap(address(tokenIn), amount, 0, trader);
    }

    function _near(int256 x, int256 y, uint256 tolerance, string memory what) internal pure {
        vm.assertLe(x > y ? uint256(x - y) : uint256(y - x), tolerance, what);
    }
}

contract PoolCurveTest is SplitSetup {
    function setUp() public {
        a = new Token("A");
        b = new Token("B");
    }

    function test_aPoolRefusesToOpenWithoutACurveOrADesk() public {
        Roles memory r = _roles();
        vm.expectRevert(EpochHall.BadConfig.selector);
        new V5Pool(
            PoolConfig(address(a), address(b), 0.5e18, EPOCH, 0.003e18, 0.1e18, 1e30, 0, address(0xC0DE)),
            r,
            _hallConfig(),
            _feePolicy()
        );
        r.desk = address(0xDE5C);
        vm.expectRevert(EpochHall.BadConfig.selector);
        new V5Pool(
            PoolConfig(address(a), address(b), 0.5e18, EPOCH, 0.003e18, 0.1e18, 1e30, 0, curve),
            r,
            _hallConfig(),
            _feePolicy()
        );
    }

    function test_thePegPriceIsTheStableCurvesWhicheverWayTheTradeFaces() public {
        V5Pool p = _ready(
            new V5Pool(
                PoolConfig(address(a), address(b), 0.5e18, EPOCH, 0.003e18, 0.1e18, 1e30, 100, curve),
                _roles(),
                _hallConfig(),
                _feePolicy()
            )
        );
        vm.prank(alice);
        p.join(1_000_000e18, 1_000_000e18, 0, 0, alice);
        _swap(p, a, 200_000e18);
        (uint256 r0, uint256 r1) = (p.reserves(0), p.reserves(1));
        vm.assertEq(p.price(), StableMath.price(r0, r1, 100), "the pool's price is the curve's");
        vm.assertLt(p.price(), 1e18, "token0 is the plentiful one, so it buys less than one of token1");

        // The same quote whether asked of the pool or of the curve directly.
        PoolCurve.Shape memory shape = PoolCurve.Shape(0.5e18, 100, 1, 1);
        (uint256 out,,) = PoolCurve(curve).quote(shape, r0, r1, 1, 1000e18, 0.003e18, address(0));
        vm.assertEq(p.quote(address(b), 1000e18), out, "the pool pays what the curve says");
        vm.assertEq(_swap(p, b, 1000e18), out, "and the swap pays the quote");
    }

    function test_noFeeModelCanChargeMoreThanTheCeiling() public {
        FeePolicy memory f = _feePolicy();
        f.feeModel = address(new GreedyModel());
        V5Pool p = _ready(_pool(0.5e18, 1e30, _hallConfig(), f));
        vm.prank(alice);
        p.join(1000e18, 1000e18, 0, 0, alice);
        _swap(p, a, 10e18);
        vm.assertEq(p.feesInHall(0) + p.venueOwed(0), 1e18, "a tenth, though the model asked for half");
    }

    function test_aPriceTooSmallToWriteDownStopsNothing() public {
        V5Pool p = _ready(_pool(0.5e18, type(uint256).max));
        vm.prank(alice);
        p.join(1e30, 1e6, 0, 0, alice);
        vm.assertEq(p.price(), 0, "a millionth of a unit of token1 per unit of token0 rounds to nothing");
        _skip(1 hours);
        vm.assertGt(_swap(p, b, 1e5), 0, "and the swap goes through all the same");
        vm.assertTrue(p.logPriceSum() < 0, "with the record holding the smallest price there is");
    }
}

contract PriceRecordTest is SplitSetup {
    V5Pool p;

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        p = _ready(_pool(0.5e18, type(uint256).max));
        vm.prank(alice);
        p.join(100_000e18, 100_000e18, 0, 0, alice);
        // Start away from a price of one, whose logarithm is nothing and would hide mistakes.
        _swap(p, a, 5000e18);
        _skip(1 hours);
    }

    function _log() internal view returns (int256) {
        return FixedPointMathLib.lnWad(int256(p.price()));
    }

    function test_theRecordIsThePriceWeightedByHowLongItStood() public {
        int256 start = p.logPriceSum();
        int256 logBefore = _log();
        uint256 priceBefore = p.price();
        vm.assertLt(priceBefore, 0.92e18, "it starts about a tenth below one");
        _skip(1 hours);
        _swap(p, b, 15_000e18); // token1 comes in: token0 now costs more of it
        int256 logAfter = _log();
        vm.assertGt(p.price(), 1.15e18, "and is moved well above it");
        _skip(3 hours);

        int256 mean = (p.logPriceSum() - start) / int256(4 hours);
        _near(mean, (logBefore + 3 * logAfter) / 4, 1e6, "one hour at the old price and three at the new");
        uint256 average = uint256(FixedPointMathLib.expWad(mean));
        vm.assertGt(average, priceBefore, "the geometric average sits between the two");
        vm.assertLt(average, p.price(), "between the two");
        vm.assertGt(average, 1e18, "nearer the price that stood longer");
    }

    function test_aPriceMovedAndPutBackInsideOneBlockLeavesNoMark() public {
        int256 before = p.logPriceSum();
        uint256 resting = p.price();
        uint256 got = _swap(p, b, 20_000e18);
        vm.assertGt(p.price(), resting * 14 / 10, "pushed far up");
        _swap(p, a, got);
        _near(int256(p.price()), int256(resting), 0.01e18, "and put back, less the fees");
        vm.assertEq(uint256(p.logPriceSum() - before), 0, "the record did not move in that block");

        int256 left = _log();
        _skip(1 hours);
        _near(p.logPriceSum() - before, left * int256(1 hours), 0, "and afterwards it runs at the price it was left at");
    }

    function test_theRecordIsWrittenOnceABlockAtThePriceFoundNotThePriceLeft() public {
        _skip(2 hours);
        // Brought up to now, the record already counts these hours at the price that stood through them.
        int256 before = p.logPriceSum();
        _swap(p, b, 10_000e18);
        vm.assertEq(
            uint256(p.logPriceSum() - before), 0, "the trade writes them at the price it found, not the one it left"
        );
        _swap(p, b, 1000e18);
        vm.assertEq(uint256(p.logPriceSum() - before), 0, "and a second trade in the block writes nothing");

        int256 left = _log();
        _skip(1 hours);
        _near(p.logPriceSum() - before, left * int256(1 hours), 0, "the price they left counts only from then on");
    }

    function test_joiningAndLeavingDoNotMoveThePriceOrTheRecord() public {
        _swap(p, b, 10_000e18);
        _skip(1 hours);
        uint256 price = p.price();
        int256 sum = p.logPriceSum();
        vm.prank(bob);
        (uint256 id,) = p.join(50_000e18, 50_000e18, 0, 0, bob);
        vm.prank(bob);
        p.exit(id, 0, 0, bob);
        _near(int256(p.price()), int256(price), 1e6, "in proportion, so the price stays put");
        _near(p.logPriceSum(), sum, 1e9, "and so does the record");
    }
}

contract FeeDeskTest is SplitSetup {
    V5Pool p;
    LooseDesk loose;

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        p = _ready(_pool(0.5e18, type(uint256).max));
        vm.prank(alice);
        p.join(1000e18, 1000e18, 0, 0, alice);
        loose = new LooseDesk();
    }

    function _handTo(address newDesk) internal {
        Roles memory r = _roles();
        r.desk = newDesk;
        vm.prank(configurer);
        p.setRoles(r);
    }

    function test_onlyTheDeskSetsTheTerms() public {
        Terms memory t = p.terms();
        t.feeWad = 0.001e18;
        vm.prank(configurer);
        vm.expectRevert(V5Pool.NotAllowed.selector);
        p.setTerms(t, 0);
        vm.prank(feeSetter);
        vm.expectRevert(V5Pool.NotAllowed.selector);
        p.setTerms(t, 0);
    }

    function test_thePoolRefusesTermsAboveItsOwnCeilingsWhoeverAsks() public {
        _handTo(address(loose));
        Terms memory t = p.terms();
        t.feeWad = 0.11e18;
        vm.expectRevert(EpochHall.BadConfig.selector);
        loose.push(p, t, 0);
        t.feeWad = 0.003e18;
        t.nextFeeWad = 0.11e18;
        vm.expectRevert(EpochHall.BadConfig.selector);
        loose.push(p, t, 0);
        t.nextFeeWad = 0;
        t.venueCutWad = 1e18 + 1;
        vm.expectRevert(EpochHall.BadConfig.selector);
        loose.push(p, t, 0);
        t.venueCutWad = 0.1e18;
        t.lockBudgetWad = 1e18 + 1;
        vm.expectRevert(EpochHall.BadConfig.selector);
        loose.push(p, t, 0);

        t.lockBudgetWad = 0;
        t.feeWad = 0.1e18;
        loose.push(p, t, type(uint64).max);
        vm.assertEq(p.feeWad(), 0.1e18, "the ceiling itself is allowed");
    }

    function test_aDeskThatDoesNotAnswerNeverStopsASwap() public {
        _handTo(address(loose));
        loose.set(true, 0);
        loose.push(p, p.terms(), vm.getBlockTimestamp()); // a review is due now
        vm.assertGt(_swap(p, a, 10e18), 0, "the swap goes through");
        vm.assertEq(p.venueCutWad(), 0.1e18, "the cut is where it was");
        (uint64 at,,) = p.review();
        vm.assertEq(at, vm.getBlockTimestamp() + 1 days, "and the desk is asked again tomorrow");

        _skip(1 days);
        loose.set(false, 2e18); // it answers, but with twice the whole
        _swap(p, a, 10e18);
        vm.assertEq(p.venueCutWad(), 0.1e18, "an answer above the whole changes nothing either");

        _skip(1 days);
        loose.set(false, 0.25e18);
        _swap(p, a, 10e18);
        vm.assertEq(p.venueCutWad(), 0.25e18, "a sound answer is taken");
        (at,,) = p.review();
        vm.assertEq(at, vm.getBlockTimestamp() + 7 days, "with the next review when the desk says");
    }

    function test_aNewPolicyPullsTheFeeAndTheCutInsideItsBounds() public {
        vm.prank(feeSetter);
        desk.queueFee(address(p), 0.002e18);

        FeePolicy memory f = _feePolicy();
        f.feeMaxWad = 0.0025e18; // below the fee in force
        f.cutMinWad = 0.2e18; // above the cut in force
        f.lockBudgetWad = 0.3e18;
        vm.prank(alice);
        vm.expectRevert(FeeDesk.NotAllowed.selector);
        desk.setPolicy(address(p), f);
        vm.prank(configurer);
        desk.setPolicy(address(p), f);

        vm.assertEq(p.feeWad(), 0.0025e18, "the fee comes down to the new cap at once");
        _skip(2 days);
        vm.assertEq(p.feeWad(), 0.0025e18, "and the change that was on its way is dropped");
        vm.assertEq(p.venueCutWad(), 0.2e18, "the cut comes up to the new floor");
        vm.assertEq(p.terms().lockBudgetWad, 0.3e18, "the lock budget reaches the pool");

        f.feeMaxWad = 0.11e18;
        vm.prank(configurer);
        vm.expectRevert(FeeDesk.BadPolicy.selector);
        desk.setPolicy(address(p), f); // no policy may reach above the ceiling
    }

    function test_switchingTheCutToSetItselfSchedulesItsReview() public {
        (uint64 at,,) = p.review();
        vm.assertEq(at, type(uint64).max, "a flat cut is never reviewed");
        _skip(3 days);
        FeePolicy memory f = _feePolicy();
        f.autoCut = true;
        vm.startPrank(configurer);
        desk.setPolicy(address(p), f);
        (at,,) = p.review();
        vm.assertEq(at, vm.getBlockTimestamp() + 4 days, "a week from when the pool opened");
        vm.expectRevert(FeeDesk.BadPolicy.selector);
        desk.setVenueCut(address(p), 0.2e18); // not by hand while it sets itself
        vm.stopPrank();
    }

    function test_withTheConfigurerGoneThePolicyIsFrozen() public {
        Roles memory r = _roles();
        r.configurer = address(0);
        vm.prank(configurer);
        p.setRoles(r);
        vm.prank(configurer);
        vm.expectRevert(FeeDesk.NotAllowed.selector);
        desk.setPolicy(address(p), _feePolicy());
        vm.prank(address(0));
        vm.expectRevert(V5Pool.NotAllowed.selector);
        p.setRoles(r);
        // The fee setter still works inside the frozen bounds.
        vm.prank(feeSetter);
        desk.queueFee(address(p), 0.002e18);
        _skip(1 days);
        vm.assertEq(p.feeWad(), 0.002e18, "the fee still moves inside them");
    }

    function test_aDeskThePoolHasLeftCanNoLongerTouchIt() public {
        FeeDesk next = new FeeDesk();
        _handTo(address(next));
        vm.prank(feeSetter);
        vm.expectRevert(V5Pool.NotAllowed.selector);
        desk.queueFee(address(p), 0.002e18); // the old desk is refused by the pool

        vm.prank(feeSetter);
        vm.expectRevert(FeeDesk.BadPolicy.selector);
        next.queueFee(address(p), 0.002e18); // the new one has no policy for this pool yet
        vm.prank(configurer);
        next.setPolicy(address(p), _feePolicy());
        vm.prank(feeSetter);
        next.queueFee(address(p), 0.002e18);
        _skip(1 days);
        vm.assertEq(p.feeWad(), 0.002e18, "and then it works as the first did");
    }

    function test_aPoolCannotBeHandedToADeskThatIsNotAContract() public {
        Roles memory r = _roles();
        r.desk = address(0xDE5C);
        vm.prank(configurer);
        vm.expectRevert(EpochHall.BadConfig.selector);
        p.setRoles(r);
    }
}

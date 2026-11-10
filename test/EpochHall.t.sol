// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Base} from "./Base.sol";
import {EpochHall} from "../src/EpochHall.sol";

/// The hall with its doors open, and ledgers in place of tokens.
contract HallHarness is EpochHall {
    mapping(address => uint256[2]) public paidTo;
    uint256[2] public polGot;
    uint256[2] public feesIn;

    constructor(HallConfig memory c) EpochHall(6 hours, c) {}

    function setHallConfig(HallConfig memory c) external {
        _setHallConfig(c);
    }

    function payLockers(uint256 k, uint256 amount) external returns (bool) {
        return _payLockers(k, amount);
    }

    function _payFee(uint256 k, address to, uint256 amount) internal override {
        paidTo[to][k] += amount;
    }

    function _creditPol(uint256 k, uint256 amount) internal override {
        polGot[k] += amount;
    }

    function open(address owner, uint256 shares, uint8 tier) external returns (uint256) {
        _current();
        return _open(owner, shares, tier);
    }

    function addFees(uint256 k, uint256 amount) external {
        _current();
        pending[k] += amount;
        feesIn[k] += amount;
    }

    function collect(uint256 id) external returns (uint256[2] memory) {
        _current();
        return _collect(id);
    }

    uint256[2] public compounded;

    /// Token 0's unlocked fees become shares, one for one, in whole units.
    function compound(uint256 id) external returns (uint256 added) {
        _current();
        Position storage p = _positions[id];
        added = _available(p)[0] / 1e18 * 1e18;
        if (added == 0) return 0;
        _spend(p, 0, added);
        compounded[0] += added;
        _grow(p, added);
    }

    function close(uint256 id, bool waived) external returns (uint256 shares, uint256 toll) {
        _current();
        (, shares, toll) = _close(id, waived);
    }

    function earnedOf(uint256 id, uint256 k) external returns (uint256) {
        _current();
        _settle(_positions[id]);
        return _positions[id].earned[k];
    }
}

contract EpochHallTest is Base {
    uint256 constant EPOCH = 6 hours;
    HallHarness hall;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        // The same settings as the simulator's named cases: floor 1/2, horizon 4, half unlocked at once, 1/4 to POL.
        hall = _hall(0.5e18, 4, 0.5e18, 0.25e18, 0, 0, false);
    }

    function _config(
        uint256 floor,
        uint256 horizon,
        uint256 u0,
        uint256 polShare,
        uint256 term,
        uint256 exitWad,
        bool skip
    ) internal pure returns (EpochHall.HallConfig memory) {
        return EpochHall.HallConfig(floor, horizon, u0, polShare, term, exitWad, 0, skip, 0);
    }

    function _hall(
        uint256 floor,
        uint256 horizon,
        uint256 u0,
        uint256 polShare,
        uint256 term,
        uint256 exitWad,
        bool skip
    ) internal returns (HallHarness) {
        return new HallHarness(_config(floor, horizon, u0, polShare, term, exitWad, skip));
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }

    /// sim/test_hall.py: test_early_exit_forfeit_goes_to_pol_and_seasoned_weight
    function test_earlyExitForfeitGoesToPolAndToThoseWhoStay() public {
        uint256 stay = hall.open(alice, 100e18, 0);
        uint256 go = hall.open(bob, 100e18, 0);
        hall.addFees(0, 80e18);
        _nextEpoch();

        hall.close(go, false); // age 1 of 4: 5/8 of its 40 is unlocked
        vm.assertEq(hall.paidTo(bob, 0), 25e18, "cash to the leaver");
        vm.assertEq(hall.polGot(0), 3.75e18, "a quarter of the 15 forfeited goes to POL");
        _nextEpoch();
        vm.assertEq(hall.earnedOf(stay, 0), 40e18 + 11.25e18, "the rest goes to the one who stayed");
    }

    function test_weightRisesInAStraightLineThenStops() public {
        uint256 id = hall.open(alice, 100e18, 0);
        uint256[6] memory want = [uint256(50e18), 62.5e18, 75e18, 87.5e18, 100e18, 100e18];
        for (uint256 i; i < 6; ++i) {
            hall.poke(type(uint256).max);
            vm.assertEq(hall.weightOf(id), want[i], "weight at this age");
            vm.assertEq(hall.totalWeight(), want[i], "total weight follows it");
            _nextEpoch();
        }
    }

    /// sim/test_hall.py: test_transfer_inside_the_horizon_keeps_age_and_held_fees
    function test_transferKeepsAgeAndHeldFees() public {
        HallHarness twin = _hall(0.5e18, 4, 0.5e18, 0.25e18, 0, 0, false);
        uint256 moved = hall.open(alice, 100e18, 0);
        uint256 kept = twin.open(alice, 100e18, 0);
        hall.open(bob, 400e18, 0);
        twin.open(bob, 400e18, 0);
        for (uint256 i; i < 7; ++i) {
            if (i == 2) {
                vm.prank(alice);
                hall.transferPosition(moved, address(0xCAFE));
            }
            hall.addFees(0, 80e18);
            twin.addFees(0, 80e18);
            _nextEpoch();
        }
        vm.assertEq(hall.earnedOf(moved, 0), twin.earnedOf(kept, 0), "the position earns the same");
        vm.assertEq(hall.ownerOf(moved), address(0xCAFE), "and has a new owner");
        vm.assertEq(hall.weightOf(moved), 100e18, "age travelled with it");
    }

    function test_mergeOfTwoMaturePositions() public {
        uint256 a = hall.open(alice, 100e18, 0);
        uint256 b = hall.open(alice, 50e18, 0);
        hall.open(bob, 70e18, 0);
        for (uint256 i; i < 6; ++i) {
            hall.addFees(1, 30e18);
            _nextEpoch();
        }
        uint256 before = hall.earnedOf(a, 1) + hall.earnedOf(b, 1);
        uint256 weightBefore = hall.totalWeight();
        vm.prank(alice);
        uint256 m = hall.merge(a, b);
        vm.assertEq(hall.totalWeight(), weightBefore, "merging changes no weight");
        vm.assertEq(hall.earnedOf(m, 1), before, "earnings carry over");
        vm.assertEq(hall.weightOf(m), 150e18, "weights add");
    }

    function test_mergeNeedsBothMature() public {
        uint256 a = hall.open(alice, 100e18, 0);
        uint256 b = hall.open(alice, 50e18, 0);
        _nextEpoch();
        vm.prank(alice);
        vm.expectRevert(EpochHall.NotMature.selector);
        hall.merge(a, b);
    }

    function test_waivedExitForfeitsNothing() public {
        hall.open(alice, 100e18, 0);
        uint256 go = hall.open(bob, 100e18, 0);
        hall.addFees(0, 80e18);
        _nextEpoch();
        hall.close(go, true);
        vm.assertEq(hall.paidTo(bob, 0), 40e18, "all of it, held or not");
        vm.assertEq(hall.polGot(0), 0, "nothing to POL");
    }

    function test_lockTollIsWrittenAtOpenAndMeltsToZero() public {
        HallHarness h = _hall(0.5e18, 4, 0.5e18, 0.25e18, 10, 0.1e18, false);
        uint256 id = h.open(alice, 100e18, 1);
        vm.assertEq(h.tollOf(id), 10e18, "full cost on day one");
        for (uint256 i; i < 5; ++i) {
            _nextEpoch();
        }
        h.poke(type(uint256).max);
        vm.assertEq(h.tollOf(id), 5e18, "half way, half the cost");
        for (uint256 i; i < 5; ++i) {
            _nextEpoch();
        }
        h.poke(type(uint256).max);
        vm.assertEq(h.tollOf(id), 0, "free at the end of the term");
        (, uint256 toll) = h.close(id, false);
        vm.assertEq(toll, 0, "and the close agrees");
    }

    function test_lockThatSkipsTheRampHasFullWeightAtOnceButNoMore() public {
        HallHarness h = _hall(0.5e18, 4, 0.5e18, 0.25e18, 10, 0.1e18, true);
        uint256 locked = h.open(alice, 100e18, 1);
        uint256 soft = h.open(bob, 100e18, 0);
        vm.assertEq(h.weightOf(locked), 100e18, "full weight from day one");
        vm.assertEq(h.weightOf(soft), 50e18, "the unlocked one starts at the floor");
        h.addFees(0, 90e18);
        _nextEpoch();
        vm.assertEq(h.earnedOf(locked, 0), 60e18, "two thirds of the first epoch");
        uint256[2] memory got = h.collect(locked);
        vm.assertEq(got[0], 60e18, "and none of it is held");
        for (uint256 i; i < 6; ++i) {
            _nextEpoch();
        }
        h.poke(type(uint256).max);
        vm.assertEq(h.weightOf(locked), 100e18, "never more than a seasoned position");
        vm.assertEq(h.weightOf(soft), 100e18, "which the other becomes");
    }

    function test_aTollThatNeverMeltsIsFlatUntilTheLockEnds() public {
        EpochHall.HallConfig memory c = _config(0.5e18, 4, 0.5e18, 0.25e18, 10, 0.1e18, false);
        c.lockMeltFloorWad = 1e18;
        HallHarness h = new HallHarness(c);
        uint256 id = h.open(alice, 100e18, 1);
        for (uint256 i; i < 9; ++i) {
            _nextEpoch();
        }
        h.poke(type(uint256).max);
        vm.assertEq(h.tollOf(id), 10e18, "still the full cost on the last day");
        _nextEpoch();
        h.poke(type(uint256).max);
        vm.assertEq(h.tollOf(id), 0, "and nothing once the lock has ended");
    }

    function test_aChangeOfSettingsReachesOnlyNewPositions() public {
        HallHarness h = _hall(0.5e18, 4, 0.5e18, 0.25e18, 10, 0.1e18, false);
        uint256 old = h.open(alice, 100e18, 1);
        // Everything gets harsher: a higher exit cost that never melts, a longer lock, a lower floor, a full hold.
        EpochHall.HallConfig memory c = _config(0.1e18, 8, 0, 0.25e18, 40, 0.5e18, false);
        c.lockMeltFloorWad = 1e18;
        h.setHallConfig(c);
        uint256 fresh = h.open(bob, 100e18, 1);

        vm.assertEq(h.tollOf(old), 10e18, "the open position keeps the cost it was opened with");
        vm.assertEq(h.weightOf(old), 50e18, "and its floor");
        vm.assertEq(h.positionOf(old).lockEnd, 10, "and its term");
        vm.assertEq(h.tollOf(fresh), 50e18, "the new one gets the new terms");
        vm.assertEq(h.weightOf(fresh), 10e18, "all of them");
        for (uint256 i; i < 10; ++i) {
            _nextEpoch();
        }
        h.poke(type(uint256).max);
        vm.assertEq(h.tollOf(old), 0, "and the old one is free on its original date");
        vm.assertEq(h.weightOf(old), 100e18, "fully seasoned on its original horizon");
    }

    function test_tollsPaidToLockersGoBySizeAndOnlyToThoseLockedBefore() public {
        HallHarness h = _hall(0.5e18, 4, 0.5e18, 0.25e18, 10, 0.1e18, false);
        vm.assertTrue(!h.payLockers(0, 5e18), "with nobody locked there is no one to pay");
        uint256 big = h.open(alice, 300e18, 1);
        uint256 small = h.open(bob, 100e18, 1);
        h.open(address(0xCAFE), 500e18, 0);
        vm.assertTrue(h.payLockers(0, 40e18), "now there is");
        uint256 late = h.open(address(0xD00D), 400e18, 1);

        vm.assertEq(h.collect(big)[0], 30e18, "three quarters to the larger lock");
        vm.assertEq(h.collect(small)[0], 10e18, "a quarter to the smaller");
        vm.assertEq(h.collect(late)[0], 0, "nothing to the one who locked afterwards");
    }

    function test_compoundingGrowsAPositionWithoutTouchingItsAge() public {
        uint256 id = hall.open(alice, 100e18, 0);
        hall.open(bob, 100e18, 0);
        hall.addFees(0, 64e18);
        _nextEpoch();
        _nextEpoch();
        // Age 2 of 4: weight is 3/4 of shares, and 3/4 of the 32 earned is unlocked.
        hall.poke(type(uint256).max);
        vm.assertEq(hall.weightOf(id), 75e18, "weight before");
        uint256 added = hall.compound(id);
        vm.assertEq(added, 24e18, "the unlocked fees, in whole units");
        vm.assertEq(hall.positionOf(id).shares, 124e18, "become shares");
        vm.assertEq(hall.weightOf(id), 93e18, "at the same 3/4 weight: the age did not move");
        vm.assertEq(hall.totalWeight(), 93e18 + 75e18, "and the hall's total follows");
        _nextEpoch();
        _nextEpoch();
        hall.poke(type(uint256).max);
        vm.assertEq(hall.weightOf(id), 124e18, "it matures on its original date, at its new size");
        vm.assertEq(hall.compound(id), 8e18, "and the fees that were held can be compounded once they unlock");
    }

    function test_hardTierUnavailableWhenSwitchedOff() public {
        vm.expectRevert(EpochHall.TierUnavailable.selector);
        hall.open(alice, 1e18, 1);
    }

    function test_idlePoolCatchesUpInSteps() public {
        uint256 id = hall.open(alice, 100e18, 0);
        hall.addFees(0, 10e18);
        vm.warp(block.timestamp + 1000 * EPOCH);
        hall.poke(300);
        vm.assertEq(hall.epoch(), 300, "bounded work per call");
        hall.poke(type(uint256).max);
        vm.assertEq(hall.epoch(), 1000, "then all the way");
        vm.assertEq(hall.earnedOf(id, 0), 10e18, "and nothing was lost on the way");
    }

    // ------------------------------------------------------------------
    // Against brute force
    // ------------------------------------------------------------------

    struct Ref {
        bool live;
        uint256 id;
        uint256 start;
        uint256 base;
        uint256 perEpoch;
        uint256 earnedScaled; // WAD-scaled, never rounded
        uint256 shares;
    }

    struct Run {
        HallHarness h;
        Ref[] refs;
        uint256 n;
        uint256 pendingRef;
        uint256 horizon;
        uint256 floor;
        uint256 seed;
    }

    /// Random opens, exits, collections and fees. A slow calculation that
    /// walks every position every epoch must agree with the hall.
    function testFuzz_matchesBruteForce(uint256 seed, uint8 horizonRaw, uint8 floorRaw) public {
        Run memory r;
        r.seed = seed;
        r.horizon = bound(horizonRaw, 1, 9);
        r.floor = bound(floorRaw, 0, 9) * 0.1e18;
        r.h = _hall(r.floor, r.horizon, 0.3e18, 0.25e18, 0, 0, false);
        r.refs = new Ref[](80);

        for (uint256 e; e < 30; ++e) {
            _act(r, e);
            uint256 fee = (_rand(seed, e, 99) % 500) * 1e18;
            r.h.addFees(0, fee);
            r.pendingRef += fee;
            _slowEpoch(r, e);
            _nextEpoch();
        }
        _finalChecks(r);
    }

    function _act(Run memory r, uint256 e) internal {
        uint256 ops = _rand(r.seed, e, 0) % 4;
        for (uint256 j; j < ops && r.n < 80; ++j) {
            uint256 x = _rand(r.seed, e, j + 1);
            if (x % 3 != 0 || r.n == 0) {
                uint256 shares = (1 + (x >> 8) % 1000) * 1e18;
                uint256 base = shares * r.floor / WAD;
                r.refs[r.n] = Ref(true, r.h.open(alice, shares, 0), e, base, (shares - base) / r.horizon, 0, shares);
                ++r.n;
                continue;
            }
            Ref memory pos = r.refs[(x >> 8) % r.n];
            if (!pos.live) continue;
            uint256 choice = (x >> 4) % 3;
            if (choice == 0) {
                r.h.collect(pos.id);
                continue;
            }
            if (choice == 1) {
                // Compounding grows the position where it stands: same age, more weight.
                uint256 added = r.h.compound(pos.id);
                Ref memory grown = r.refs[(x >> 8) % r.n];
                grown.base += grown.base * added / grown.shares;
                grown.perEpoch += grown.perEpoch * added / grown.shares;
                grown.shares += added;
                continue;
            }
            // Leaving: check the hall against the slow sum, then hand back the forfeit.
            uint256 earned = r.h.earnedOf(pos.id, 0);
            vm.assertApproxEqAbs(earned, pos.earnedScaled / WAD, 30, "earned at exit");
            uint256 age = e - pos.start < r.horizon ? e - pos.start : r.horizon;
            uint256 held = earned - earned * (0.3e18 + 0.7e18 * age / r.horizon) / WAD;
            r.h.close(pos.id, false);
            r.pendingRef += held - held * 0.25e18 / WAD;
            r.refs[(x >> 8) % r.n].live = false;
        }
    }

    /// The slow way: every live position, this epoch.
    function _slowEpoch(Run memory r, uint256 e) internal view {
        uint256 total;
        for (uint256 i; i < r.n; ++i) {
            if (r.refs[i].live) total += _refWeight(r.refs[i], e, r.horizon);
        }
        vm.assertEq(r.h.totalWeight(), total, "total weight");
        if (total == 0 || r.pendingRef == 0) return;
        uint256 perWeight = r.pendingRef * WAD / total;
        for (uint256 i; i < r.n; ++i) {
            if (r.refs[i].live) r.refs[i].earnedScaled += _refWeight(r.refs[i], e, r.horizon) * perWeight;
        }
        r.pendingRef -= (perWeight * total + WAD - 1) / WAD;
    }

    function _finalChecks(Run memory r) internal {
        uint256 stillHeld;
        for (uint256 i; i < r.n; ++i) {
            if (!r.refs[i].live) continue;
            uint256 earned = r.h.earnedOf(r.refs[i].id, 0);
            vm.assertApproxEqAbs(earned, r.refs[i].earnedScaled / WAD, 30, "earned at the end");
            vm.assertLe(earned, r.refs[i].earnedScaled / WAD, "rounding is never in the position's favour");
            stillHeld += earned - r.h.positionOf(r.refs[i].id).paid[0];
        }
        uint256 accounted = r.h.paidTo(alice, 0) + stillHeld + r.h.polGot(0) + r.h.pending(0) + r.h.compounded(0);
        vm.assertLe(accounted, r.h.feesIn(0), "never pays out more than came in");
        vm.assertGe(accounted + 3000, r.h.feesIn(0), "and loses only dust");
    }

    function _refWeight(Ref memory x, uint256 e, uint256 horizon) internal pure returns (uint256) {
        uint256 age = e - x.start < horizon ? e - x.start : horizon;
        return x.base + x.perEpoch * age;
    }

    function _rand(uint256 seed, uint256 a, uint256 b) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, a, b)));
    }
}

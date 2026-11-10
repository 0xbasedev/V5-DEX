// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Token} from "./Base.sol";
import {PoolSetup} from "./V5Pool.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {EpochHall} from "../src/EpochHall.sol";
import {TokenLock} from "../src/TokenLock.sol";
import {Gauges, ILockForGauges} from "../src/Gauges.sol";

abstract contract LockSetup is PoolSetup {
    uint256 constant YEAR = 365 * 4; // epochs
    Token tkn;
    TokenLock locks;
    Gauges gauges;
    address burnSink = address(0xB024);
    address sink = address(0x51CC);

    /// Locks of a quarter to two years. Leaving on day one costs half, melting
    /// to nothing; a fifth of that is burned and the rest goes to those who stayed.
    function _lockConfig() internal pure returns (EpochHall.HallConfig memory c) {
        c.floorWad = 1e18;
        c.horizon = 1;
        c.unlockedAtZeroWad = 1e18;
        c.lockExitWad = 0.5e18;
        c.lockSkipsRamp = true;
        c.tollPolShareWad = 0.2e18;
    }

    function _deployLocks() internal {
        a = new Token("USD");
        b = new Token("OTHER");
        tkn = new Token("TKN");
        locks = new TokenLock(address(a), address(tkn), burnSink, EPOCH, _lockConfig(), YEAR / 4, 2 * YEAR, configurer);
        // Any one pool may take at most 60% of a week's budget; a bribe lasts four weeks.
        gauges = new Gauges(ILockForGauges(address(locks)), address(a), 0.6e18, 4, sink, configurer);
        address[3] memory who = [alice, bob, trader];
        for (uint256 i; i < 3; ++i) {
            tkn.mint(who[i], 1e30);
            a.mint(who[i], 1e30);
            b.mint(who[i], 1e30);
            vm.startPrank(who[i]);
            tkn.approve(address(locks), type(uint256).max);
            a.approve(address(locks), type(uint256).max);
            a.approve(address(gauges), type(uint256).max);
            b.approve(address(gauges), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _lock(address who, uint256 amount, uint256 epochs) internal returns (uint256 id) {
        vm.prank(who);
        id = locks.lock(amount, epochs, who);
    }
}

contract TokenLockTest is LockSetup {
    function setUp() public {
        _deployLocks();
    }

    function test_aLongerLockWeighsMore() public {
        uint256 long = _lock(alice, 1000e18, 2 * YEAR);
        uint256 short = _lock(bob, 1000e18, YEAR / 2);
        vm.assertEq(locks.weightOf(long), 1000e18, "the longest lock counts in full");
        vm.assertEq(locks.weightOf(short), 250e18, "a quarter of the length, a quarter of the weight");

        vm.prank(trader);
        locks.addFees(500e18, 0);
        _nextEpoch();
        vm.prank(alice);
        vm.assertEq(locks.collect(long)[0], 400e18, "fees follow weight: four fifths");
        vm.prank(bob);
        vm.assertEq(locks.collect(short)[0], 100e18, "and one fifth");
    }

    function test_lockLengthsAreBounded() public {
        vm.startPrank(alice);
        vm.expectRevert(TokenLock.BadLength.selector);
        locks.lock(1e18, YEAR / 4 - 1, alice);
        vm.expectRevert(TokenLock.BadLength.selector);
        locks.lock(1e18, 2 * YEAR + 1, alice);
        vm.stopPrank();
    }

    function test_leavingEarlyCostsLessAsTheLockRunsAndTheCostIsSplit() public {
        uint256 stays = _lock(alice, 1000e18, YEAR);
        uint256 leaves = _lock(bob, 1000e18, YEAR);
        vm.assertEq(locks.exitCostOf(leaves), 500e18, "half on day one");
        _skip(EPOCH * YEAR / 2);
        locks.poke(type(uint256).max);
        vm.assertEq(locks.exitCostOf(leaves), 250e18, "a quarter half way through");

        uint256 before = tkn.balanceOf(bob);
        vm.prank(bob);
        vm.assertEq(locks.unlock(leaves), 750e18, "he gets the rest back");
        vm.assertEq(tkn.balanceOf(bob) - before, 750e18, "in his wallet");
        vm.assertEq(tkn.balanceOf(burnSink), 50e18, "a fifth of the cost is burned");
        vm.prank(alice);
        vm.assertEq(locks.collect(stays)[1], 200e18, "the rest goes to the locker who stayed");
    }

    function test_ifNobodyStayedTheWholeCostIsBurned() public {
        uint256 only = _lock(bob, 1000e18, YEAR);
        vm.prank(bob);
        locks.unlock(only);
        vm.assertEq(tkn.balanceOf(burnSink), 500e18, "there was nobody else to pay it to");
        vm.assertEq(locks.totalLocked(), 0, "and the lock is empty");
    }

    function test_aLockThatHasRunItsTermLeavesFreeAndCanBeClosedByAnyone() public {
        uint256 id = _lock(alice, 1000e18, YEAR / 4);
        vm.prank(bob);
        vm.expectRevert(TokenLock.StillLocked.selector);
        locks.kick(id);
        _skip(EPOCH * YEAR / 4);
        vm.assertEq(locks.votingWeight(id), 0, "once it has run it no longer votes");
        uint256 before = tkn.balanceOf(alice);
        vm.prank(bob);
        locks.kick(id); // anyone may close it; the tokens go to the owner
        vm.assertEq(tkn.balanceOf(alice) - before, 1000e18, "returned in full to its owner");
    }

    function test_onlyTheOwnerUnlocksAndLocksCannotBeMerged() public {
        uint256 one = _lock(alice, 1000e18, YEAR);
        uint256 two = _lock(alice, 1000e18, YEAR);
        vm.prank(bob);
        vm.expectRevert(EpochHall.NotOwner.selector);
        locks.unlock(one);
        vm.prank(alice);
        vm.expectRevert(TokenLock.NotAllowed.selector);
        locks.merge(one, two);
    }

    function test_aLockCanBeSoldAndKeepsItsTerms() public {
        uint256 id = _lock(alice, 1000e18, YEAR);
        vm.prank(alice);
        locks.transferPosition(id, bob);
        _skip(EPOCH * YEAR);
        vm.prank(bob);
        vm.assertEq(locks.unlock(id), 1000e18, "the buyer collects the tokens when it ends");
    }
}

contract GaugesTest is LockSetup {
    V5Pool poolOne;
    V5Pool poolTwo;
    uint256 big;
    uint256 small;

    function setUp() public {
        _deployLocks();
        poolOne = _pool(0.5e18, type(uint256).max);
        poolTwo = _pool(0.5e18, type(uint256).max);
        b.mint(alice, 1e30);
        vm.startPrank(alice);
        a.approve(address(poolOne), type(uint256).max);
        b.approve(address(poolOne), type(uint256).max);
        a.approve(address(poolTwo), type(uint256).max);
        b.approve(address(poolTwo), type(uint256).max);
        poolOne.join(1000e18, 1000e18, 0, 0, alice);
        poolTwo.join(1000e18, 1000e18, 0, 0, alice);
        vm.stopPrank();
        vm.startPrank(configurer);
        gauges.setListed(address(poolOne), true);
        gauges.setListed(address(poolTwo), true);
        vm.stopPrank();
        big = _lock(alice, 3000e18, 2 * YEAR); // weight 3000
        small = _lock(bob, 1000e18, 2 * YEAR); // weight 1000
    }

    function _one(address p) internal pure returns (address[] memory pools, uint256[] memory shares) {
        pools = new address[](1);
        shares = new uint256[](1);
        (pools[0], shares[0]) = (p, 1e18);
    }

    function test_votesDirectTheBoostBudgetToPoolsAsFees() public {
        vm.prank(trader);
        gauges.fund(1000e18);
        (address[] memory p1, uint256[] memory s1) = _one(address(poolOne));
        (address[] memory p2, uint256[] memory s2) = _one(address(poolTwo));
        vm.prank(alice);
        gauges.vote(big, p2, s2); // 3000 for pool two
        vm.prank(bob);
        gauges.vote(small, p1, s1); // 1000 for pool one
        vm.assertEq(gauges.shareOf(0, address(poolTwo)), 0.75e18, "three quarters of the vote");

        vm.expectRevert(Gauges.WeekNotOver.selector);
        gauges.boost(0, address(poolOne));
        _skip(7 days);
        vm.assertEq(gauges.boost(0, address(poolOne)), 250e18, "a quarter of the vote, a quarter of the budget");
        vm.assertEq(gauges.boost(0, address(poolTwo)), 600e18, "three quarters of the vote, but capped at 60%");
        vm.assertEq(poolTwo.feesInHall(0), 600e18, "paid into the pool's hall as fees for its LPs");
        vm.expectRevert(Gauges.AlreadyDone.selector);
        gauges.boost(0, address(poolTwo));

        // What the cap held back rolls on.
        _skip(7 days);
        gauges.rollOver(0);
        vm.assertEq(gauges.budget(2), 150e18, "the 150 the cap held back is in the current week's budget");
        vm.expectRevert(Gauges.AlreadyDone.selector);
        gauges.rollOver(0);
    }

    function test_aVoteCanBeSplitAndMustAddUp() public {
        address[] memory pools = new address[](2);
        uint256[] memory shares = new uint256[](2);
        (pools[0], pools[1]) = (address(poolOne), address(poolTwo));
        (shares[0], shares[1]) = (0.3e18, 0.6e18);
        vm.startPrank(alice);
        vm.expectRevert(Gauges.BadVote.selector);
        gauges.vote(big, pools, shares); // sums to 90%
        shares[1] = 0.7e18;
        gauges.vote(big, pools, shares);
        vm.expectRevert(Gauges.AlreadyVoted.selector);
        gauges.vote(big, pools, shares); // one vote per lock per week
        vm.stopPrank();
        vm.assertEq(gauges.votesFor(0, address(poolOne)), 900e18, "30% of 3000");
        vm.assertEq(gauges.votesFor(0, address(poolTwo)), 2100e18, "70% of 3000");
    }

    function test_onlyListedPoolsAndOnlyTheLocksOwnerAndOnlyLocksThatOutlastTheWeek() public {
        V5Pool stranger = _pool(0.5e18, type(uint256).max);
        (address[] memory ps, uint256[] memory ss) = _one(address(stranger));
        vm.prank(alice);
        vm.expectRevert(Gauges.NotListed.selector);
        gauges.vote(big, ps, ss);

        (address[] memory p1, uint256[] memory s1) = _one(address(poolOne));
        vm.prank(bob);
        vm.expectRevert(Gauges.NotAllowed.selector);
        gauges.vote(big, p1, s1); // not his lock

        // A lock about to end cannot vote: its tokens could leave free and vote again.
        uint256 brief = _lock(trader, 1000e18, YEAR / 4);
        _skip(EPOCH * YEAR / 4 - 2 hours); // it ends later this same week
        vm.prank(trader);
        vm.expectRevert(Gauges.BadVote.selector);
        gauges.vote(brief, p1, s1);
    }

    function test_aBribeIsSharedByThoseWhoVotedForThePool() public {
        vm.prank(trader);
        gauges.bribe(address(poolOne), address(b), 400e18);
        (address[] memory p1, uint256[] memory s1) = _one(address(poolOne));
        vm.prank(alice);
        gauges.vote(big, p1, s1);
        vm.prank(bob);
        gauges.vote(small, p1, s1);

        vm.expectRevert(Gauges.WeekNotOver.selector);
        gauges.claimBribe(0, address(poolOne), address(b), big);
        _skip(7 days);
        uint256 before = b.balanceOf(alice);
        vm.assertEq(gauges.claimBribe(0, address(poolOne), address(b), big), 300e18, "three quarters of the votes");
        vm.assertEq(b.balanceOf(alice) - before, 300e18, "paid to the voter");
        vm.expectRevert(Gauges.AlreadyDone.selector);
        gauges.claimBribe(0, address(poolOne), address(b), big);

        // Bob never collects. After four weeks his share decays to the sink.
        vm.expectRevert(Gauges.NotYet.selector);
        gauges.sweepBribe(0, address(poolOne), address(b));
        _skip(5 * 7 days);
        vm.assertEq(gauges.sweepBribe(0, address(poolOne), address(b)), 100e18, "the uncollected quarter");
        vm.assertEq(b.balanceOf(sink), 100e18, "goes to the buyback path");
        vm.expectRevert(Gauges.AlreadyDone.selector);
        gauges.claimBribe(0, address(poolOne), address(b), small);
    }

    function test_aBribeStillReachesAVoterWhoHasSinceClosedTheirLock() public {
        vm.prank(trader);
        gauges.bribe(address(poolOne), address(b), 400e18);
        (address[] memory p1, uint256[] memory s1) = _one(address(poolOne));
        vm.prank(bob);
        gauges.vote(small, p1, s1);
        _skip(7 days);
        vm.prank(bob);
        locks.unlock(small); // he pays to leave, and the lock no longer exists
        uint256 before = b.balanceOf(bob);
        gauges.claimBribe(0, address(poolOne), address(b), small);
        vm.assertEq(b.balanceOf(bob) - before, 400e18, "the bribe goes to who cast the vote");
    }

    function test_withNoVotesTheWholeBudgetRollsOn() public {
        vm.prank(trader);
        gauges.fund(1000e18);
        _skip(14 days);
        gauges.rollOver(0);
        vm.assertEq(gauges.budget(2), 1000e18, "nothing was handed out, so all of it moves on");
        vm.expectRevert(Gauges.AlreadyDone.selector);
        gauges.boost(0, address(poolOne)); // and a week that has rolled on can no longer pay
    }
}

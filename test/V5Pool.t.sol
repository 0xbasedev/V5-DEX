// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Base, Token} from "./Base.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {EpochHall} from "../src/EpochHall.sol";

abstract contract PoolSetup is Base {
    uint256 constant EPOCH = 6 hours;
    Token a;
    Token b;
    address venue = address(0xFEE);
    address pol = address(0x901);
    address guardian = address(0x6A4D);
    address capRaiser = address(0xCA9);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address trader = address(0x7DE);

    function _pool(uint256 weight0, uint256 cap) internal returns (V5Pool p) {
        p = new V5Pool(
            V5Pool.PoolConfig(address(a), address(b), weight0, 0.003e18, 0.1e18, venue, pol, guardian, capRaiser, cap),
            // floor 1/2, horizon 4 epochs, half unlocked at once, 1/4 of forfeits to POL, 10-epoch lock at 10%
            EpochHall.HallConfig(EPOCH, 0.5e18, 4, 0.5e18, 0.25e18, 10, 0.1e18, false)
        );
    }

    function _fund(address who, V5Pool p) internal {
        a.mint(who, 1e30);
        b.mint(who, 1e30);
        vm.startPrank(who);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        vm.stopPrank();
    }

    function _nextEpoch() internal {
        vm.warp(block.timestamp + EPOCH);
    }
}

contract V5PoolTest is PoolSetup {
    V5Pool pool;

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        pool = _pool(0.5e18, type(uint256).max);
        _fund(alice, pool);
        _fund(bob, pool);
        _fund(trader, pool);
    }

    function _join(address who, uint256 amount, uint8 tier) internal returns (uint256 id) {
        vm.prank(who);
        (id,) = pool.join(amount, amount, 0, tier, who);
    }

    function test_joinOpensAPositionInProportion() public {
        uint256 first = _join(alice, 1000e18, 0);
        vm.assertEq(pool.positionOf(first).shares, 1000e18 - 1000, "first join, less the dead shares");
        vm.prank(bob);
        (uint256 second, uint256 shares) = pool.join(500e18, 9999e18, 0, 0, bob);
        vm.assertEq(shares, 500e18, "half as much, half the shares");
        vm.assertEq(pool.reserves(1), 1500e18, "only the proportional amount of the other token is taken");
        vm.assertEq(pool.ownerOf(second), bob, "and bob holds the position");
    }

    function test_swapPaysTheQuoteAndFeesNeverEnterReserves() public {
        _join(alice, 1000e18, 0);
        uint256 quoted = pool.quote(address(a), 10e18);
        uint256 kBefore = pool.reserves(0) * pool.reserves(1);
        vm.prank(trader);
        uint256 got = pool.swap(address(a), 10e18, 0, trader);

        vm.assertEq(got, quoted, "the swap pays exactly the quote");
        vm.assertEq(pool.reserves(0), 1000e18 + 10e18 - 0.03e18, "reserves take the amount in less the whole fee");
        vm.assertEq(pool.venueOwed(0), 0.003e18, "a tenth of the fee is the venue's");
        vm.assertEq(pool.feesInHall(0), 0.027e18, "the rest is in the hall for LPs");
        vm.assertGe(pool.reserves(0) * pool.reserves(1), kBefore, "the curve never loses value to a swap");
    }

    function test_feesArePaidBySeasonedWeightAndHeldWhileSeasoning() public {
        uint256 id = _join(alice, 1000e18, 0);
        vm.prank(trader);
        pool.swap(address(a), 100e18, 0, trader);
        _nextEpoch();

        // One LP, so all 0.27 of the LP fee is hers; at age 1 of 4, 5/8 of it is unlocked.
        vm.prank(alice);
        uint256[2] memory got = pool.collect(id);
        vm.assertApproxEqAbs(got[0], 0.27e18 * 5 / 8, 1e6, "the unlocked part");
        for (uint256 i; i < 3; ++i) _nextEpoch();
        vm.prank(alice);
        got = pool.collect(id);
        vm.assertApproxEqAbs(got[0], 0.27e18 * 3 / 8, 1e6, "the rest unlocks by the horizon");
    }

    function test_earlyExitForfeitsHeldFeesToPolAndToThoseWhoStay() public {
        uint256 stay = _join(alice, 1000e18, 0);
        uint256 go = _join(bob, 1000e18, 0);
        vm.prank(trader);
        pool.swap(address(a), 100e18, 0, trader);
        _nextEpoch();

        uint256 before = a.balanceOf(bob);
        vm.prank(bob);
        (uint256 out0,) = pool.exit(go, 0, 0, bob);
        // Bob's half of the 0.27 is 0.135; 5/8 unlocked, 3/8 forfeited.
        vm.assertApproxEqAbs(a.balanceOf(bob) - before - out0, 0.135e18 * 5 / 8, 1e6, "his unlocked fees");
        vm.assertApproxEqAbs(pool.polOwed(0), 0.135e18 * 3 / 8 / 4, 1e6, "a quarter of the forfeit to POL");
        _nextEpoch();
        vm.prank(alice);
        pool.collect(stay);
        for (uint256 i; i < 3; ++i) _nextEpoch();
        vm.prank(alice);
        pool.collect(stay);
        uint256 hers = pool.positionOf(stay).paid[0];
        vm.assertApproxEqAbs(hers, 0.135e18 + 0.135e18 * 3 / 8 * 3 / 4, 1e6, "the rest reaches the one who stayed");
    }

    function test_lockTollNeverExceedsTheRateWrittenAtOpenAndGoesToStayers() public {
        _join(alice, 1000e18, 0);
        uint256 locked = _join(bob, 1000e18, 1);
        for (uint256 i; i < 5; ++i) _nextEpoch(); // half way through a 10-epoch lock at 10%

        vm.prank(bob);
        (uint256 out0, uint256 out1) = pool.exit(locked, 0, 0, bob);
        vm.assertApproxEqAbs(out0, 950e18, 1e6, "he pays half of 10% of his half");
        vm.assertEq(out0, out1, "on both sides");
        vm.assertGe(out0, 900e18, "never more than the rate written at open");
        vm.assertApproxEqAbs(pool.polOwed(0), 12.5e18, 1e6, "a quarter of the toll to POL");
        vm.assertApproxEqAbs(pool.feesInHall(0), 37.5e18, 1e6, "the rest to the LPs who stay");
        vm.assertApproxEqAbs(pool.reserves(0), 1000e18, 1e6, "and alice's liquidity is untouched");
    }

    function test_pauseStopsSwapsAndJoinsButNeverAnExit() public {
        _join(alice, 1000e18, 0);
        uint256 locked = _join(bob, 1000e18, 1);
        vm.prank(trader);
        pool.swap(address(a), 100e18, 0, trader);
        _nextEpoch();

        vm.prank(alice);
        vm.expectRevert(V5Pool.NotAllowed.selector);
        pool.setPaused(true);
        vm.prank(guardian);
        pool.setPaused(true);

        vm.prank(trader);
        vm.expectRevert(V5Pool.Paused.selector);
        pool.swap(address(a), 1e18, 0, trader);
        vm.prank(alice);
        vm.expectRevert(V5Pool.Paused.selector);
        pool.join(1e18, 1e18, 0, 0, alice);

        uint256 before = a.balanceOf(bob);
        vm.prank(bob);
        (uint256 out0,) = pool.exit(locked, 0, 0, bob);
        vm.assertApproxEqAbs(out0, pool.reserves(0), 1e6, "a locked position leaves with its full half: no toll");
        vm.assertGt(a.balanceOf(bob) - before - out0, 0, "and with its held fees");
        vm.assertEq(pool.polOwed(0), 0, "nothing was forfeited");
    }

    function test_depositCapOnlyGoesUp() public {
        V5Pool capped = _pool(0.5e18, 1500e18);
        _fund(alice, capped);
        vm.startPrank(alice);
        capped.join(1000e18, 1000e18, 0, 0, alice);
        vm.expectRevert(V5Pool.OverCap.selector);
        capped.join(600e18, 600e18, 0, 0, alice);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(V5Pool.NotAllowed.selector);
        capped.raiseCap(5000e18);
        vm.prank(capRaiser);
        vm.expectRevert(V5Pool.NotAllowed.selector);
        capped.raiseCap(1000e18);
        vm.prank(capRaiser);
        capped.raiseCap(5000e18);
        vm.prank(alice);
        capped.join(600e18, 600e18, 0, 0, alice);
    }

    function test_onlyTheOwnerCanExitOrCollect() public {
        uint256 id = _join(alice, 1000e18, 0);
        vm.startPrank(bob);
        vm.expectRevert(EpochHall.NotOwner.selector);
        pool.exit(id, 0, 0, bob);
        vm.expectRevert(EpochHall.NotOwner.selector);
        pool.collect(id);
        vm.stopPrank();
    }

    function test_aSwapCannotTakeTooMuchOfTheReserve() public {
        _join(alice, 1000e18, 0);
        vm.prank(trader);
        vm.expectRevert(V5Pool.TooMuchIn.selector);
        pool.swap(address(a), 400e18, 0, trader);
    }

    function test_sweepSendsTheVenueAndPolTheirShare() public {
        _join(alice, 1000e18, 0);
        vm.prank(trader);
        pool.swap(address(a), 100e18, 0, trader);
        pool.sweep();
        vm.assertEq(a.balanceOf(venue), 0.03e18, "venue cut");
        vm.assertEq(pool.venueOwed(0), 0, "and nothing left owing");
    }

    function testFuzz_thereAndBackNeverProfits(uint256 amountIn, uint8 weightRaw) public {
        V5Pool p = _pool(bound(weightRaw, 2, 8) * 0.1e18, type(uint256).max);
        _fund(alice, p);
        _fund(trader, p);
        vm.prank(alice);
        p.join(1_000_000e18, 1_000_000e18, 0, 0, alice);
        amountIn = bound(amountIn, 1e12, 20_000e18); // small enough that the trip back stays under the 30% limit

        vm.startPrank(trader);
        uint256 quoted = p.quote(address(a), amountIn);
        uint256 out = p.swap(address(a), amountIn, 0, trader);
        vm.assertEq(out, quoted, "quote and swap agree at any weights");
        uint256 back = p.swap(address(b), out, 0, trader);
        vm.stopPrank();
        vm.assertLt(back, amountIn, "a round trip always costs something");
    }

    function test_weightedPoolPricesByItsWeights() public {
        V5Pool p = _pool(0.8e18, type(uint256).max);
        _fund(alice, p);
        _fund(trader, p);
        vm.prank(alice);
        p.join(800_000e18, 200_000e18, 0, 0, alice);
        // 80/20 with reserves 800k/200k: one A is worth one B. A small trade should pay that, less the 0.3% fee.
        uint256 out = p.quote(address(a), 1e18);
        vm.assertApproxEqAbs(out, 0.997e18, 0.0001e18, "close to spot less the fee");
        vm.assertLt(out, 0.997e18, "and never better than it");
    }
}

/// Random joins, swaps, collections, exits and passing time.
contract Handler is PoolSetup {
    V5Pool public pool;
    uint256[] public ids;
    address[3] actors;

    constructor(Token a_, Token b_, V5Pool pool_) {
        a = a_;
        b = b_;
        pool = pool_;
        actors = [alice, bob, trader];
        for (uint256 i; i < 3; ++i) _fund(actors[i], pool);
    }

    function join(uint256 who, uint256 amount, bool lock) external {
        address actor = actors[who % 3];
        amount = bound(amount, 1e15, 1e24);
        vm.prank(actor);
        (uint256 id,) = pool.join(amount, amount * 4, 0, lock ? 1 : 0, actor);
        ids.push(id);
    }

    function swap(uint256 amount, bool zeroForOne) external {
        uint256 i = zeroForOne ? 0 : 1;
        amount = bound(amount, 1e6, pool.reserves(i) / 4 + 1e6);
        vm.prank(trader);
        pool.swap(zeroForOne ? address(a) : address(b), amount, 0, trader);
    }

    function collect(uint256 which) external {
        if (ids.length == 0) return;
        uint256 id = ids[which % ids.length];
        address owner = pool.ownerOf(id);
        if (owner == address(0)) return;
        vm.prank(owner);
        pool.collect(id);
    }

    function exit(uint256 which) external {
        if (ids.length == 0) return;
        uint256 id = ids[which % ids.length];
        address owner = pool.ownerOf(id);
        if (owner == address(0)) return;
        vm.prank(owner);
        pool.exit(id, 0, 0, owner);
    }

    function pass(uint256 epochs) external {
        vm.warp(block.timestamp + bound(epochs, 1, 6) * EPOCH);
    }

    function pause(bool on) external {
        vm.prank(guardian);
        pool.setPaused(on);
    }

    function sweep() external {
        pool.sweep();
    }

    function count() external view returns (uint256) {
        return ids.length;
    }
}

contract V5PoolInvariants is PoolSetup {
    V5Pool pool;
    Handler handler;

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        pool = _pool(0.6e18, type(uint256).max);
        handler = new Handler(a, b, pool);
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    /// Every token the pool holds is accounted for, to the wei: reserves,
    /// fees in the hall, and what is owed to the venue and to POL.
    function invariant_everyTokenIsAccountedFor() public view {
        vm.assertEq(
            a.balanceOf(address(pool)),
            pool.reserves(0) + pool.feesInHall(0) + pool.venueOwed(0) + pool.polOwed(0),
            "token0"
        );
        vm.assertEq(
            b.balanceOf(address(pool)),
            pool.reserves(1) + pool.feesInHall(1) + pool.venueOwed(1) + pool.polOwed(1),
            "token1"
        );
    }

    /// Whatever has happened, every position can still leave, and once they
    /// all have, the hall has paid out no more than it took in.
    function invariant_everyoneCanAlwaysLeave() public {
        uint256 n = handler.count();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            address owner = pool.ownerOf(id);
            if (owner == address(0)) continue;
            vm.prank(owner);
            pool.exit(id, 0, 0, owner);
        }
        vm.assertGe(
            a.balanceOf(address(pool)), pool.reserves(0) + pool.venueOwed(0) + pool.polOwed(0), "token0 still covered"
        );
        vm.assertGe(
            b.balanceOf(address(pool)), pool.reserves(1) + pool.venueOwed(1) + pool.polOwed(1), "token1 still covered"
        );
    }
}

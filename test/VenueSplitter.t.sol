// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Token} from "./Base.sol";
import {PoolSetup} from "./V5Pool.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {EpochHall} from "../src/EpochHall.sol";
import {VenueSplitter, IV5PoolForSplitter} from "../src/VenueSplitter.sol";
import {Defaults} from "../src/Defaults.sol";

contract VenueSplitterTest is PoolSetup {
    V5Pool pool;
    VenueSplitter splitter;
    address build = address(0xB111D);
    address prize = address(0x9121E);
    address bank = address(0xBA4C);

    function setUp() public {
        a = new Token("A");
        b = new Token("B");
        pool = _pool(0.5e18, type(uint256).max);
        splitter =
            new VenueSplitter(IV5PoolForSplitter(address(pool)), Defaults.lines(build, pol, prize, bank), configurer);
        // Point the pool's venue at the splitter.
        V5Pool.Roles memory r = _roles();
        r.venue = address(splitter);
        vm.prank(configurer);
        pool.setRoles(r);
        _fund(alice, pool);
        _fund(trader, pool);
    }

    function test_theVenueCutIsDividedBetweenItsLines() public {
        vm.prank(alice);
        (uint256 id,) = pool.join(1000e18, 1000e18, 0, 0, alice);
        vm.prank(trader);
        pool.swap(address(a), 100e18, 0, trader); // fee 0.3, of which the venue's cut is 0.03

        splitter.distribute();
        vm.assertEq(a.balanceOf(build), 0.012e18, "40% to the build fund");
        vm.assertEq(a.balanceOf(pol), 0.006e18, "20% to protocol-owned liquidity");
        vm.assertEq(a.balanceOf(prize), 0.003e18, "10% to prizes");
        vm.assertEq(a.balanceOf(bank), 0.0045e18, "half the buyback line is banked");
        vm.assertEq(splitter.returnedToLps(0), 0.0045e18, "and half goes back to the pool's LPs");
        vm.assertEq(a.balanceOf(address(splitter)), 0, "nothing is left behind");

        // The LP ends up with the LP share of the fee plus the half returned.
        for (uint256 i; i < 4; ++i) {
            _nextEpoch();
        }
        vm.prank(alice);
        vm.assertApproxEqAbs(pool.collect(id)[0], 0.27e18 + 0.0045e18, 1e6, "paid by seasoned weight like any fee");
    }

    function test_linesAreSettingsAndMustAddUp() public {
        VenueSplitter.Lines memory l = Defaults.lines(build, pol, prize, bank);
        l.buybackToLpsWad = 1e18; // everything on the buyback line to LPs, nothing banked
        vm.prank(alice);
        vm.expectRevert(VenueSplitter.NotAllowed.selector);
        splitter.setLines(l);
        vm.startPrank(configurer);
        splitter.setLines(l);
        l.buildWad = 0.9e18; // now the lines sum to more than the whole
        vm.expectRevert(VenueSplitter.BadLines.selector);
        splitter.setLines(l);
        splitter.setConfigurer(address(0));
        vm.stopPrank();
        vm.assertEq(splitter.lines().buybackToLpsWad, 1e18, "the valid change stuck");
        vm.prank(configurer);
        vm.expectRevert(VenueSplitter.NotAllowed.selector);
        splitter.setConfigurer(configurer);
    }
}

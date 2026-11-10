// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Token} from "./Base.sol";
import {EscrowSetup} from "./BankEscrow.t.sol";
import {V5Pool} from "../src/V5Pool.sol";
import {VenueSplitter} from "../src/VenueSplitter.sol";
import {Defaults} from "../src/Defaults.sol";

contract VenueSplitterTest is EscrowSetup {
    function setUp() public {
        _deployAll(1000e18);
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
        vm.assertEq(escrow.ledgerOf(address(pool)), 0.0045e18, "half the buyback line is banked in the escrow");
        vm.assertEq(pool.bankTotal(), 0.0045e18, "and the pool's hall has recorded it");
        vm.assertEq(splitter.returnedToLps(0), 0.0045e18, "the other half goes back to the pool's LPs");
        vm.assertEq(a.balanceOf(address(splitter)), 0, "nothing is left behind");

        // The LP ends up with the LP share of the fee plus the half returned.
        for (uint256 i; i < 4; ++i) {
            _nextEpoch();
        }
        vm.prank(alice);
        vm.assertApproxEqAbs(pool.collect(id)[0], 0.27e18 + 0.0045e18, 1e6, "paid by seasoned weight like any fee");
    }

    function test_bankedMoneyInTheOtherTokenWaitsForTheConverter() public {
        vm.prank(alice);
        pool.join(1000e18, 1000e18, 0, 0, alice);
        vm.prank(trader);
        pool.swap(address(b), 100e18, 0, trader); // this fee is paid in the token the escrow does not take

        splitter.distribute();
        vm.assertEq(splitter.waiting(1), 0.0045e18, "the banked share waits in the splitter");
        vm.assertEq(escrow.ledgerOf(address(pool)), 0, "and nothing is in the escrow yet");

        vm.prank(alice);
        vm.expectRevert(VenueSplitter.NotAllowed.selector);
        splitter.convert(0);
        uint256 expected = pool.quote(address(b), 0.0045e18);
        vm.prank(converter);
        uint256 out = splitter.convert(expected);
        vm.assertEq(out, expected, "the converter swaps it at no worse than the minimum it set");
        vm.assertEq(splitter.waiting(1), 0, "nothing is left waiting");
        vm.assertEq(escrow.ledgerOf(address(pool)), out, "and it is banked");
    }

    function test_whatDoesNotFitUnderTheCapGoesToTheLps() public {
        // A cap so small that only part of the banked share fits.
        _deployAll(0.001e18);
        _fund(alice, pool);
        _fund(trader, pool);
        vm.prank(alice);
        pool.join(1000e18, 1000e18, 0, 0, alice);
        vm.prank(trader);
        pool.swap(address(a), 100e18, 0, trader);
        splitter.distribute();
        vm.assertEq(escrow.ledgerOf(address(pool)), 0.001e18, "the escrow takes up to the cap");
        vm.assertEq(splitter.returnedToLps(0), 0.0045e18 + 0.0035e18, "and the LPs get their half plus the overflow");
        vm.assertEq(escrow.room(address(pool)), 0, "the cap is reached");
    }

    function test_withNoEscrowTheWholeBuybackLineGoesToTheLps() public {
        VenueSplitter.Lines memory l = Defaults.lines(build, pol, prize, address(0), converter);
        vm.prank(configurer);
        splitter.setLines(l);
        vm.prank(alice);
        pool.join(1000e18, 1000e18, 0, 0, alice);
        vm.prank(trader);
        pool.swap(address(a), 100e18, 0, trader);
        splitter.distribute();
        vm.assertEq(splitter.returnedToLps(0), 0.009e18, "all 30% of the cut");
    }

    function test_linesAreSettingsAndMustAddUp() public {
        VenueSplitter.Lines memory l = Defaults.lines(build, pol, prize, address(escrow), converter);
        l.buybackToLpsWad = 1e18;
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

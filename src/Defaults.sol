// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {EpochHall} from "./EpochHall.sol";
import {V5Pool} from "./V5Pool.sol";
import {VenueSplitter} from "./VenueSplitter.sol";
import {BankEscrow} from "./BankEscrow.sol";

/// @title Defaults
/// @notice The settings a new V5 pool starts with.
///
/// Each value is the reviewer's pick from the simulator runs recorded in
/// `docs/rulings-needed.md`. None is a ruling, every one can be changed on a
/// live pool, and the market inputs behind the runs were placeholders. Where
/// the runs did not settle a number, the comment says so.
library Defaults {
    /// Six hours, from the spec.
    uint256 internal constant EPOCH = 6 hours;
    uint256 internal constant EPOCHS_PER_DAY = 4;

    function hall() internal pure returns (EpochHall.HallConfig memory c) {
        // Seasoning. The fee hold is what keeps hot money out, so it stays on
        // (ruling 5). The runs support a horizon of one to four weeks and a
        // floor below a half; the exact figures are not settled.
        c.floorWad = 0.4e18;
        c.horizon = 28 * EPOCHS_PER_DAY;
        c.unlockedAtZeroWad = 0.4e18;
        c.polShareWad = 0.3e18;

        // The lock. No weight boost exists (ruled). A locked position skips the
        // ramp, and leavers' tolls go to the LPs still locked (ruling 1, option a).
        // The exit cost melts to zero over the term, which did as well as a
        // flat cost once the boost was gone (ruling 2). The runs support an
        // exit cost of 5% to 10% and say nothing firm about the term.
        c.lockTerm = 90 * EPOCHS_PER_DAY;
        c.lockExitWad = 0.1e18;
        c.lockMeltFloorWad = 0;
        c.lockSkipsRamp = true;
        c.tollPolShareWad = 0;
    }

    /// `feeWad` is the fee the pool opens with: whatever is competitive for the
    /// pair, for example 0.0005e18 for a stable pair or 0.003e18 for a volatile one.
    /// `referenceAprWad` is what LPs in this pair can earn elsewhere. It has to
    /// be chosen per pool; set too low, the venue overcharges.
    function fees(uint256 feeWad, uint256 referenceAprWad) internal pure returns (V5Pool.FeePolicy memory f) {
        // The fee may fall to 0.4 of where it opened and never rise above it.
        // A decrease lands in a day, an increase in two weeks (ruling 3).
        f.feeMinWad = feeWad * 4 / 10;
        f.feeMaxWad = feeWad;
        f.feeDownDelay = 1 days;
        f.feeUpDelay = 14 days;

        // The venue cut sets itself each week, taking half of what the pool
        // yields above the reference rate, between 5% and 40% of the fee, and
        // moving at most 5 points at a time (ruling 4).
        f.autoCut = true;
        f.cutOfExcessWad = 0.5e18;
        f.referenceAprWad = referenceAprWad;
        f.cutMinWad = 0.05e18;
        f.cutMaxWad = 0.4e18;
        f.cutStepWad = 0.05e18;
        f.cutReview = 7 days;

        // Nothing from the venue cut goes to lockers at the start. Raising this
        // buys more liquidity through a shock at the venue's expense (ruling 1, option b).
        f.lockBudgetWad = 0;
    }

    /// How the venue cut is divided. The 40/20/10 lines for the build fund,
    /// protocol-owned liquidity and prizes are the simulator's working values
    /// and were never swept; the remaining 30% is the buyback line. Before the
    /// token exists, half of that line goes back to the pool's LPs and half is
    /// banked for the launch burn (ruled: 50/50).
    function lines(address build, address pol, address prize, address bank, address converter)
        internal
        pure
        returns (VenueSplitter.Lines memory l)
    {
        l.buildWad = 0.4e18;
        l.polWad = 0.2e18;
        l.prizeWad = 0.1e18;
        l.buybackToLpsWad = 0.5e18;
        l.build = build;
        l.pol = pol;
        l.prize = prize;
        l.bank = bank;
        l.converter = converter;
    }

    /// The escrow's limits. None of these numbers comes from a simulator run:
    /// the simulator does not model the escrow's release, pause or refund.
    /// They are starting points chosen to respect the one hard rule, that a
    /// stuck pause must outlast a deploy delay plus an unpause.
    ///
    /// `deployDelay` is the timelocked deployer's delay.
    function escrowLimits(uint256 poolCap, uint256 deployDelay) internal pure returns (BankEscrow.Limits memory l) {
        l.poolCap = poolCap; // per pool, in the escrow's asset; no safe default
        l.releaseRateWad = 0.01e18; // 1% of the ledger per epoch: half is gone in about 17 days
        l.unpauseDelay = 3 days;
        l.stuckPeriod = deployDelay + l.unpauseDelay + 14 days;
        l.threshold = 3;
        l.memberFloor = 3;
    }

    /// The longest timelock: how long a queued deploy waits. Not from a run.
    uint256 internal constant DEPLOY_DELAY = 14 days;

    /// The venue cut a pool opens with, before its first weekly review.
    uint256 internal constant OPENING_CUT = 0.1e18;
}

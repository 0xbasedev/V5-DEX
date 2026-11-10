// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

// The shapes a V5 pool and the contracts around it pass to one another.

/// What a pool is opened with and can never change.
struct PoolConfig {
    address token0;
    address token1;
    /// Weight of token0 (WAD). Token1 has the rest.
    uint256 weight0;
    uint256 epochLength;
    /// The swap fee and the venue cut the pool opens with.
    uint256 feeWad;
    uint256 venueCutWad;
    uint256 depositCap;
    /// Zero for a weighted pool. For a peg pair, the amplification; weights must then be equal.
    uint256 amp;
    /// The audited `PoolCurve` deployment.
    address curve;
}

/// Who may do what to a pool.
struct Roles {
    address venue; // receives the venue cut
    address pol; // receives protocol-owned liquidity credits
    address guardian; // may pause and unpause
    address capRaiser; // may raise the deposit cap
    address configurer; // may change settings
    address feeSetter; // may queue a fee change inside the bounds
    address bank; // the escrow; may record what it has banked for this pool
    address depegWatch; // optional; while it reports a depeg, exits are free
    address desk; // the fee desk; sets the pool's fee terms inside the pool's own ceilings
}

/// The fee terms a pool charges by. The pool holds them; the desk sets them.
struct Terms {
    /// The swap fee (WAD of the amount paid in).
    uint64 feeWad;
    /// A fee change on its way, and when it lands (0 = none).
    uint64 nextFeeWad;
    uint64 nextFeeAt;
    /// The venue's share of each fee (WAD).
    uint64 venueCutWad;
    /// Share of the venue cut paid to locked LPs (WAD).
    uint64 lockBudgetWad;
    /// An optional fee model, such as the tuning fork. Zero means the plain fee.
    address feeModel;
}

/// The rules the desk sets a pool's terms by.
struct FeePolicy {
    /// Bounds on the swap fee (WAD of the amount paid in).
    uint256 feeMinWad;
    uint256 feeMaxWad;
    /// How long a decrease and an increase wait before taking effect, in seconds.
    uint256 feeDownDelay;
    uint256 feeUpDelay;
    /// The venue cut sets itself: each review it aims to take `cutOfExcessWad`
    /// of whatever the pool's fees yield above `referenceAprWad`.
    bool autoCut;
    uint256 cutOfExcessWad;
    uint256 referenceAprWad;
    /// Bounds on the venue cut (WAD of the fee), the most it moves per review, and seconds between reviews.
    uint256 cutMinWad;
    uint256 cutMaxWad;
    uint256 cutStepWad;
    uint256 cutReview;
    /// Share of the venue cut paid to locked LPs (WAD).
    uint256 lockBudgetWad;
    /// An optional fee model, such as the tuning fork. Zero means the plain fee.
    address feeModel;
}

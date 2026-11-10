# Contracts

First cut, written to be shaped. **Not audited. Do not deploy with real funds.**

```
pnpm install          # Foundry and Solady come from npm
pnpm test             # forge test
pnpm test:sim         # the simulator's own tests
```

## What is here

| File | What it does |
|---|---|
| `EpochHall.sol` | Seasoned-position bookkeeping: the weight ramp, constant-time fee settlement, the fee hold, forfeits on early exit, the hard lock and its toll, transfer and merge. A Solidity port of `sim/hall.py`. |
| `V5Pool.sol` | A two-token weighted pool built on the hall. Swap fees go to the hall's ledger and to the venue, never into reserves. Joining opens a position; there is no LP token. |

## What the tests cover

25 tests in `test/`, no test library needed.

- **Against brute force.** Random opens, exits, collections and fees over 30 epochs, 512 runs. A slow calculation that walks every position every epoch must agree with the hall, the hall may never pay out more than came in, and rounding may never favour a position.
- **The simulator's named cases**, with the same numbers: the early-exit forfeit, a transfer inside the horizon, a merge.
- **The pool**: the swap pays exactly the quote; fees never enter reserves; a weighted pool prices by its weights; a round trip always costs something.
- **The council's invariants that can be tested on-chain**: a leaver never pays more than the rate written into the position; a pause never blocks an exit and makes it free; no admin call can raise a toll (there is none to call).
- **Two invariants under random use**: every token the pool holds is accounted for to the wei, and every position can always leave.

The brute-force test found a real fault in the first draft: a rounding leak that let the hall owe up to one wei more per epoch than it held. It is fixed, and the test now guards it.

## Decisions made here that are yours to change

Each was the simplest reading of spec v1.16 or of `docs/rulings-needed.md`. None is settled.

1. **The hall is built into each pool**, as a base contract. The spec describes one Epoch Hall for the venue. A shared hall becomes necessary when the locked token arrives; until then one contract per pool is smaller and easier to audit.
2. **A position is a record, not yet an NFT.** It can be handed over with `transferPosition`, and its age, lock and held fees travel with it. There is no ERC-721 surface, so wallets and marketplaces will not see it.
3. **Forfeits and tolls leave the reserves.** A share is credited to POL and the rest is paid to the LPs who stay, as fees. The spec says they "stay in the pool as depth". Doing that needs POL to hold a position, which is not built.
4. **The lock follows the spec plus two rulings**: no boost, and an exit cost that melts to zero over the term. Skipping the seasoning ramp is a switch per pool. Tolls are split as §18.3 says, not paid to lockers; rulings 1 and 2 would change this.
5. **Nothing can be changed after deployment** except the pause and a deposit cap that only goes up. There is no fee registry, the fee is fixed and the venue cut is flat. Rulings 3 and 4 would add a fee that responds and a cut that sets itself.
6. **The guardian can pause and unpause.** While paused, joins and swaps stop and every exit is free of forfeits and tolls.
7. **Two tokens only.** Tokens that take a fee on transfer or change balances by themselves are not supported.
8. **The first join's shares are the square root of the two amounts**, whatever the weights, with 1,000 shares locked for good.
9. **All rounding is against the position or the trader.** The weighted curve's power function gets a margin of one part in 10^14.

## Not built yet

- Compounding, and the auto-compounding vault.
- The banked half: escrow, deferred claims, sunset refund (spec §18.8).
- A router, and per-transaction permits.
- The fee registry, the responsive fee and the self-setting venue cut.
- The depeg waiver, the tuning-fork fee and the stable-amplified curve.
- A shared hall, the token, locks on the token, gauges.
- Deployment scripts and the deterministic addresses.

## Gas, first reading

From the tests, first call to a fresh pool, so on the high side: swap about 143,000, join 183,000 to 319,000, exit about 285,000, collect 124,000 to 246,000. The hall's catch-up to the current epoch is inside each. Nothing has been tuned.

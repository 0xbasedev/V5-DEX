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
| `EpochHall.sol` | Seasoned-position bookkeeping: the weight ramp, constant-time fee settlement, the fee hold, forfeits on early exit, the hard lock and its toll, tolls paid to lockers, transfer and merge. A Solidity port of `sim/hall.py`. |
| `V5Pool.sol` | A two-token weighted pool built on the hall. Swap fees go to the hall's ledger and to the venue, never into reserves. Joining opens a position; there is no LP token. The fee moves inside bounds, and the venue cut can set itself. |
| `Defaults.sol` | The settings a new pool starts with, each with the reason for it. |

## Everything is a setting

Nothing about the economics is hard-coded yet. The `configurer` can change any of it on a live pool:

- **The hall's settings** (`setHallConfig`): floor, horizon, fee hold, POL share of forfeits, lock term, exit cost, how far it melts, whether a lock skips the ramp, and where lock tolls go.
- **The fee policy** (`setFeePolicy`): the fee's bounds and delays, whether the venue cut sets itself and how, and the share of the cut paid to lockers.
- **The roles** (`setRoles`): who receives the venue cut and POL, who may pause, raise the cap, queue a fee, and configure.

Two protections hold whatever is changed:

- **A position keeps the terms it opened under.** A change to the hall's settings reaches only positions opened afterwards, so no change can raise what it costs someone already in to leave.
- **An exit cannot be blocked.** No setting, role or pause stops one.

Handing the configurer role to the zero address freezes every setting for good. That is how a setting gets "merged into hard code" before the code itself is rewritten.

Only the two tokens, their weights and the epoch length cannot change.

## The defaults, and why

These are the reviewer's picks from the simulator runs in `docs/rulings-needed.md`. Every market input behind those runs was a placeholder.

| Setting | Default | Why |
|---|---|---|
| Seasoning floor | 0.4 | Low enough to filter hot money with the hold on. The runs support anything below a half. |
| Seasoning horizon | 28 days | The runs support one to four weeks. |
| Fee hold | On, 40% unlocked at once | The hold is the part of seasoning that keeps hot money out (ruling 5). |
| POL share of forfeited fees | 30% | The simulator's working value; not swept. |
| Lock weight boost | None | Ruled out. There is no setting for one. |
| Lock term | 90 days | The runs did not settle this. |
| Lock exit cost | 10%, melting to zero | Level with a flat cost once the boost was gone, and kinder near the end of a term (ruling 2). 5% to 10% is supported. |
| Lock skips the ramp | Yes | Without a boost, nobody locks unless there is something else to gain (ruling 1). |
| Lock tolls | All to LPs still locked | With the above, about 9 to 13 more points of liquidity through a shock for 2% of venue revenue (ruling 1). |
| Share of venue cut to lockers | 0 | Available; raising it buys more retention at the venue's expense. |
| Fee bounds | 0.4x to 1x the opening fee | A fee that cannot fall loses to a competitor that manages its own (ruling 3). |
| Fee delays | 1 day down, 14 days up | A fast decrease beat a slow one by 31% to 53% in venue revenue. |
| Venue cut | Sets itself weekly, 5% to 40%, takes half the yield above the reference rate | Beat every flat cut it was compared with (ruling 4). |
| Reference rate | Set per pool | No default is safe. Too low and the venue overcharges. |

## What the tests cover

34 tests in `test/`, no test library needed.

- **Against brute force.** Random opens, exits, collections and fees over 30 epochs, 512 runs. A slow calculation that walks every position every epoch must agree with the hall, the hall may never pay out more than came in, and rounding may never favour a position.
- **The simulator's named cases**, with the same numbers: the early-exit forfeit, a transfer inside the horizon, a merge.
- **The pool**: the swap pays exactly the quote; fees never enter reserves; a weighted pool prices by its weights; a round trip always costs something.
- **The settings**: a pool opens on the defaults; a change reaches only new positions; the fee falls in a day and rises in fourteen; the venue cut steps up in a busy pool and down in a quiet one; tolls and the lock budget reach lockers by size; settings can be frozen.
- **The council's invariants that can be tested on-chain**: a leaver never pays more than the rate written into the position; a pause never blocks an exit and makes it free; no setting can raise a toll on an open position.
- **Two invariants under random use**: every token the pool holds is accounted for to the wei, and every position can always leave.

The brute-force test found a real fault in the first draft: a rounding leak that let the hall owe up to one wei more per epoch than it held. It is fixed, and the test now guards it.

## Structural choices still open

These are about how the contracts are built, not what they are set to.

1. **The hall is built into each pool**, as a base contract. The spec describes one Epoch Hall for the venue. A shared hall becomes necessary when the locked token arrives.
2. **A position is a record, not yet an NFT.** It can be handed over with `transferPosition`, and its age, lock and held fees travel with it. Wallets and marketplaces will not see it.
3. **Forfeits and tolls leave the reserves** and are paid out as fees. The spec says they "stay in the pool as depth". Doing that needs POL to hold a position, which is not built.
4. **Tolls are paid to lockers at once**, not streamed over a term. The simulator found no difference in retention, and paying at once costs constant gas.
5. **The venue cut's review reads the pool's own price** to value fees in one token. Someone could skew one review by moving the price first; the damage is capped at one step of the cut.
6. **The guardian can pause and unpause.** While paused, joins and swaps stop and every exit is free of forfeits and tolls.
7. **Two tokens only.** Tokens that take a fee on transfer or change balances by themselves are not supported.
8. **All rounding is against the position or the trader.**

## Not built yet

- Compounding, and the auto-compounding vault.
- The banked half: escrow, deferred claims, sunset refund (spec §18.8).
- A router, and per-transaction permits.
- A timelock in front of the configurer, and anything that moves the fee automatically.
- The depeg waiver, the tuning-fork fee and the stable-amplified curve.
- A shared hall, the token, locks on the token, gauges.
- Deployment scripts and the deterministic addresses.

## Gas and size, first reading

From the tests: a swap is about 200,000 gas, a join about 358,000, an exit 290,000 to 302,000, a collect 130,000 to 262,000. That is high. Making everything a setting means reading settings from storage on every call, and the hall's catch-up to the current epoch is inside each. Nothing has been tuned, and fixing settings into the code later will bring it down.

The pool compiles to about 21,000 bytes against a limit of 24,576, so there is room for roughly one more feature before it has to be split.

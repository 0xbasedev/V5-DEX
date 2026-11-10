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
| `StableMath.sol` | The amplified curve for peg pairs. |
| `V5Pool.sol` | A two-token pool built on the hall, with a weighted curve for general pairs or the amplified curve for peg pairs. Swap fees go to the hall's ledger and to the venue, never into reserves. Joining opens a position; there is no LP token. The fee moves inside bounds, and the venue cut can set itself. |
| `TuningFork.sol` | The directional fee for peg pools: cheap toward the pitch, dearer the further away, charged over the whole price move. A fee model the pool consults on swaps. |
| `DepegWatch.sol` | Reports when an outside price has been off its peg for a full window. While it does, exits are free. |
| `VenueSplitter.sol` | Divides one pool's venue cut between the build fund, protocol-owned liquidity, prizes and the buyback line. Before the token exists, half the buyback line goes back to the pool's LPs and half is banked in the escrow, up to the pool's cap. |
| `BankEscrow.sol` | Holds the banked half, one per chain. It can only hold, release slowly to one fixed address, pause, and refund. |
| `TimelockedDeployer.sol` | The only way later-written contracts (the outlet, the Engine, the token) can arrive. Their addresses are fixed from day one; their code must be published and wait out a delay. |
| `ExchangeToken.sol` | The token: fixed supply minted once, no owner, no mint, burnable. Its code is identical whatever its supply and chain. |
| `BuybackEngine.sol` | Buys the token with the venue's stables, at most once a block and never above a reference price, and sends it to the Burn Vault. No admin, no settings. |
| `BurnVault.sol` | Holds the token and burns it on burn day. No withdraw, no admin. |
| `TokenLock.sol` | Locking the token for a share of fees and a vote. An Epoch Hall whose stake is the token: longer locks weigh more, leaving early costs less as the lock runs, and that cost is split between a burn and the lockers who stayed. |
| `Gauges.sol` | Weekly votes by lockers direct a boost budget of real fees to pools, with a cap on any one pool. Bribes for votes, with decay. |
| `HomeOutlet.sol` | The outlet on the home chain: passes escrow releases to the Engine. |
| `Defaults.sol` | The settings a new pool, splitter, escrow, fork and depeg watch start with, each with the reason for it. |

## The banked half, end to end

This is the part of the design that holds money outside a pool, and the part the spec spends most words on (§18.8).

1. **A swap pays a fee.** The venue's cut of it is set aside in the pool.
2. **The splitter divides the cut.** Of the buyback line, half goes straight back to the pool's LPs. The other half is banked.
3. **The escrow takes it**, in one asset, up to a cap per pool. Anything over the cap goes to the LPs. Banked money in the pool's other token waits in the splitter until a named converter swaps it.
4. **The pool's hall records it.** Whoever holds seasoned weight in that epoch earns a claim on it. The claim belongs to the wallet, and stays with it if the position is sold or closed.
5. **Nothing leaves the escrow** until code exists at the outlet's address whose hash matches what the deployer published, that code has been live for an epoch, and no other deploy is waiting. Then at most a fixed share of the ledger goes per epoch, to that address only.
6. **Any one member of the pause set can stop releases.** Unpausing takes a threshold and a delay. A threshold can remove a member at once, except while a deploy is waiting.
7. **Once the token exists, the road continues.** The outlet passes each release to the Buyback Engine. The Engine buys the token a little at a time, checking on every buy that the token is the audited one and that it is not paying above its reference price, and sends what it buys to the Burn Vault. On burn day anyone can burn the lot.
8. **The money comes back** if no outlet exists by the sunset, or if a pause lasts too long without a break. Each wallet collects by its claim. A refund cannot be paused, pays only what was not already drawn, and closes the escrow for good.

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
| Venue cut lines | 40% build, 20% POL, 10% prizes, 30% buyback | The simulator's working values; never swept. |
| Buyback line before the token | Half back to LPs, half banked | Ruled 50/50. |

## What the tests cover

114 tests in `test/`, no test library needed.

- **Against brute force.** Random opens, exits, collections and fees over 30 epochs, 512 runs. A slow calculation that walks every position every epoch must agree with the hall, the hall may never pay out more than came in, and rounding may never favour a position.
- **The simulator's named cases**, with the same numbers: the early-exit forfeit, a transfer inside the horizon, a merge.
- **The pool**: the swap pays exactly the quote; fees never enter reserves; a weighted pool prices by its weights; a round trip always costs something.
- **Compounding**: unlocked fees become liquidity at the position's current age, held fees cannot be used, and the position matures on its original date at its new size.
- **The venue cut's lines**: each receives its share to the wei, the LPs' half comes back as fees, and the lines must add up.
- **The settings**: a pool opens on the defaults; a change reaches only new positions; the fee falls in a day and rises in fourteen; the venue cut steps up in a busy pool and down in a quiet one; tolls and the lock budget reach lockers by size; settings can be frozen.
- **The amplified curve**: it matches values computed independently outside Solidity, where the invariant was checked against the curve's equation to better than one part in 10^24; over 20,000 random cases no swap shrinks the invariant and no there-and-back trade returns more than went in; a peg pool pays far more than a weighted one for the same trade; tokens with 6 and 18 decimals trade at the peg.
- **The tuning fork**: toward the pitch pays the floor; away pays more the further it goes, up to the cap; a trade that crosses the pitch is charged for each part of the way; the swap still pays exactly the quote. Over 3,000 random cases, cutting a trade in two changed the fee by less than a thousandth and left the trader better off by less than a millionth of the trade.
- **The depeg watch**: one bad reading is not a depeg; a full window outside, watched throughout, is; a reading back inside or a long silence starts the clock over; during a depeg a locked position leaves free; a watch that fails cannot block an exit.
- **The deployer**: a slot's address is known before anything is deployed there; only the published code can arrive, only after the delay, only once; the outlet cannot arrive after the sunset.
- **The escrow**: per-pool ledgers and caps; no release without the published outlet, in its first epoch, or while another deploy waits; releases come from every pool in proportion; one member pauses, a threshold unpauses after a delay, a rogue member is removed at once but never while a deploy waits; both refund triggers; a pool that lies cannot take another pool's money; a stray transfer cannot dilute later depositors.
- **Deferred claims with a real pool**: a late depositor gets only its share of the epochs it was in; a claim stays with the seller of a position and survives closing it; after a partial draw the rest is split by the same claims.
- **The launch burn, end to end**: a banked fee travels escrow to outlet to Engine to Burn Vault and the supply falls, with the token, the Engine and the outlet each arriving through the timelocked deployer. The token's code is the same whatever its supply, name or chain, and it cannot mint. The Engine stops if the token is not the one it was built for or its supply is above the commitment; buys once a block and never before its start; will not buy into a price someone pushed up; and measures against an outside price when given one. The Burn Vault burns only on burn day and its meter counts only what was burned.
- **The token lock**: a longer lock weighs and earns more; lengths are bounded; leaving early costs half on day one and a quarter half way, split between the burn and the stayers; with nobody else locked the whole cost is burned; a lock that has run leaves free, cannot vote, and can be closed by anyone for its owner; a lock can be sold and keeps its terms; locks cannot be merged.
- **The gauges**: votes direct the budget to pools as fees for their LPs, capped per pool, with the remainder rolling on; a vote can be split and must add up; only listed pools, only the lock's owner, only a lock that outlasts the week; a bribe is shared by those who voted for the pool, reaches a voter who has since closed their lock, and decays to the buyback path if not collected.
- **The council's invariants that can be tested on-chain**: a leaver never pays more than the rate written into the position; a pause never blocks an exit and makes it free; no setting can raise a toll on an open position.
- **Four invariants under random use**: every token the pool holds is accounted for to the wei; every position can always leave; the escrow's ledger is always covered; and money leaves the escrow only to the outlet or as a refund.

The tests have found two real faults so far, both fixed and both now guarded:

- A rounding leak in the hall that let it owe up to one wei more per epoch than it held.
- In the amplified curve, with no fee, a there-and-back trade could return one wei more than went in, because the solver is accurate only to its last unit. The amount out now holds back a few units.

## Structural choices still open

These are about how the contracts are built, not what they are set to.

1. **The hall is built into each pool**, as a base contract. The spec describes one Epoch Hall for the venue. A shared hall becomes necessary when the locked token arrives.
2. **A position is a record, not yet an NFT.** It can be handed over with `transferPosition`, and its age, lock and held fees travel with it. Wallets and marketplaces will not see it.
3. **Forfeits and tolls leave the reserves** and are paid out as fees. The spec says they "stay in the pool as depth". Doing that needs POL to hold a position, which is not built.
4. **Tolls are paid to lockers at once**, not streamed over a term. The simulator found no difference in retention, and paying at once costs constant gas.
5. **The venue cut's review reads the pool's own price** to value fees in one token. Someone could skew one review by moving the price first; the damage is capped at one step of the cut.
6. **The guardian can pause and unpause** a pool. While paused, joins and swaps stop and every exit is free of forfeits and tolls.
7. **Two tokens only.** Tokens that take a fee on transfer or change balances by themselves are not supported.
8. **All rounding is against the position or the trader.**

On the fork and the depeg watch:

- **The fork is a separate contract the pool consults**, not code inside the pool. That keeps the pool under its size limit and means a pool can run with no fork or a different fee model. It is on the swap path only and cannot touch an exit.
- **The whole fee, surcharge included, goes down the usual waterfall.** The spec leaves a separate LP/POL split of the directional fee as a config field; it is not built.
- **"Charged over the whole move" is an average along the trade weighted by amount traded**, taken at three points. It is close to exact, not exact.
- **A fork costs gas**: three passes over the curve per swap instead of one.
- **The depeg watch needs people to call it.** It reports a depeg only if readings kept coming in throughout the window.

On the launch burn:

- **The Engine's own average is built from readings anyone may trigger.** With no outside price, whoever alone triggers readings can lean on it. The premium limit, the size of each buy and the length of the window bound the damage, and a keeper reading every block removes most of it. A price record kept by the pool itself would be sturdier; the pool has no room for one until it is split.
- **Everything the Engine buys is burned.** The spec also mentions paying some of it to seasoned LPs; that split is not built.
- **The Burn Vault is deployed plainly, not through the timelocked deployer.** It has no admin and nothing to configure, and the Engine's published code names its address.

On the token lock and the gauges:

- **The token lock is an Epoch Hall**, as the spec's "one hall, two kinds of stake" suggests, but a separate instance from any pool's.
- **Weight does not decay while a lock runs.** It is set by the length chosen and holds until the lock ends. A lock that has ended keeps earning until someone closes it, which anyone may do.
- **One vote per lock per week, and it is final.** A lock must outlast the week it votes in, so the same tokens cannot vote, leave free and vote again.
- **The cap on a pool's boost is a flat share of the week's budget.** The spec wants it to scale with the venue fees that pool produced, plus a flat slice for new pools. That needs a record of each pool's fees per week, which does not exist.
- **Listing a pool is by hand.** The spec's age, depth and oracle checks are applied by whoever holds the configurer role.
- **A bribe is paid to whoever cast the vote**, not to whoever holds the lock later.

Where the escrow departs from spec v1.16, on purpose:

9. **The cap is per pool, not per chain.** Anyone may bank for any pool, so one chain-wide cap could be filled by a stranger to push every real pool's share to its LPs instead.
10. **"Nothing is released before the token exists" is enforced as "before the published outlet exists".** A chain other than home cannot see the token. The outlet arrives only through the timelocked deployer, so the timelock and the watcher are the gate.
11. **The refund is paid by the escrow, not through the hall.** The hall keeps the claims and the escrow keeps the money, so the pool never holds the escrow's asset. The split is the one the spec describes.
12. **The claim is measured against everything recorded as banked**, including an epoch still open. A wallet that collects before the last epoch closes gets a little less then and the rest on a second call. Nobody can be overpaid.
13. **Stray transfers are counted in only when a refund opens.** Counting them in earlier would let a first depositor dilute everyone who banks after.
14. **The freeze after a deploy covers the outlet's first epoch only.** A later Engine deploy freezes releases while it waits, but not for its own first epoch.
15. **The escrow's limits are settings for now**, like everything else. That weakens "only limits the escrow enforces are guarantees" until the configurer is set to zero. The outlet, the asset and the deployer can never be changed.
16. **Converting banked money from the pool's other token is restricted to one address**, with a minimum it chooses. Left open to everyone, whoever picked the moment could arrange a bad price. A pool with neither token in the escrow's asset cannot bank at all yet.

## Not built yet

- The auto-compounding vault. Compounding itself is built, and uses only as much of each token as fits the pool's proportions; it does not swap the excess.
- The outlet for chains other than home, which has to carry money across chains.
- Moving protocol-owned liquidity by vote. The gauges record the votes; nothing acts on them for POL yet.
- A fee line from the venue cut to the token lock and to the boost budget. Both accept payments from anyone; the splitter does not yet send them.
- A router, and per-transaction permits.
- A timelock in front of the configurer, and anything that moves the fee automatically.
- An outside price source. The fork's pitch and the depeg watch both read one through a one-function interface; no adapter to a real oracle exists yet.
- Ramping the amplified curve's amplification, which is fixed per pool.
- A shared hall.
- Deployment scripts and the deterministic addresses.

## Gas and size, first reading

The contracts are now compiled through the IR pipeline, which shrank the pool by about 3,500 bytes. With the amplified curve, the fee-model hook and the depeg waiver added it stands at about 23,000 against a limit of 24,576. It is full: the next thing that belongs inside the pool means splitting it first. One side effect matters for tests only: a test that moves the clock must read the time through the cheatcode, as `test/Base.sol` does.

A swap is about 200,000 gas, a join about 358,000, an exit about 300,000. That is high. Every setting is read from storage on every call, and the hall's catch-up to the current epoch is inside each. Nothing has been tuned, and fixing settings into the code later will bring it down.

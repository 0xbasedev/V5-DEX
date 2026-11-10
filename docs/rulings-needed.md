# Rulings needed from Jess

Written 2026-11-10 by the external reviewer, from the simulator in `sim/`. Canon is spec v1.16; nothing here changes it until ruled.

**How to read the numbers.** Every figure is the mean of 40 runs on the current simulator, in which the seasoned pool and the plain pool face identical LPs and identical market moves. The "plain pool" has no seasoning and no lock. All market inputs are placeholders, so the figures show which way a choice pushes and roughly how hard, not what a real pool will earn. Each ruling lists the command that reproduces it.

**Corrections to what I reported earlier** are collected at the end. Two of them change a recommendation.

---

## Already ruled

| | Ruling | Source |
|---|---|---|
| A | The lock has no weight boost. | Jess: "No boost." |
| B | The lock's exit cost is flat for the term and does not roll. | Jess: "Approved" — **please confirm, see ruling 2.** |

---

## 1. What does an LP get for locking?

With no boost and nothing in its place, nobody locks, and V5 is the soft tier alone: the plain pool's shock retention with about 9% less depth.

Volatile pair, two shocks, 90-day lock, flat 10% exit cost.

| Reward | Take the lock | Average TVL | Left after shock 1 / 2 | Venue cut collected | POL owned |
|---|---|---|---|---|---|
| Nothing | 0% | $6.05M | 61.1% / 62.2% | $93,608 | $18,652 |
| Tolls to lockers only | 0% | $6.05M | 61.1% / 62.2% | $93,608 | $18,652 |
| Lock skips the seasoning ramp | 26.1% | $6.33M | 68.2% / 67.6% | $97,075 | $22,561 |
| Skips ramp + tolls to lockers | 49.4% | $6.51M | 70.0% / 74.8% | $99,237 | $19,030 |
| 20% of venue cut to lockers | 36.3% | $6.53M | 73.1% / 69.7% | $79,671 | $22,415 |
| All three | 68.9% | $6.79M | 79.2% / 79.1% | $82,094 | $15,807 |
| *Plain pool* | | *$6.67M* | *61.5% / 61.5%* | *$101,382* | *$17,359* |

- "Skips the ramp" means a locked position has full weight and unlocked fees from day one. It never has more weight than a seasoned position, so it is not a boost.
- "Tolls to lockers" is the council's proposal: a leaver's exit toll goes to LPs locked before the exit. It cannot start the lock by itself, because with no lockers there are no tolls.

**Options.**
- **(a) Skips ramp + tolls to lockers.** About 9 to 13 more points of liquidity through a shock, for 2% of venue revenue.
- **(b) All three.** About 18 more points and slightly more depth than the plain pool, for 19% of venue revenue.

**Recommendation: (a) for launch**, with the budget in (b) available as a config line that starts at zero.

**Spec impact.** Amends the seasoning rule in §3 for the hard tier. Reverses the POL share of lock tolls in §18.3 (soft-tier forfeits keep their POL share). The budget would be a new line in the venue-cut split.

`python3 -m sim.run --scenario twoshock --seeds 40 --set hard_exit_pct=10 --set lock_melt_floor=1 --set hard_skips_ramp=1 --set toll_mode=1`

---

## 2. Confirm or withdraw ruling B (flat exit cost)

I recommended a flat exit cost from runs that had a 1.25 boost. With no boost the advantage disappears, because fewer LPs accept a flat cost.

Same setting as ruling 1, reward (a), 10% exit cost unless stated.

| Exit cost within the term | Take the lock | Average TVL | Left after shock 1 / 2 |
|---|---|---|---|
| Melts to zero (spec today) | 76.6% | $6.44M | 69.5% / 74.2% |
| Flat | 49.4% | $6.51M | 70.0% / 74.8% |
| Flat, and rolls | 36.0% | $6.36M | 66.6% / 71.2% |
| Flat at 5% | 78.3% | $6.47M | 70.0% / 75.3% |
| Flat at 20% | 21.0% | $6.29M | 67.2% / 66.9% |

Melting and flat are level. Rolling is worse. A 20% cost is worse than 5% or 10%, because too few accept it.

**Recommendation: withdraw B and keep the spec's melting cost.** It performs the same, needs no spec change, and is kinder to an LP who has to leave near the end of a term. Keep "no rolling".

**Spec impact.** None if withdrawn.

`python3 -m sim.run --scenario twoshock --seeds 40 --set hard_exit_pct=10 --set hard_skips_ramp=1 --set toll_mode=1` (add `--set lock_melt_floor=1` for flat)

---

## 3. Should the fee respond, and how fast can it fall?

Spec §18.4 sets a competitive fee at launch with step-ups on a schedule. A fee that never moves loses badly to a competitor that manages its own.

Stable pair with thin volume. The competitor picks its best fee each week and its LPs follow yield. We start at 0.05%; both sides have a floor of 0.02%.

| Our fee | Fee at the end | Our share of trading | Venue cut collected | Long-stay LP APR |
|---|---|---|---|---|
| Never moves | 0.0500% | 7.5% | $3,015 | 3.5% |
| Follows the competitor, decreases take 14 days | 0.0231% | 12.9% | $4,245 | 4.3% |
| Follows the competitor, decreases take 1 day | 0.0200% | 22.9% | $6,505 | 5.1% |
| Picks its best reply, decreases take 14 days | 0.0200% | 26.3% | $7,165 | 5.4% |
| Picks its best reply, decreases take 1 day | 0.0200% | 34.3% | $9,384 | 5.6% |
| *Nobody responds at all* | *0.0500%* | *23.4%* | *$8,797* | *5.3%* |

- Responding is worth two to three times the venue's revenue against a competitor that reacts.
- A 1-day timelock on decreases beats 14 days by 31% to 53%.
- Fighting the fee war leaves us about where we were if nobody had reacted, because cheaper trading grows the pair's volume. That depends on trading growing as it gets cheaper, which is an assumption.

**Recommendation.** Three rules:
1. The fee may move inside bounds written into the code.
2. A decrease takes effect after a short timelock; an increase keeps the long one.
3. The floor is set from what the venue needs to run, because whoever has the lower floor outlasts the other.

Whether the fee moves by a keeper, by a rule the contract applies to an on-chain signal, or by hand through the fast path is a separate design question and is not ruled here.

**Spec impact.** Amends §18.4 and the fee-registry rule in §12 (one mutable surface, timelocked) to allow a fast downward path.

`python3 -m sim.run --scenario tight --seeds 40 --set competitor_response=2 --set competitor_depth_speed=2 --set our_response=2` (0 = never moves, 1 = follows; `--set fee_down_delay_days=14` for the slow case)

---

## 4. How big is the venue cut?

Traders never see the cut, because it sits inside the fee. LPs do: it lowers their yield, some leave, and the pool gets shallower. How much depends on how well the pool pays.

| Venue cut | Well-paid stable pair: TVL | Venue collects | Thin stable pair: TVL | Venue collects |
|---|---|---|---|---|
| 10% | $7.49M | $60,450 | $3.11M | $8,797 |
| 20% | $7.42M | $120,209 | $2.65M | $15,485 |
| 30% | $7.33M | $178,975 | $2.20M | $20,008 |
| 40% | $7.18M | $235,846 | $1.76M | $21,965 |

- In a well-paid pool, going from 10% to 40% costs 4% of depth and nearly quadruples revenue.
- In a thin pool it costs 43% of depth for two and a half times the revenue, and the last step from 30% to 40% gives up 20% of depth for 10% more revenue.

**Recommendation.** Do not rule one flat number. Rule the shape: the cut is set per pool, with a ceiling in code, lower where LP yield is close to what LPs can get elsewhere. I would start well-paid pools near 20% and thin pools near 10%. A cut that adjusts itself to a pool's yield is worth designing but has not been simulated.

**Spec impact.** §18.4 says "a small venue cut" with the size open. This sets it per pool and changes "small".

`python3 -m sim.run --seeds 40 --set venue_cut_pct=20` (add `--scenario tight` for the thin pair)

---

## 5. Keep the fee hold?

Spec §18.3 holds fees earned while a position seasons and unlocks them over the horizon. The simulator shows the hold, not the weight ramp, is what turns hot money away.

Well-paid stable pair.

| Seasoning | Hot money that enters | Medium-stay that enters | Average TVL | Long-stay LP APR | POL owned |
|---|---|---|---|---|---|
| None (plain pool) | 99.8% | 99.9% | $7.89M | 14.5% | $12,379 |
| Floor 0.4, 28 days, hold on | 18.2% | 88.4% | $7.49M | 15.7% | $14,767 |
| Floor 0.4, 28 days, hold off | 77.6% | 97.0% | $7.78M | 15.5% | $12,296 |
| Floor 0.7, 28 days, hold off | 98.6% | 99.5% | $7.88M | 15.0% | $12,372 |

- With the hold, seasoning keeps out four fifths of hot money, moves about a point of yield to LPs who stay, and adds a fifth to POL. It costs 5% of depth.
- Without the hold, seasoning does little. At a floor of 0.7 it is indistinguishable from the plain pool.
- Seasoning does not hold liquidity in a shock, with or without the hold: 61.1% stays against 61.5% for the plain pool.

Whether the 5% matters depends on what short-stay depth is worth. If liquidity under a week old counts for a quarter as much with traders, the seasoned pool and the plain pool have the same usable depth ($6.70M and $6.71M) and the same venue revenue.

**This one is a judgment about the product, and it is yours.**
- **Keep the hold** if the aim is a pool whose depth can be relied on and whose yield goes to those who stay. Accept about 5% less headline TVL.
- **Drop the hold** if headline TVL matters more. Then drop the weight ramp too, since it does almost nothing alone, and V5 becomes the lock plus the fee policy.

**Recommendation: keep it**, as a per-pool setting, and say plainly that seasoning is a filter and not run protection.

**Spec impact.** None if kept. The wording in §3 that parked capital is protected should not be read as protection in a shock; that job is the lock's.

`python3 -m sim.run --seeds 40` (add `--set u0=1` for hold off, `--set fresh_depth_value=0.25` to discount short-stay depth)

---

## 6. Soft tier: no principal toll

Spec §18.3 allows "at most a small anti-churn floor" on principal for early soft-tier exits. Nothing in the simulator needed one: the fee hold already does that job.

**Recommendation: set it to zero** and leave the config field in place.

**Spec impact.** Settles one OPEN number in §18.3.

---

## 7. Not ready to rule

The searches did not agree on these, so I would leave them OPEN and give ranges.

| Setting | What the evidence supports | What it does not settle |
|---|---|---|
| Seasoning horizon | Short: one to four weeks. | The exact figure. |
| Seasoning floor | Below about 0.5 if the hold is kept and filtering is the aim. | The exact figure; the searches ranged from 0.4 to 0.8. |
| Lock exit cost | 5% to 10%. Not 2%, not 20%. | Where in that range. |
| Lock term | Nothing. Winners used 30, 60, 90 and 180 days. | Everything. |

---

## 8. Carried over, still open

- **How the claim maths reads the spec.** The exact test depends on choices listed at the top of `sim/hall.py`. The main one: whoever owns a position when an epoch closes earns that whole epoch, so a transfer mid-epoch gives the current epoch to the receiver. The council should confirm or correct each.
- **Three wording points in spec v1.16**: "no release before the token exists" cannot be checked by code on a chain other than home; the sunset bullet reads as unconditional; the brief's Token paragraph still describes sending funds home over CCTP.
- **O3** legal review, **O4** the Arc PoolManager date, **O6** the home chain.

---

## Corrections to what I reported earlier

- **Flat exit cost.** I called it "the clear win" (84.4% retained against 74.0%). That was with a 1.25 boost and before the two pools were given identical draws. With no boost it is level with a melting cost. See ruling 2.
- **Fee hold.** After the first search I said winning designs drop the hold. That search's depth test was mostly noise. The like-for-like runs in ruling 5 show the hold is the part of seasoning that works.
- **Search specifics.** "Only 49 of 318 designs passed" and the first search's finalist figures should be disregarded. The corrected searches are in `sim/out/` when rerun with `python3 -m sim.search`.
- **Venue revenue multiples of five to six times** from the corrected searches rest mostly on a 40% venue cut, the highest value the search was allowed to try, measured against a plain pool with a fixed fee and a 10% cut. Ruling 4 gives the like-for-like figures.

## What the simulator still cannot tell you

The tuning-fork fee, the depeg waiver, the token phase and more than one pool are not modelled. How LPs behave in a shock, how often they need their money back, how much trading grows when it gets cheaper, and the competitor's fee floor are all assumptions, and several results above move with them.

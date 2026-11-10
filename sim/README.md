# V5 simulator

Python 3, standard library only. Nothing to install.

```
python3 -m unittest sim.test_hall -v     # the first test: claim maths, exact
python3 -m unittest sim.test_model       # sanity checks on the scenario model
python3 -m sim.run                       # the stable scenario against a plain pool
python3 -m sim.run --scenario shock      # stable | tight | volatile | shock | hardlock
python3 -m sim.run --sweep               # floor x horizon grid -> sim/out/sweep-<scenario>.csv
python3 -m sim.run --sweep fees          # gross fee x venue cut grid -> sim/out/fees-<scenario>.csv
python3 -m sim.run --set floor=0.6 --set horizon_days=14 --seeds 20
```

## What is here

| File | What it does |
|---|---|
| `hall.py` | The Epoch Hall's bookkeeping, twice: the constant-time version a contract would use, and a brute-force version. |
| `test_hall.py` | Runs both on the same operations with exact fractions and requires equality. Covers the cases listed in spec v1.16 O5. |
| `model.py` | One V5 pool, a fee waterfall, and a stream of LPs who each decide whether to enter. |
| `test_model.py` | Checks that every scenario accounts for every fee and every banked dollar. |
| `run.py` | Command line: a scenario table, or a parameter sweep. |

## The first test

Spec O5 asks that the two-accumulator claim maths match a brute-force calculation before any seasoning number is set. It does, exactly, across 120 random operation sequences and these named cases:

- crossing the horizon
- a late deposit just before a refund
- a transfer mid-epoch, inside the horizon, followed by an exit by the new owner, and into a wrapper
- a merge of two mature positions
- an early exit whose forfeit goes to POL and seasoned weight
- a refund after a partial draw

Each run also checks that deferred claims add up to exactly what was banked, and that every unit of fees is accounted for.

## Interpretations the test depends on

The spec leaves these open. They are choices made here, not rulings, and `hall.py` lists them at the top.

- Age is counted in whole epochs, so the horizon is crossed at an epoch boundary.
- Whoever owns a position when an epoch closes earns that epoch. A mid-epoch transfer gives the whole current epoch to the receiver.
- The unlocked share applies to all fees a position has earned so far, and rises on the same line as its weight.
- Held fees travel with a transferred position. Deferred claims stay with the wallet.
- Compounding is in whole units; one unit of fees buys one unit of shares.

## Scenarios

| Name | What it sets up |
|---|---|
| `stable` | A stable pair with plenty of volume. The default. |
| `tight` | The same pair with thin volume, so the pool pays about what LPs can get elsewhere. |
| `volatile` | A 50/50 pair with a moving price, a higher fee and less organic volume. |
| `shock` | `volatile`, plus a 30% price fall on day 90 that makes LPs consider leaving. |
| `hardlock` | `shock`, with a 90-day hard-lock tier on offer. |
| `twoshock` | `hardlock` over 240 days with a second shock on day 150, so some locks have run their term. |

Any parameter can be overridden with `--set name=value`, and `--sweep` works with any scenario.

## What the model assumes

The scenario numbers are only as good as these. All are parameters in `model.py`.

- One pool. One share is one dollar on a stable pair. On a volatile pair the pool is 50/50, the price follows a random walk, and each LP's loss against simply holding is tracked.
- Traders react to price. The pair has a fixed amount of trading per day across all venues. Each trade, drawn from a spread of sizes, is split between our pool and one competitor so that the last dollar costs the same in both, counting fee and price impact. That is what an aggregator does. Small trades go wholly to the lower fee; large trades split by depth. A stable pair trades with far less price impact, so its flow is far more sensitive to the fee.
- Total trading responds to cost. Before we arrive the pair trades `market_daily_volume` a day with the competitor alone. A 1% fall in the average cost of a trade (fee plus price impact, across both venues) adds `demand_elasticity` percent to trading, 1.0 by default. So our depth grows the market, and higher fees anywhere shrink it. Set it to 0 to fix total trading.
- Traders see the gross fee only. The venue cut sits inside it, so its cost shows up as lower LP yield and, through that, less depth.
- `competitor_response` sets how the competitor behaves on fee. 0: it never changes. 1: it matches ours whenever ours is lower. 2: every week it moves to whichever fee earns it the most against ours. It first reacts after 14 days and never goes below 0.4 times its day-one fee. Its depth is fixed in every case, and our own fee never changes during a run.
- A moving price adds the trading needed to keep the pool at the market price, less the moves too small to be worth arbitraging past the fee.
- LPs arrive at random with a size, a planned stay (days, weeks or months) and an outside rate they could earn elsewhere. Each enters only if the pool's recent fee pace, the weight ramp, the fee hold and any toll leave them above that rate, plus the expected loss to price moves. They leave when their planned stay ends.
- In a shock, 60% of LPs do nothing. Each of the rest fears losing up to 5% of their position and leaves if that fear is larger than what leaving costs them.
- A hard-locked position seasons on the same ramp with a weight multiplier, and pays a share of principal to leave early that melts to zero over the term. An LP takes the lock only if it plans to stay the whole term and the lock pays enough more.
- `toll_mode` sets where a lock's exit toll goes. 0 is spec §18.3: a POL share, the rest to all seasoned weight. 1 pays it all to LPs locked before the exit, each toll paid out over one lock term and lost by a receiver who leaves first. 2 is the same, except the credit unlocks over the receiver's own lock term.
- Anchor tenants are in from day one and never leave.
- The venue's POL line, and the POL share of forfeits and tolls, are deposited as liquidity daily.
- The prize slice is paid to the Hall every 30 days as ordinary fees, which approximates "by seasoned weight over the month".
- Pre-token only: half the buyback line goes to LPs, half is banked up to the holding cap.

Not modelled yet: a competitor whose depth changes, our own fee responding in turn, the tuning-fork fee, the depeg waiver, the token phase, more than one pool, compounding vaults, and LPs who react to each other.

## Reading the output

Every default is a placeholder. A table from this tool shows how the mechanism responds to a setting; it does not show what a real pool will earn. A ruling should cite the run and the parameters it used.

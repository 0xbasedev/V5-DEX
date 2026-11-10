# V5 simulator

Python 3, standard library only. Nothing to install.

```
python3 -m unittest sim.test_hall -v     # the first test: claim maths, exact
python3 -m sim.run                       # one scenario against a plain pool
python3 -m sim.run --sweep               # floor x horizon grid -> sim/out/sweep.csv
python3 -m sim.run --set floor=0.6 --set horizon_days=14 --seeds 20
```

## What is here

| File | What it does |
|---|---|
| `hall.py` | The Epoch Hall's bookkeeping, twice: the constant-time version a contract would use, and a brute-force version. |
| `test_hall.py` | Runs both on the same operations with exact fractions and requires equality. Covers the cases listed in spec v1.16 O5. |
| `model.py` | One V5 pool, a fee waterfall, and a stream of LPs who each decide whether to enter. |
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

## What the model assumes

The scenario numbers are only as good as these. All are parameters in `model.py`.

- One pool. One share is one dollar: no price moves and no impermanent loss.
- Volume grows with depth (to the power 0.6 by default) with random noise.
- LPs arrive at random with a size, a planned stay (days, weeks or months) and an outside rate they could earn elsewhere. Each enters only if the pool's recent fee pace, the weight ramp, the fee hold and any toll leave them above that rate. They leave when their planned stay ends.
- Anchor tenants are in from day one and never leave.
- The venue's POL line and the POL share of forfeits are deposited as liquidity daily.
- The prize slice is paid to the Hall every 30 days as ordinary fees, which approximates "by seasoned weight over the month".
- Pre-token only: half the buyback line goes to LPs, half is banked up to the holding cap.

Not modelled yet: the hard-lock tier, the tuning-fork fee, price risk, the token phase, more than one pool, and LPs who react to each other or to a shock.

## Reading the output

Every default is a placeholder. A table from this tool shows how the mechanism responds to a setting; it does not show what a real pool will earn. A ruling should cite the run and the parameters it used.

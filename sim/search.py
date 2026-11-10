"""Search the design space for settings that beat the plain pool.

  python3 -m sim.search                         # default search, about five minutes on four cores
  python3 -m sim.search --candidates 400 --rounds 4 --seeds 8
  python3 -m sim.search --tolerance 0           # never accept less depth than the plain pool

A candidate is a set of values for the things the protocol controls. Each one
is run in several market environments, with the same random draws as the
plain pool it is compared against. A candidate is kept only if its depth is
within `--tolerance` percent of the plain pool's in every environment. The
keepers are ranked on two things: what the venue earns, and how much
liquidity stays through a shock. The best are then run again on fresh random
draws, because the best of many noisy results always looks better than it is.

Results: sim/out/search.csv (every candidate) and the table printed at the end.
"""

import argparse
import csv
import math
import os
import random
from multiprocessing import Pool

from .model import Params, SCENARIOS, simulate

# What the protocol controls, and the values tried. The lock's weight boost is
# not here: it is ruled out, so it stays at 1.
SPACE = {
    "floor": [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
    "horizon_days": [7, 14, 21, 28, 42, 56],
    "u0": [0.1, 0.25, 0.4, 0.6, 0.8, 1.0],
    "pol_share_pct": [0, 15, 30, 50],
    "principal_floor_pct": [0, 0.25, 0.5, 1.0],
    "venue_cut_pct": [5, 10, 15, 20, 30, 40],
    "hard_lock_days": [0, 30, 60, 90, 180],
    "hard_exit_pct": [2, 5, 10, 15, 20],
    "lock_melt_floor": [0.0, 0.5, 1.0],
    "lock_rolls": [0, 1],
    "hard_skips_ramp": [0, 1],
    "toll_mode": [0, 1],
    "lock_budget_pct": [0, 10, 20, 30],
    "our_response": [0, 1, 2],
    "fee_down_delay_days": [1, 7, 14],
}

# The markets every candidate has to cope with. Each is (scenario, overrides).
_RIVAL = dict(competitor_response=2, competitor_depth_speed=2)
ENVIRONMENTS = {
    "stable, competitor asleep": ("stable", {}),
    "stable, competitor awake": ("stable", _RIVAL),
    "thin, competitor awake": ("tight", _RIVAL),
    "volatile, two shocks": ("twoshock", {}),
}


def environment(name):
    scenario, extra = ENVIRONMENTS[name]
    return Params().but(**SCENARIOS[scenario]).but(**extra)


def venue_value(p, r):
    """What the venue ends up with: its cut (the POL line counted once, as the
    liquidity it bought), what that liquidity earned, and any POL from tolls."""
    return r["venue_cut"] * (1 - p.pol_pct / 100) + r["pol_value"] + r["pol_income"]


def measure(job):
    """Run one design in one environment over several seeds."""
    design, env_name, seeds, first_seed = job
    base = environment(env_name)
    if design is None:
        p = base.plain()
    elif design.get("_plain"):
        # The same pool with the same fee policy and venue cut, but no seasoning and no lock.
        p = base.but(**{k: v for k, v in design.items() if k != "_plain"}).plain()
    else:
        p = base.but(**design)
    tvl = value = apr = 0.0
    kept = []
    for s in range(seeds):
        r = simulate(p.but(seed=first_seed + s))
        tvl += r["tvl_avg"]
        value += venue_value(p, r)
        apr += r["net_apr_long"] if r["net_apr_long"] == r["net_apr_long"] else 0.0
        kept += [r[k] for k in ("shock_retained_pct", "shock2_retained_pct") if r[k] == r[k]]
    return dict(tvl=tvl / seeds, value=value / seeds, apr=apr / seeds,
                kept=sum(kept) / len(kept) if kept else float("nan"))


def score(design, results, baseline):
    """Compare one design's results with the plain pool's, environment by environment."""
    depth, revenue, lp, kept = [], [], [], []
    for env in ENVIRONMENTS:
        mine, plain = results[env], baseline[env]
        depth.append(mine["tvl"] / plain["tvl"])
        revenue.append(mine["value"] / plain["value"])
        lp.append(mine["apr"] - plain["apr"])
        if mine["kept"] == mine["kept"]:
            kept.append(mine["kept"] - plain["kept"])
    return dict(design,
                worst_depth_pct=100 * (min(depth) - 1),
                revenue_x=math.exp(sum(math.log(max(x, 1e-9)) for x in revenue) / len(revenue)),
                kept_points=sum(kept) / len(kept),
                lp_apr_points=sum(lp) / len(lp))


def evaluate(pool, designs, seeds, first_seed, baseline=None):
    jobs = [(d, env, seeds, first_seed) for d in designs for env in ENVIRONMENTS]
    flat = pool.map(measure, jobs, chunksize=4)
    n = len(ENVIRONMENTS)
    grouped = [dict(zip(ENVIRONMENTS, flat[i * n:(i + 1) * n])) for i in range(len(designs))]
    if baseline is None:
        return grouped
    return [score(d, g, baseline) for d, g in zip(designs, grouped)]


def random_design(rng):
    return tidy({k: rng.choice(v) for k, v in SPACE.items()})


def mutate(rng, design):
    child = dict(design)
    for k in rng.sample(list(SPACE), rng.choice([1, 1, 2, 3])):
        values = SPACE[k]
        i = values.index(child[k]) if child[k] in values else rng.randrange(len(values))
        child[k] = values[max(0, min(len(values) - 1, i + rng.choice([-1, 1])))]
    return tidy(child)


def tidy(d):
    """Settings that do nothing are put back to their defaults, so that two
    designs that behave the same are the same design."""
    if not d["hard_lock_days"]:
        d.update(hard_exit_pct=SPACE["hard_exit_pct"][0], lock_melt_floor=0.0, lock_rolls=0,
                 hard_skips_ramp=0, toll_mode=0, lock_budget_pct=0)
    if not d["our_response"]:
        d["fee_down_delay_days"] = SPACE["fee_down_delay_days"][0]
    return d


def key(d):
    return tuple(d[k] for k in SPACE)


def frontier(rows):
    """Rows that no other row beats on both revenue and liquidity kept."""
    best = []
    for r in rows:
        if not any(o["revenue_x"] >= r["revenue_x"] and o["kept_points"] >= r["kept_points"]
                   and (o["revenue_x"] > r["revenue_x"] or o["kept_points"] > r["kept_points"]) for o in rows):
            best.append(r)
    return sorted(best, key=lambda r: -r["revenue_x"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--candidates", type=int, default=240, help="random designs to start from")
    ap.add_argument("--rounds", type=int, default=3, help="rounds of refining the best so far")
    ap.add_argument("--seeds", type=int, default=6, help="random runs per design per environment")
    ap.add_argument("--tolerance", type=float, default=3.0, help="depth a design may give up against the plain pool, %%")
    ap.add_argument("--finalists", type=int, default=12)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    with Pool() as pool:
        baseline = evaluate(pool, [None], args.seeds, 1000)[0]
        seen, rows = set(), []

        def run_batch(designs, label):
            fresh = []
            for d in designs:
                if key(d) not in seen:
                    seen.add(key(d))
                    fresh.append(d)
            rows.extend(evaluate(pool, fresh, args.seeds, 1000, baseline))
            ok = [r for r in rows if r["worst_depth_pct"] >= -args.tolerance]
            print(f"{label}: {len(fresh)} new designs, {len(rows)} tried, {len(ok)} keep the pool's depth")
            return ok

        ok = run_batch([random_design(rng) for _ in range(args.candidates)], "random start")
        for i in range(args.rounds):
            parents = frontier(ok) or sorted(rows, key=lambda r: -r["worst_depth_pct"])[:10]
            children = [mutate(rng, {k: par[k] for k in SPACE}) for par in parents for _ in range(8)]
            ok = run_batch(children, f"refining, round {i + 1}")

        os.makedirs("sim/out", exist_ok=True)
        with open("sim/out/search.csv", "w", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)

        # The best of many noisy results looks better than it is. Run the leaders
        # again on random draws they have not seen, and report those numbers.
        leaders = frontier(ok)[:args.finalists]
        designs = [{k: r[k] for k in SPACE} for r in leaders]
        fresh_baseline = evaluate(pool, [None], 4 * args.seeds, 5000)[0]
        checked = evaluate(pool, designs, 4 * args.seeds, 5000, fresh_baseline)
        # How much of each finalist's result is seasoning and the lock, and how much is
        # its fee policy and venue cut? Compare it with itself minus seasoning.
        twins = evaluate(pool, [dict(d, _plain=True) for d in designs], 4 * args.seeds, 5000)
        mine = evaluate(pool, designs, 4 * args.seeds, 5000)
        for row, d, own, twin in zip(checked, designs, mine, twins):
            own_score = score(d, own, twin)
            row["seasoning_revenue_x"] = own_score["revenue_x"]
            row["seasoning_depth_pct"] = own_score["worst_depth_pct"]
            row["seasoning_kept_points"] = own_score["kept_points"]

    print(f"\nFinalists, run again on {4 * args.seeds} fresh draws per environment (plain pool = 1.00x revenue, 0 points):\n")
    short = dict(floor="floor", horizon_days="days", u0="u0", pol_share_pct="pol%", principal_floor_pct="toll%",
                 venue_cut_pct="cut%", hard_lock_days="lock", hard_exit_pct="exit%", lock_melt_floor="melt",
                 lock_rolls="roll", hard_skips_ramp="skip", toll_mode="tolls", lock_budget_pct="budg%",
                 our_response="fee", fee_down_delay_days="down")
    print("".join(f"{short[k]:>6}" for k in SPACE) + f"{'revenue':>10}{'kept':>8}{'depth':>8}{'LP APR':>8}"
          + "   | seasoning alone:" + f"{'revenue':>9}{'kept':>8}{'depth':>8}")
    for r in sorted(checked, key=lambda r: -r["revenue_x"]):
        flag = "" if r["worst_depth_pct"] >= -args.tolerance else "  (fails depth on fresh draws)"
        print("".join(f"{r[k]:>6g}" for k in SPACE)
              + f"{r['revenue_x']:>9.2f}x{r['kept_points']:>+8.1f}{r['worst_depth_pct']:>+7.1f}%{r['lp_apr_points']:>+8.1f}"
              + " " * 21 + f"{r['seasoning_revenue_x']:>8.2f}x{r['seasoning_kept_points']:>+8.1f}{r['seasoning_depth_pct']:>+7.1f}%{flag}")

    print("\nWhat the designs that keep the pool's depth have in common (share of the top 30 by revenue):")
    top = sorted(ok, key=lambda r: -r["revenue_x"])[:30]
    for k in SPACE:
        counts = {}
        for r in top:
            counts[r[k]] = counts.get(r[k], 0) + 1
        common = sorted(counts.items(), key=lambda kv: -kv[1])[:3]
        print(f"  {k:22}" + "   ".join(f"{v:g}: {100 * c // len(top)}%" for v, c in common))
    print("\nEvery candidate: sim/out/search.csv")
    print("Columns: revenue = venue's take against the plain pool; kept = extra points of liquidity left after a shock;")
    print("depth = worst case against the plain pool across environments; LP APR = long-stay net APR, points against plain.")
    print("'Seasoning alone' compares each finalist with the same pool, fee policy and venue cut but no seasoning or lock.")


if __name__ == "__main__":
    main()

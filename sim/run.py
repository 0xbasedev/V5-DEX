"""Run the V5 simulator.

  python3 -m sim.run                       the stable-pair scenario against a plain pool
  python3 -m sim.run --scenario shock      stable | tight | volatile | shock | hardlock | twoshock
  python3 -m sim.run --set floor=0.6 --set horizon_days=14
  python3 -m sim.run --sweep               floor x horizon grid, written to sim/out/sweep-<scenario>.csv
  python3 -m sim.run --sweep fees          gross fee x venue cut grid, written to sim/out/fees-<scenario>.csv
  python3 -m sim.run --sweep lock --scenario hardlock    lock boost x exit cost grid
  python3 -m sim.run --seeds 20            average over more random runs
"""

import argparse
import csv
import os
from dataclasses import asdict, fields

from .model import Params, SCENARIOS, average

ROWS = [
    ("Depth", None),
    ("tvl_avg", "Average TVL ($)"),
    ("tvl_end", "TVL at the end ($)"),
    ("seasoned_share_pct", "TVL that is fully seasoned (%)"),
    ("volume", "Volume ($)"),
    ("market_share_pct", "Share of the pair's trading (%)"),
    ("market_growth_pct", "Trading in the pair, vs before we arrived (%)"),
    ("our_fee_end", "Our fee at the end (%)"),
    ("our_fee_changes", "Times our fee changed"),
    ("rival_fee_end", "Competitor's fee at the end (%)"),
    ("rival_tvl_end", "Competitor's TVL at the end ($)"),
    ("hard_share_pct", "TVL that is hard-locked (%)"),
    ("At the shock", None),
    ("shock_seasoned_mix_pct", "LP capital that was fully seasoned (%)"),
    ("shock_hard_mix_pct", "LP capital that was hard-locked (%)"),
    ("shock_retained_pct", "Liquidity still there afterwards (%)"),
    ("shock_kept_seasoned_pct", "  of seasoned capital (%)"),
    ("shock_kept_fresh_pct", "  of fresh capital (%)"),
    ("shock_kept_hard_pct", "  of hard-locked capital (%)"),
    ("shock_kept_soft_pct", "  of unlocked capital (%)"),
    ("At the second shock", None),
    ("shock2_hard_mix_pct", "LP capital that was hard-locked (%)"),
    ("shock2_retained_pct", "Liquidity still there afterwards (%)"),
    ("shock2_kept_hard_mid_pct", "  of capital still inside its lock (%)"),
    ("shock2_kept_hard_done_pct", "  of capital past its lock term (%)"),
    ("shock2_kept_soft_pct", "  of unlocked capital (%)"),
    ("Who gets in (% of capital offered)", None),
    ("accepted_hot_pct", "Hot money, stays days"),
    ("accepted_medium_pct", "Medium, stays weeks"),
    ("accepted_long_pct", "Long, stays months"),
    ("accepted_long_late_pct", "Long, arriving in the second half"),
    ("lock_take_pct", "Capital that could lock and did (%)"),
    ("What LPs earned from fees (APR %)", None),
    ("apr_anchor", "Anchor tenants"),
    ("apr_long", "Long"),
    ("apr_medium", "Medium"),
    ("apr_hot", "Hot"),
    ("apr_locked", "Locked positions"),
    ("apr_unlocked_long", "Long, not locked"),
    ("new_vs_mature_pct", "New dollar vs seasoned dollar, first horizon (%)"),
    ("After price moves (APR %)", None),
    ("net_apr_anchor", "Anchor tenants"),
    ("net_apr_long", "Long"),
    ("net_apr_medium", "Medium"),
    ("net_apr_hot", "Hot"),
    ("Venue ($)", None),
    ("venue_cut", "Venue cut, all lines"),
    ("build", "Build fund"),
    ("pol_value", "POL owned"),
    ("pol_income", "Fees earned by POL"),
    ("banked", "Banked for the launch burn"),
    ("forfeited_fees", "Fees forfeited by early leavers"),
    ("principal_tolls", "Principal paid to leave a lock early"),
    ("tolls_to_lockers", "  of which paid on to LPs who stayed locked"),
]


def fmt(key, v):
    if v != v:
        return "n/a"
    if key == "our_fee_changes":
        return f"{v:.1f}"
    if key.startswith(("rival_fee", "our_fee")):
        return f"{v:.4f}"
    return f"{v:,.1f}" if key.endswith("_pct") or "apr_" in key else f"{v:,.0f}"


def parse_sets(pairs):
    types = {f.name: f.type for f in fields(Params)}
    out = {}
    for pair in pairs:
        k, v = pair.split("=", 1)
        if k not in types:
            raise SystemExit(f"unknown parameter: {k}")
        out[k] = int(v) if types[k] is int else float(v)
    return out


def scenario(p, seeds, name):
    ea, eb = {}, {}
    a, b = average(p, seeds, ea), average(p.plain(), seeds, eb)

    def cell(key, vals, errs):
        text = fmt(key, vals[key])
        return f"{text} ±{errs[key]:.1f}" if key.startswith("shock") and key in errs else text

    lock = f", hard lock {p.hard_lock_days:g} days" if p.hard_lock_days else ""
    print(f"{name}: floor {p.floor}, horizon {p.horizon_days:g} days{lock}, {p.days} days, mean of {seeds} runs\n")
    print(f"{'':50}{'V5':>14}{'Plain pool':>14}")
    for key, label in ROWS:
        if label is None:
            print(f"\n{key}")
        else:
            print(f"  {label:48}{cell(key, a, ea):>14}{cell(key, b, eb):>14}")


def sweep_fees(p, seeds, name):
    """Gross fee (as a multiple of the competitor's) by venue cut."""
    multiples = [0.6, 0.8, 1.0, 1.2, 1.5, 2.0]
    cuts = [10, 20, 40]
    cols = ["tvl_end", "market_share_pct", "market_growth_pct", "rival_fee_end", "rival_tvl_end", "apr_long", "venue_cut"]
    os.makedirs("sim/out", exist_ok=True)
    path = f"sim/out/fees-{name}.csv"
    print(f"{'fee %':>7}{'cut %':>7}" + "".join(f"{c:>18}" for c in cols))
    with open(path, "w", newline="") as fh:
        writer = None
        for mult in multiples:
            fee = round(p.competitor_fee_pct * mult, 4)
            for cut in cuts:
                r = average(p.but(gross_fee_pct=fee, venue_cut_pct=cut), seeds)
                row = dict(gross_fee_pct=fee, venue_cut_pct=cut, **r)
                if writer is None:
                    writer = csv.DictWriter(fh, fieldnames=list(row))
                    writer.writeheader()
                writer.writerow(row)
                print(f"{fee:>7g}{cut:>7}" + "".join(f"{fmt(c, r[c]):>18}" for c in cols))
    how = ["never changes it", "matches a lower fee", "picks its best reply"][p.competitor_response]
    print(f"\nFull results: {path}  (the competitor starts at {p.competitor_fee_pct:g}% and {how})")


def sweep_lock(p, seeds, name):
    """Weight boost for a locked position by the cost of leaving early."""
    if not p.hard_lock_days:
        raise SystemExit("this scenario has no hard lock; try --scenario hardlock")
    boosts = [1.1, 1.25, 1.5, 2.0, 3.0]
    exits = [2, 5, 10, 20]
    cols = ["lock_take_pct", "hard_share_pct", "tvl_avg", "shock_retained_pct", "apr_locked",
            "apr_unlocked_long", "principal_tolls", "pol_value"]
    os.makedirs("sim/out", exist_ok=True)
    path = f"sim/out/lock-{name}.csv"
    print(f"{'boost':>6}{'exit %':>7}" + "".join(f"{c:>19}" for c in cols))
    with open(path, "w", newline="") as fh:
        writer = None
        for boost in boosts:
            for cost in exits:
                r = average(p.but(hard_boost=boost, hard_exit_pct=cost), seeds)
                row = dict(hard_boost=boost, hard_exit_pct=cost, **r)
                if writer is None:
                    writer = csv.DictWriter(fh, fieldnames=list(row))
                    writer.writeheader()
                writer.writerow(row)
                print(f"{boost:>6g}{cost:>7}" + "".join(f"{fmt(c, r[c]):>19}" for c in cols))
    print(f"\nFull results: {path}  ({p.hard_lock_days:g}-day lock)")


def sweep(p, seeds, name):
    floors = [0.2, 0.4, 0.6, 0.8, 1.0]
    horizons = [7, 14, 28, 56]
    cols = ["tvl_avg", "accepted_hot_pct", "accepted_long_late_pct", "apr_long", "apr_hot",
            "new_vs_mature_pct", "shock_retained_pct", "venue_total"]
    os.makedirs("sim/out", exist_ok=True)
    path = f"sim/out/sweep-{name}.csv"
    print(f"{'floor':>6}{'days':>6}" + "".join(f"{c:>24}" for c in cols))
    with open(path, "w", newline="") as fh:
        writer = None
        for floor in floors:
            for horizon in horizons:
                r = average(p.but(floor=floor, horizon_days=horizon, u0=floor), seeds)
                row = dict(floor=floor, horizon_days=horizon, **r)
                if writer is None:
                    writer = csv.DictWriter(fh, fieldnames=list(row))
                    writer.writeheader()
                writer.writerow(row)
                print(f"{floor:>6}{horizon:>6}" + "".join(f"{fmt(c, r[c]):>24}" for c in cols))
    print(f"\nFull results: {path}  (u0 is set equal to floor in this grid; floor 1.0 is the plain pool)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", nargs="?", const="seasoning", choices=["seasoning", "fees", "lock"])
    ap.add_argument("--scenario", choices=sorted(SCENARIOS), default="stable")
    ap.add_argument("--seeds", type=int, default=8)
    ap.add_argument("--set", action="append", default=[], metavar="name=value")
    args = ap.parse_args()
    params = Params().but(**SCENARIOS[args.scenario]).but(**parse_sets(args.set))
    job = {"seasoning": sweep, "fees": sweep_fees, "lock": sweep_lock, None: scenario}[args.sweep]
    job(params, args.seeds, args.scenario)

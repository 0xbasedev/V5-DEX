"""A V5 pool with seasoning, run against a stream of LPs who decide for themselves.

Everything here that is not a spec rule is an assumption, listed in README.md.
Every default in `Params` is a placeholder to be swept, not a ruling.
"""

import math
import random
from dataclasses import dataclass, asdict

from .hall import AccHall, ramp

KINDS = ("hot", "medium", "long")


@dataclass
class Params:
    # --- seasoning (spec §18.3, all OPEN) ---
    floor: float = 0.4               # weight of a brand-new position, as a share of full weight
    horizon_days: float = 28         # days to full weight and free exit
    u0: float = 0.4                  # share of earned fees unlocked at age zero
    pol_share_pct: float = 30        # share of forfeits that becomes POL; the rest goes to seasoned weight
    principal_floor_pct: float = 0   # anti-churn principal toll at age zero, melting to zero at the horizon

    # --- fees (spec §18.4, all OPEN) ---
    gross_fee_pct: float = 0.05      # of volume
    venue_cut_pct: float = 10        # of the gross fee
    build_pct: float = 40            # pre-token split of the venue cut; the four lines sum to 100
    pol_pct: float = 20
    buyback_pct: float = 30
    prize_pct: float = 10
    holding_cap: float = 250_000     # escrow stops taking the banked half here (per chain)

    # --- market (assumptions) ---
    days: int = 180
    epochs_per_day: int = 4
    volume_at_ref: float = 2_000_000     # daily volume when TVL equals tvl_ref
    tvl_ref: float = 1_000_000
    depth_elasticity: float = 0.6        # volume grows with TVL to this power
    volume_sigma: float = 0.35           # per-epoch noise
    anchor_tvl: float = 500_000          # anchor tenants, in from day one and never leaving

    # --- LPs (assumptions) ---
    arrivals_per_day: float = 3
    size_median: float = 50_000
    size_sigma: float = 1.0
    mix_hot: float = 0.40                # share of arrivals; the rest are "long"
    mix_medium: float = 0.35
    hold_hot: tuple = (1, 5)             # planned stay in days, uniform
    hold_medium: tuple = (10, 40)
    hold_long: tuple = (90, 365)
    outside_apr_pct: float = 6           # what an LP can earn elsewhere, mean
    outside_apr_sd: float = 2

    seed: int = 0

    def plain(self):
        """The same pool with seasoning switched off: the comparison case."""
        d = asdict(self)
        d.update(floor=1.0, u0=1.0, principal_floor_pct=0.0)
        return Params(**d)


def _poisson(rng, lam):
    limit, k, prod = math.exp(-lam), 0, rng.random()
    while prod > limit:
        k += 1
        prod *= rng.random()
    return k


def simulate(p: Params):
    rng = random.Random(p.seed)
    E = p.epochs_per_day
    H = max(1, round(p.horizon_days * E))
    hall = AccHall(p.floor, H, p.u0, p.pol_share_pct / 100)
    per_year = 365 * E

    meta = {}     # pid -> [kind, shares, epoch in, planned epoch out]
    done = []     # (kind, shares, epochs held, net cash, entry epoch)
    tvl = 0.0
    out = dict(volume=0.0, lp_fees=0.0, build=0.0, banked=0.0, bank_overflow_to_lps=0.0,
               forfeited_fees=0.0, principal_tolls=0.0, pol_value=0.0)
    offered = {k: 0.0 for k in KINDS}
    accepted = {k: 0.0 for k in KINDS}
    pol_cash = prize_pot = 0.0
    pol_seen = 0.0
    seasoned_days = []
    tvl_days = []

    def open_position(kind, size, hold_epochs):
        nonlocal tvl
        pid = hall.deposit(kind, size)
        meta[pid] = [kind, size, hall.e, None if hold_epochs is None else hall.e + hold_epochs]
        tvl += size

    def daily_volume(depth):
        return p.volume_at_ref * (depth / p.tvl_ref) ** p.depth_elasticity

    def hall_fees_per_epoch(depth):
        gross = daily_volume(depth) / E * p.gross_fee_pct / 100
        return gross * (1 - p.venue_cut_pct / 100 * (1 - p.buyback_pct / 200))

    def expected_apr(size, T):
        """What a newcomer expects over a stay of T epochs if fees keep their recent pace."""
        if T <= H:
            sum_w = T * p.floor + (1 - p.floor) * (T * (T - 1) / 2) / H
        else:
            sum_w = H * p.floor + (1 - p.floor) * (H - 1) / 2 + (T - H)
        per_weight = rate / (hall.W + size * sum_w / T)
        kept = size * per_weight * sum_w * ramp(p.u0, T, H)
        toll = size * p.principal_floor_pct / 100 * max(0.0, 1 - T / H)
        return (kept - toll) / size * per_year / T * 100

    open_position("anchor", p.anchor_tvl, None)
    rate = hall_fees_per_epoch(tvl)   # smoothed fees reaching the Hall per epoch
    smooth = 2 / (4 * E + 1)

    for day in range(p.days):
        # LPs whose planned stay is over leave.
        for pid in [k for k, m in meta.items() if m[3] is not None and m[3] <= hall.e]:
            kind, size, e_in, _ = meta.pop(pid)
            age = hall.e - e_in
            cash, forfeited = hall.exit(pid)
            toll = size * p.principal_floor_pct / 100 * max(0.0, 1 - age / H)
            pol_cash += toll * p.pol_share_pct / 100
            hall.add_fees(toll * (1 - p.pol_share_pct / 100))
            out["forfeited_fees"] += forfeited
            out["principal_tolls"] += toll
            tvl -= size
            done.append((kind, size, age, cash - toll, e_in))

        # New LPs look at the pool and decide.
        for _ in range(_poisson(rng, p.arrivals_per_day)):
            x = rng.random()
            kind = "hot" if x < p.mix_hot else "medium" if x < p.mix_hot + p.mix_medium else "long"
            size = p.size_median * math.exp(rng.gauss(0, p.size_sigma))
            lo, hi = getattr(p, "hold_" + kind)
            T = max(1, round(rng.uniform(lo, hi) * E))
            hurdle = rng.gauss(p.outside_apr_pct, p.outside_apr_sd)
            offered[kind] += size
            if expected_apr(size, T) >= hurdle:
                accepted[kind] += size
                open_position(kind, size, T)

        # The venue's POL line, and its share of forfeits, go in as liquidity.
        pol_cash += hall.pol - pol_seen
        pol_seen = hall.pol
        if pol_cash > 0:
            open_position("pol", pol_cash, None)
            pol_cash = 0.0

        for _ in range(E):
            noise = math.exp(rng.gauss(0, p.volume_sigma) - p.volume_sigma ** 2 / 2)
            volume = daily_volume(tvl) / E * noise
            gross = volume * p.gross_fee_pct / 100
            venue = gross * p.venue_cut_pct / 100
            buyback = venue * p.buyback_pct / 100
            to_bank = min(buyback / 2, max(0.0, p.holding_cap - out["banked"]))
            to_hall = gross - venue + buyback - to_bank
            hall.add_fees(to_hall)
            hall.add_bank(to_bank)
            out["volume"] += volume
            out["lp_fees"] += to_hall
            out["banked"] += to_bank
            out["bank_overflow_to_lps"] += buyback / 2 - to_bank
            out["build"] += venue * p.build_pct / 100
            pol_cash += venue * p.pol_pct / 100
            prize_pot += venue * p.prize_pct / 100
            rate += smooth * (to_hall - rate)
            hall.end_epoch()

        if day % 30 == 29:   # the Bonfire: prize slice paid out by seasoned weight
            hall.add_fees(prize_pot)
            out["lp_fees"] += prize_pot
            prize_pot = 0.0

        tvl_days.append(tvl)
        if hall.e >= H:
            ripe = sum(q.s for q in hall.pos.values() if hall.e - q.e0 >= H)
            seasoned_days.append(ripe / tvl)

    hall.settle_all()
    for pid, (kind, size, e_in, _) in meta.items():
        # Still in at the end: count what they have earned, on the view that they stay to unlock it.
        done.append((kind, size, hall.e - e_in, hall.pos[pid].earned, e_in))

    def apr(rows):
        dollar_epochs = sum(s * t for _, s, t, _, _ in rows)
        return sum(c for *_, c, _ in rows) / dollar_epochs * per_year * 100 if dollar_epochs else float("nan")

    for kind in KINDS + ("anchor",):
        out["apr_" + kind] = apr([r for r in done if r[0] == kind])
    out["pol_income"] = sum(r[3] for r in done if r[0] == "pol")
    out["pol_value"] = sum(r[1] for r in done if r[0] == "pol")
    for kind in KINDS:
        out["accepted_" + kind + "_pct"] = 100 * accepted[kind] / offered[kind] if offered[kind] else float("nan")
    out["tvl_end"] = tvl
    out["tvl_avg"] = sum(tvl_days) / len(tvl_days)
    out["seasoned_share_pct"] = 100 * sum(seasoned_days) / len(seasoned_days) if seasoned_days else float("nan")
    out["venue_total"] = out["build"] + out["pol_income"] + out["pol_value"]

    # Growth-trap probe: over one horizon starting mid-run, what does a brand-new
    # dollar earn compared with a fully seasoned one?
    e1 = (p.days // 2) * E
    e2 = min(e1 + H, hall.e)
    mature = hall.cp[e2][0] - hall.cp[e1][0]
    fresh = hall.span(1.0, e1, e1, e2, 0, 1)
    out["new_vs_mature_pct"] = 100 * fresh / mature if mature else float("nan")
    out["mature_apr_mid"] = mature / (e2 - e1) * per_year * 100
    return out


def average(p: Params, seeds):
    runs = []
    for s in range(seeds):
        d = asdict(p)
        d["seed"] = p.seed + s
        runs.append(simulate(Params(**d)))
    keys = runs[0].keys()
    return {k: sum(r[k] for r in runs) / len(runs) for k in keys}

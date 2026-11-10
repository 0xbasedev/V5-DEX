"""A V5 pool with seasoning, run against a stream of LPs who decide for themselves.

Everything here that is not a spec rule is an assumption, listed in README.md.
Every default in `Params` is a placeholder to be swept, not a ruling.
"""

import math
import random
from dataclasses import dataclass, asdict
from statistics import NormalDist

from .hall import AccHall, ramp

KINDS = ("hot", "medium", "long")


@dataclass
class Params:
    # --- seasoning, soft tier (spec §18.3, all OPEN) ---
    floor: float = 0.4               # weight of a brand-new position, as a share of full weight
    horizon_days: float = 28         # days to full weight and free exit
    u0: float = 0.4                  # share of earned fees unlocked at age zero
    pol_share_pct: float = 30        # share of forfeits and tolls that becomes POL; the rest goes to seasoned weight
    principal_floor_pct: float = 0   # anti-churn principal toll at age zero, melting to zero at the horizon

    # --- hard-lock tier (spec §3, all OPEN; 0 days switches it off) ---
    hard_lock_days: float = 0
    hard_boost: float = 1.5          # weight multiplier for a locked position
    hard_exit_pct: float = 5         # principal cost of leaving at day zero, melting to zero at the end of the term
    lock_premium_pct: float = 2      # extra APR an LP wants before accepting a lock
    toll_mode: int = 0               # where a lock's exit toll goes:
                                     #   0  spec §18.3: a POL share, the rest to all seasoned weight
                                     #   1  all to LPs locked before the exit, each toll paid out over one lock term
                                     #   2  all to LPs locked before the exit, unlocking over the receiver's own term

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
    market_daily_volume: float = 15_000_000   # trading in this pair before we arrive, with the competitor alone
    demand_elasticity: float = 1.0       # a 1% fall in the cost of trading adds this many % to trading; 0 fixes it
    competitor_tvl: float = 10_000_000   # the venue traders would otherwise use
    competitor_fee_pct: float = 0.05     # its fee on day one
    competitor_response: int = 0         # 0 never changes its fee
                                         # 1 matches ours whenever ours is lower
                                         # 2 picks whichever fee earns it the most against ours
    competitor_delay_days: int = 14      # how long before it first reacts
    competitor_review_days: int = 7      # how often it reconsiders after that
    competitor_floor_mult: float = 0.4   # it never goes below this multiple of its day-one fee
    trade_median: float = 5_000          # trade sizes are lognormal
    trade_sigma: float = 1.5
    depth_multiplier: float = 50         # how much deeper than 50/50 the curve trades; 1 for a volatile pair
    volume_sigma: float = 0.35           # per-epoch noise
    anchor_tvl: float = 500_000          # anchor tenants, in from day one and never leaving
    annual_vol_pct: float = 0            # price volatility of the pair; 0 is a stable pair
    shock_day: int = -1                  # day of a market shock; -1 for none
    shock_day2: int = -1                 # day of a second shock; -1 for none
    shock_drop_pct: float = 30           # price fall on that day
    shock_fear_pct: float = 5            # LPs each fear losing up to this much of their position
    inertia_pct: float = 0.05            # fear below this never moves anyone
    passive_pct: float = 60              # LPs who do not react to a shock at all

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

    def but(self, **changes):
        d = asdict(self)
        d.update(changes)
        return Params(**d)

    def plain(self):
        """The same pool with seasoning and locks switched off: the comparison case."""
        return self.but(floor=1.0, u0=1.0, principal_floor_pct=0.0, hard_lock_days=0)


_VOLATILE = dict(annual_vol_pct=70, gross_fee_pct=0.30, competitor_fee_pct=0.30, depth_multiplier=1,
                 market_daily_volume=2_500_000)

SCENARIOS = {
    "stable": dict(),
    "tight": dict(market_daily_volume=4_000_000),
    "volatile": dict(_VOLATILE),
    "shock": dict(_VOLATILE, shock_day=90),
    "hardlock": dict(_VOLATILE, shock_day=90, hard_lock_days=90),
    "twoshock": dict(_VOLATILE, shock_day=90, shock_day2=150, hard_lock_days=90, days=240),
}

_Z = [NormalDist().inv_cdf((i + 0.5) / 32) for i in range(32)]


def route(p, tvl, competitor_tvl=None, competitor_fee_pct=None):
    """How the pair's trading splits, and what it costs.

    Each trade is split between our pool and the competitor so that the last
    dollar costs the same in both (fee plus price impact), which is what an
    aggregator does. Small trades go wholly to the lower fee; large trades
    split by depth.

    Returns (our share of the trading, average cost of a dollar traded).
    """
    r1 = tvl / 2 * p.depth_multiplier
    r2 = (p.competitor_tvl if competitor_tvl is None else competitor_tvl) / 2 * p.depth_multiplier
    f1 = p.gross_fee_pct / 100
    f2 = (p.competitor_fee_pct if competitor_fee_pct is None else competitor_fee_pct) / 100
    ours = total = cost = 0.0
    for z in _Z:
        x = p.trade_median * math.exp(p.trade_sigma * z)
        x1 = min(x, max(0.0, r1 * (x + r2 * (f2 - f1)) / (r1 + r2)))
        x2 = x - x1
        cost += f1 * x1 + f2 * x2 + (x1 * x1 / (2 * r1) if r1 else 0.0) + x2 * x2 / (2 * r2)
        ours += x1
        total += x
    return ours / total, cost / total


def our_share(p, tvl, competitor_tvl=None, competitor_fee_pct=None):
    return route(p, tvl, competitor_tvl, competitor_fee_pct)[0]


def market_volume(p, cost):
    """Daily trading in the pair at a given average cost. The reference point is
    the competitor alone at its day-one fee, when trading is `market_daily_volume`."""
    if not p.demand_elasticity:
        return p.market_daily_volume
    reference = route(p, 0.0)[1]
    return p.market_daily_volume * (cost / reference) ** -p.demand_elasticity


def competitor_reply(p, tvl, current_fee_pct):
    """The fee the competitor moves to when it reconsiders."""
    floor = p.competitor_fee_pct * p.competitor_floor_mult
    if p.competitor_response == 1:
        return max(floor, min(current_fee_pct, p.gross_fee_pct))
    if p.competitor_response == 2:
        best_fee, best_income = current_fee_pct, -1.0
        for i in range(8, 41):   # 0.40x to 2.00x its day-one fee, in steps of 0.05x
            fee = p.competitor_fee_pct * i / 20
            if fee < floor - 1e-12:
                continue
            share, cost = route(p, tvl, competitor_fee_pct=fee)
            income = fee * (1 - share) * market_volume(p, cost)
            if income > best_income * (1 + 1e-9):
                best_fee, best_income = fee, income
        return best_fee
    return current_fee_pct


def _poisson(rng, lam):
    limit, k, prod = math.exp(-lam), 0, rng.random()
    while prod > limit:
        k += 1
        prod *= rng.random()
    return k


def run(p: Params):
    """Returns (results, hall). Use `simulate` unless you need the Hall itself."""
    rng = random.Random(p.seed)
    E = p.epochs_per_day
    H = max(1, round(p.horizon_days * E))
    term = round(p.hard_lock_days * E)
    hall = AccHall(p.floor, H, p.u0, p.pol_share_pct / 100)
    per_year = 365 * E
    volatile = p.annual_vol_pct > 0
    sig = p.annual_vol_pct / 100 / math.sqrt(per_year)
    il_drag = (p.annual_vol_pct / 100) ** 2 / 8 * 100   # expected yearly loss to price moves, %
    pol_cut = p.pol_share_pct / 100

    price = 1.0
    index = lambda: math.sqrt(price) if volatile else 1.0      # dollars per share (50/50 pool)

    def price_loss(m):
        """Dollars a position is behind simply holding the two assets it came in with."""
        r = price / m["price_in"]
        return m["size"] * ((1 + r) / 2 - math.sqrt(r))

    meta = {}     # pid -> dict
    done = []     # dict per finished or still-open position
    shares = 0.0  # real shares in the pool; weight boosts live only in the Hall
    out = dict(volume=0.0, lp_fees=0.0, build=0.0, banked=0.0, bank_overflow_to_lps=0.0,
               forfeited_fees=0.0, principal_tolls=0.0, venue_cut=0.0, tolls_to_lockers=0.0)
    offered = {k: 0.0 for k in KINDS}
    accepted = {k: 0.0 for k in KINDS}
    late = [0.0, 0.0]   # long capital offered and accepted in the second half
    pol_cash = prize_pot = pol_seen = 0.0
    seasoned_days, tvl_days, hard_days = [], [], []
    shock = {}   # what the pool looked like at each shock, and who stayed
    toll_events = []     # (epoch, dollars per locked share) for tolls paid to lockers
    locked_shares = 0.0

    def tvl():
        return shares * index()

    def open_position(kind, size, stay, tier="soft"):
        nonlocal shares, locked_shares
        s = size / index()
        pid = hall.deposit(kind, s * (p.hard_boost if tier == "hard" else 1.0))
        meta[pid] = dict(kind=kind, s=s, size=size, e_in=hall.e, tier=tier, price_in=price,
                         e_out=None if stay is None else hall.e + stay, toll_idx=len(toll_events))
        shares += s
        if tier == "hard":
            locked_shares += s

    def toll_credit(m):
        """(paid out so far, still to come) from tolls credited to a locked position."""
        if m["tier"] != "hard" or not p.toll_mode:
            return 0.0, 0.0
        age = hall.e - m["e_in"]
        got = waiting = 0.0
        for when, per_share in toll_events[m["toll_idx"]:]:
            done_frac = min(1.0, ((hall.e - when) if p.toll_mode == 1 else age) / term)
            got += per_share * done_frac
            waiting += per_share * (1 - done_frac)
        return m["s"] * got, m["s"] * waiting

    def pay_lockers(amount):
        if amount <= 0:
            return
        out["tolls_to_lockers"] += amount
        if locked_shares > 0:
            toll_events.append((hall.e, amount / locked_shares))
        else:
            hall.add_fees(amount)   # nobody locked to receive it

    def toll_rate(m, age):
        if m["tier"] == "hard":
            return p.hard_exit_pct / 100 * max(0.0, 1 - age / term)
        return p.principal_floor_pct / 100 * max(0.0, 1 - age / H)

    def close(pid):
        nonlocal shares, pol_cash, locked_shares
        m = meta.pop(pid)
        age = hall.e - m["e_in"]
        value = m["s"] * index()
        cash, forfeited = hall.exit(pid)
        toll = value * toll_rate(m, age)
        got, waiting = toll_credit(m)
        shares -= m["s"]
        if m["tier"] == "hard":
            locked_shares -= m["s"]
        if p.toll_mode and m["tier"] == "hard":
            pay_lockers(toll + waiting)   # the leaver's toll, and the credits they walk away from
        else:
            pol_cash += toll * pol_cut
            hall.add_fees(toll * (1 - pol_cut))
        out["forfeited_fees"] += forfeited
        out["principal_tolls"] += toll
        done.append(dict(m, t=age, fees=cash - toll + got, il=price_loss(m)))

    rival_fee = p.competitor_fee_pct
    rival_fee_days = []

    market_seen = [0.0, 0.0]   # trading in the whole pair, and its cost weighted by that trading

    def organic_volume(depth):
        share, cost = route(p, depth, competitor_fee_pct=rival_fee)
        market = market_volume(p, cost)
        market_seen[0] += market / E
        market_seen[1] += market / E * cost
        return market * share

    def expected_apr(size, T, tier):
        """What a newcomer expects over a stay of T epochs if fees keep their recent pace."""
        if T <= H:
            sum_w = T * p.floor + (1 - p.floor) * (T * (T - 1) / 2) / H
        else:
            sum_w = H * p.floor + (1 - p.floor) * (H - 1) / 2 + (T - H)
        s = size / index() * (p.hard_boost if tier == "hard" else 1.0)
        per_weight = rate / (hall.W + s * sum_w / T)
        kept = s * per_weight * sum_w * ramp(p.u0, T, H)
        toll = 0.0 if tier == "hard" else size * p.principal_floor_pct / 100 * max(0.0, 1 - T / H)
        return (kept - toll) / size * per_year / T * 100

    def run_shock(tag):
        nonlocal price
        if volatile:
            price *= 1 - p.shock_drop_pct / 100
        before = shares
        groups = {g: [0.0, 0.0] for g in ("seasoned", "fresh", "hard", "soft", "hard_mid", "hard_done")}

        def tally(m, col):
            if m["kind"] in KINDS:
                age = hall.e - m["e_in"]
                groups["seasoned" if age >= H else "fresh"][col] += m["s"]
                groups[m["tier"]][col] += m["s"]
                if m["tier"] == "hard":
                    groups["hard_done" if age >= term else "hard_mid"][col] += m["s"]

        for m in meta.values():
            tally(m, 0)
        for pid in [k for k, m in meta.items() if m["kind"] in KINDS]:
            if rng.random() < p.passive_pct / 100:
                continue
            m = meta[pid]
            value = m["s"] * index()
            q = hall.pos[pid]
            locked = q.earned - q.paid - hall.unlocked_now(pid)
            cost = locked + value * toll_rate(m, hall.e - m["e_in"]) + toll_credit(m)[1]
            fear = rng.uniform(0, p.shock_fear_pct) / 100 * value
            if fear > cost + value * p.inertia_pct / 100:
                close(pid)
        for m in meta.values():
            tally(m, 1)
        lp_before = groups["seasoned"][0] + groups["fresh"][0]
        shock[f"{tag}_retained_pct"] = 100 * shares / before
        shock[f"{tag}_seasoned_mix_pct"] = 100 * groups["seasoned"][0] / lp_before if lp_before else float("nan")
        shock[f"{tag}_hard_mix_pct"] = 100 * groups["hard"][0] / lp_before if lp_before else float("nan")
        for g, (was, now) in groups.items():
            shock[f"{tag}_kept_{g}_pct"] = 100 * now / was if was else float("nan")

    open_position("anchor", p.anchor_tvl, None)
    gross0 = organic_volume(tvl()) / E * p.gross_fee_pct / 100
    market_seen[:] = [0.0, 0.0]
    rate = gross0 * (1 - p.venue_cut_pct / 100 * (1 - p.buyback_pct / 200))   # smoothed fees reaching the Hall per epoch
    smooth = 2 / (4 * E + 1)

    for day in range(p.days):
        if (p.competitor_response and day >= p.competitor_delay_days
                and (day - p.competitor_delay_days) % p.competitor_review_days == 0):
            rival_fee = competitor_reply(p, tvl(), rival_fee)
        rival_fee_days.append(rival_fee)
        if day == p.shock_day:
            run_shock("shock")
        if day == p.shock_day2:
            run_shock("shock2")

        # LPs whose planned stay is over leave.
        for pid in [k for k, m in meta.items() if m["e_out"] is not None and m["e_out"] <= hall.e]:
            close(pid)

        # New LPs look at the pool and decide.
        for _ in range(_poisson(rng, p.arrivals_per_day)):
            x = rng.random()
            kind = "hot" if x < p.mix_hot else "medium" if x < p.mix_hot + p.mix_medium else "long"
            size = p.size_median * math.exp(rng.gauss(0, p.size_sigma))
            lo, hi = getattr(p, "hold_" + kind)
            T = max(1, round(rng.uniform(lo, hi) * E))
            hurdle = rng.gauss(p.outside_apr_pct, p.outside_apr_sd) + il_drag
            offered[kind] += size
            second_half = kind == "long" and day >= p.days // 2
            if second_half:
                late[0] += size
            soft = expected_apr(size, T, "soft")
            tier = None
            if term and T >= term and expected_apr(size, T, "hard") >= max(hurdle, soft) + p.lock_premium_pct:
                tier = "hard"
            elif soft >= hurdle:
                tier = "soft"
            if tier:
                accepted[kind] += size
                if second_half:
                    late[1] += size
                open_position(kind, size, T, tier)

        # The venue's POL line, and its share of forfeits and tolls, go in as liquidity.
        pol_cash += hall.pol - pol_seen
        pol_seen = hall.pol
        if pol_cash > 0:
            open_position("pol", pol_cash, None)
            pol_cash = 0.0

        for _ in range(E):
            arb = 0.0
            if volatile:
                step = sig * rng.gauss(0, 1) - sig * sig / 2
                price *= math.exp(step)
                # Trading needed to move a 50/50 pool to the new price. Moves smaller
                # than the fee are not worth arbitraging.
                arb = max(0.0, abs(step) - p.gross_fee_pct / 100) * tvl() / 4
            noise = math.exp(rng.gauss(0, p.volume_sigma) - p.volume_sigma ** 2 / 2)
            volume = organic_volume(tvl()) / E * noise + arb
            gross = volume * p.gross_fee_pct / 100
            venue = gross * p.venue_cut_pct / 100
            buyback = venue * p.buyback_pct / 100
            to_bank = min(buyback / 2, max(0.0, p.holding_cap - out["banked"]))
            to_hall = gross - venue + buyback - to_bank
            hall.add_fees(to_hall)
            hall.add_bank(to_bank)
            out["volume"] += volume
            out["venue_cut"] += venue
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

        tvl_days.append(tvl())
        hard_days.append(sum(m["s"] for m in meta.values() if m["tier"] == "hard") / shares)
        if hall.e >= H:
            seasoned_days.append(sum(m["s"] for m in meta.values() if hall.e - m["e_in"] >= H) / shares)

    hall.settle_all()
    for pid, m in meta.items():
        # Still in at the end: count what they have earned, on the view that they stay to unlock it.
        done.append(dict(m, t=hall.e - m["e_in"], fees=hall.pos[pid].earned + sum(toll_credit(m)),
                         il=price_loss(m)))

    def apr(rows, net):
        dollar_epochs = sum(r["size"] * r["t"] for r in rows)
        got = sum(r["fees"] - (r["il"] if net else 0.0) for r in rows)
        return got / dollar_epochs * per_year * 100 if dollar_epochs else float("nan")

    for kind in KINDS + ("anchor",):
        rows = [r for r in done if r["kind"] == kind]
        out["apr_" + kind] = apr(rows, False)
        out["net_apr_" + kind] = apr(rows, True)
    pol = [r for r in done if r["kind"] == "pol"]
    out["pol_income"] = sum(r["fees"] for r in pol)
    out["pol_value"] = sum(r["s"] for r in pol) * index()
    for kind in KINDS:
        out["accepted_" + kind + "_pct"] = 100 * accepted[kind] / offered[kind] if offered[kind] else float("nan")
    out["accepted_long_late_pct"] = 100 * late[1] / late[0] if late[0] else float("nan")
    out["tvl_end"] = tvl()
    out["tvl_avg"] = sum(tvl_days) / len(tvl_days)
    out["seasoned_share_pct"] = 100 * sum(seasoned_days) / len(seasoned_days) if seasoned_days else float("nan")
    out["hard_share_pct"] = 100 * sum(hard_days) / len(hard_days)
    for tag in ("shock", "shock2"):
        for k in ("retained", "seasoned_mix", "hard_mix", "kept_seasoned", "kept_fresh", "kept_hard", "kept_soft",
                  "kept_hard_mid", "kept_hard_done"):
            out[f"{tag}_{k}_pct"] = shock.get(f"{tag}_{k}_pct", float("nan"))
    out["venue_total"] = out["build"] + out["pol_income"] + out["pol_value"]
    out["market_share_pct"] = 100 * out["volume"] / market_seen[0]
    out["market_volume"] = market_seen[0]
    out["market_growth_pct"] = 100 * (market_seen[0] / (p.market_daily_volume * p.days) - 1)
    out["trading_cost_pct"] = 100 * market_seen[1] / market_seen[0]
    out["rival_fee_end"] = rival_fee
    out["rival_fee_avg"] = sum(rival_fee_days) / len(rival_fee_days)

    # Growth-trap probe: over one horizon starting mid-run, what does a brand-new
    # dollar earn compared with a fully seasoned one?
    e1 = (p.days // 2) * E
    e2 = min(e1 + H, hall.e)
    mature = hall.cp[e2][0] - hall.cp[e1][0]
    out["new_vs_mature_pct"] = 100 * hall.span(1.0, e1, e1, e2, 0, 1) / mature if mature else float("nan")
    return out, hall


def simulate(p: Params):
    return run(p)[0]


def average(p: Params, seeds, errors=None):
    """Mean of each result over `seeds` runs. If `errors` is a dict it is filled
    with the standard error of each mean."""
    runs = [simulate(p.but(seed=p.seed + s)) for s in range(seeds)]
    out = {}
    for k in runs[0]:
        vals = [r[k] for r in runs if r[k] == r[k]]
        out[k] = sum(vals) / len(vals) if vals else float("nan")
        if errors is not None and len(vals) > 1:
            var = sum((v - out[k]) ** 2 for v in vals) / (len(vals) - 1)
            errors[k] = math.sqrt(var / len(vals))
    return out

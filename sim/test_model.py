"""Sanity checks on the scenario model.  Run:  python3 -m unittest sim.test_model"""

import math
import unittest

from .model import Params, SCENARIOS, competitor_reply, market_volume, our_reply, our_share, route, run


class ModelChecks(unittest.TestCase):
    def test_every_scenario_accounts_for_every_fee(self):
        for name, changes in SCENARIOS.items():
            out, hall = run(Params(days=120, seed=3).but(**changes))
            paid_or_held = sum(hall.payout.values()) + hall.held() + hall.pol + hall.pending_fee
            self.assertTrue(math.isclose(paid_or_held, hall.fees_in, rel_tol=1e-9), name)
            self.assertTrue(math.isclose(sum(hall.claimw.values()), out["banked"], rel_tol=1e-9), name)

    def test_plain_pool_forfeits_nothing_and_pays_new_money_in_full(self):
        out, _ = run(Params(days=120, shock_day=60).plain())
        self.assertEqual(out["forfeited_fees"], 0)
        self.assertEqual(out["principal_tolls"], 0)
        self.assertAlmostEqual(out["new_vs_mature_pct"], 100)

    def test_traders_follow_fee_and_depth(self):
        p = Params()
        # Same fee: flow splits by depth.
        self.assertAlmostEqual(our_share(p, 10_000_000), 0.5)
        self.assertAlmostEqual(our_share(p, 5_000_000), 1 / 3)
        # A higher fee loses flow, a lower fee wins it, and more depth always helps.
        shares = [our_share(p.but(gross_fee_pct=f), 5_000_000) for f in (0.03, 0.05, 0.07, 0.2)]
        self.assertEqual(shares, sorted(shares, reverse=True))
        self.assertGreater(shares[0], 1 / 3)
        self.assertLess(shares[2], 1 / 3)
        self.assertLess(our_share(p.but(gross_fee_pct=0.07), 5_000_000),
                        our_share(p.but(gross_fee_pct=0.07), 8_000_000))
        # A volatile pair has more price impact, so the same fee gap moves less flow.
        v = p.but(depth_multiplier=1, competitor_fee_pct=0.30)
        stable_loss = 1 / 3 - shares[2]
        volatile_loss = 1 / 3 - our_share(v.but(gross_fee_pct=0.42), 5_000_000)
        self.assertLess(volatile_loss, stable_loss)

    def test_tolls_paid_to_lockers_reach_nobody_else(self):
        base = Params(days=200, seed=5).but(**SCENARIOS["twoshock"]).but(days=200, hard_boost=1.5)
        for mode in (1, 2):
            out, hall = run(base.but(toll_mode=mode))
            self.assertGreater(out["principal_tolls"], 0)
            # Every toll went to lockers (plus re-paid credits that leavers walked away from).
            self.assertGreaterEqual(out["tolls_to_lockers"], out["principal_tolls"] - 1e-6)
            # POL received only its fee line and its share of forfeited fees: no toll money.
            split, _ = run(base.but(toll_mode=0))
            self.assertLess(out["pol_value"], split["pol_value"])

    def test_trading_responds_to_cost(self):
        p = Params()
        alone = route(p, 0.0)[1]
        self.assertAlmostEqual(market_volume(p, alone), p.market_daily_volume)
        # Our depth makes trading cheaper, so there is more of it.
        with_us = route(p, 5_000_000)[1]
        self.assertLess(with_us, alone)
        self.assertGreater(market_volume(p, with_us), p.market_daily_volume)
        # Dearer trading means less of it, and more so the more elastic demand is.
        dear = route(p.but(gross_fee_pct=0.2, competitor_fee_pct=0.2), 5_000_000)[1]
        self.assertLess(market_volume(p, dear), market_volume(p, with_us))
        self.assertLess(market_volume(p.but(demand_elasticity=2), dear), market_volume(p, dear))
        self.assertEqual(market_volume(p.but(demand_elasticity=0), dear), p.market_daily_volume)

    def test_lps_price_the_lock(self):
        base = Params(days=150, seed=2).but(**SCENARIOS["hardlock"]).but(hard_boost=1.5)
        take = lambda **kw: run(base.but(**kw))[0]["lock_take_pct"]
        # A dearer exit, a smaller boost, more need for cash or more dislike of risk: fewer take the lock.
        self.assertLess(take(hard_exit_pct=20), take(hard_exit_pct=2))
        self.assertLess(take(hard_boost=1.05), take(hard_boost=2.0))
        self.assertLess(take(liquidity_need_per_year=2.0), take(liquidity_need_per_year=0.1))
        self.assertLess(take(lock_aversion=4.0), take(lock_aversion=0.5))
        # With nobody ever needing cash, the lock costs an LP nothing and tolls only arise in the shock.
        calm = run(base.but(liquidity_need_per_year=0, shock_day=-1))[0]
        self.assertEqual(calm["principal_tolls"], 0)
        # With needs, some locked LPs pay to leave even in calm times.
        needy = run(base.but(shock_day=-1))[0]
        self.assertGreater(needy["principal_tolls"], 0)

    def test_no_boost_needs_another_reason_to_lock(self):
        base = Params(seed=1).but(**SCENARIOS["twoshock"]).but(hard_exit_pct=10, lock_melt_floor=1.0)
        self.assertEqual(base.hard_boost, 1.0)
        self.assertEqual(run(base)[0]["lock_take_pct"], 0)                      # nothing to gain
        self.assertEqual(run(base.but(toll_mode=1))[0]["lock_take_pct"], 0)     # no lockers, so no tolls to share
        self.assertGreater(run(base.but(hard_skips_ramp=1))[0]["lock_take_pct"], 0)
        paid = run(base.but(lock_budget_pct=30))[0]
        self.assertGreater(paid["lock_take_pct"], 0)
        self.assertGreater(paid["lock_budget_paid"], 0)

    def test_rolling_and_non_melting_locks(self):
        base = Params(seed=4).but(**SCENARIOS["twoshock"]).but(hard_boost=1.25, hard_exit_pct=10)
        plain = run(base)[0]
        rolling = run(base.but(lock_rolls=1))[0]
        flat = run(base.but(lock_melt_floor=1.0))[0]
        # Rolling leaves less locked capital free to walk at the second shock.
        self.assertLess(rolling["shock2_free_mix_pct"], plain["shock2_free_mix_pct"])
        # A lock that costs more to leave is taken by fewer LPs.
        self.assertLessEqual(flat["lock_take_pct"], plain["lock_take_pct"])
        self.assertLessEqual(rolling["lock_take_pct"], plain["lock_take_pct"])
        # melt floor 0 with no rolling is the old behaviour: same run, same result.
        self.assertEqual(repr(run(base.but(lock_melt_floor=0.0, lock_rolls=0))[0]), repr(plain))

    def test_recent_arrivals_can_count_for_less(self):
        full, _ = run(Params(days=90))
        self.assertAlmostEqual(full["reliable_tvl_avg"], full["tvl_avg"])
        half, _ = run(Params(days=90, fresh_depth_value=0.5))
        self.assertLess(half["reliable_tvl_avg"], half["tvl_avg"])
        # A plain pool lets hot money in, so discounting it costs the plain pool more flow.
        loss = lambda p: 1 - run(p.but(fresh_depth_value=0.5))[0]["volume"] / run(p)[0]["volume"]
        self.assertGreater(loss(Params(days=90).plain()), loss(Params(days=90)))

    def test_competitor_depth_follows_its_yield(self):
        fixed, _ = run(Params(days=120))
        self.assertEqual(fixed["rival_tvl_end"], Params().competitor_tvl)
        # We take flow from it, so its LPs earn less than before and some leave.
        moving, _ = run(Params(days=120, competitor_depth_speed=2.0))
        self.assertLess(moving["rival_tvl_end"], Params().competitor_tvl)
        self.assertGreater(moving["market_share_pct"], fixed["market_share_pct"])
        # If we price ourselves out, it keeps its flow and nearly all its depth.
        priced_out, _ = run(Params(days=120, competitor_depth_speed=2.0, gross_fee_pct=0.2))
        self.assertGreater(priced_out["rival_tvl_end"], 0.97 * Params().competitor_tvl)

    def test_our_fee_moves_only_inside_its_bounds_and_timelocks(self):
        p = Params(our_response=1)
        self.assertAlmostEqual(our_reply(p, 0.05, 5e6, 0.035, 1e7), 0.035)   # follows down
        self.assertAlmostEqual(our_reply(p, 0.05, 5e6, 0.001, 1e7), 0.02)    # floor
        self.assertAlmostEqual(our_reply(p, 0.05, 5e6, 0.09, 1e7), 0.05)     # cap
        best = our_reply(p.but(our_response=2), 0.05, 5e6, 0.035, 1e7)
        self.assertTrue(0.02 - 1e-12 <= best <= 0.05 + 1e-12)
        # Fixed fee: nothing changes. Following a competitor that undercuts: it does.
        still, _ = run(Params(days=90, competitor_response=2))
        self.assertEqual((still["our_fee_end"], still["our_fee_changes"]), (0.05, 0))
        moved, _ = run(Params(days=90, competitor_response=2, our_response=1))
        self.assertLess(moved["our_fee_end"], 0.05)
        self.assertGreaterEqual(moved["our_fee_end"], 0.02 - 1e-12)
        # A slower timelock on decreases means fewer changes get through.
        slow, _ = run(Params(days=90, competitor_response=2, our_response=1, fee_down_delay_days=28))
        self.assertLessEqual(slow["our_fee_changes"], moved["our_fee_changes"])

    def test_competitor_replies(self):
        p = Params(gross_fee_pct=0.04)
        self.assertEqual(competitor_reply(p, 5e6, 0.05), 0.05)                              # static
        self.assertEqual(competitor_reply(p.but(competitor_response=1), 5e6, 0.05), 0.04)   # matches down
        self.assertEqual(competitor_reply(p.but(competitor_response=1, gross_fee_pct=0.07), 5e6, 0.05), 0.05)
        self.assertAlmostEqual(competitor_reply(p.but(competitor_response=1, gross_fee_pct=0.01), 5e6, 0.05), 0.02)  # floor
        best = competitor_reply(p.but(competitor_response=2), 5e6, 0.05)
        def income(fee):
            share, cost = route(p, 5e6, competitor_fee_pct=fee)
            return fee * (1 - share) * market_volume(p, cost)
        self.assertGreaterEqual(income(best), income(0.05))
        self.assertGreaterEqual(best, 0.02 - 1e-12)
        # In a full run the matching competitor ends on our fee.
        out, _ = run(Params(days=60, gross_fee_pct=0.04, competitor_response=1))
        self.assertAlmostEqual(out["rival_fee_end"], 0.04)

    def test_same_seed_same_result(self):
        p = Params(days=60, seed=7).but(**SCENARIOS["hardlock"]).but(shock_day=30)
        self.assertEqual(repr(run(p)[0]), repr(run(p)[0]))   # repr, because nan != nan

    def test_banked_half_stops_at_the_holding_cap(self):
        out, _ = run(Params(days=120, holding_cap=1_000))
        self.assertAlmostEqual(out["banked"], 1_000)
        self.assertGreater(out["bank_overflow_to_lps"], 0)


class SearchChecks(unittest.TestCase):
    def test_designs_stay_inside_the_space_and_tidy_up(self):
        import random
        from .search import SPACE, frontier, mutate, random_design, tidy
        rng = random.Random(0)
        for _ in range(200):
            d = mutate(rng, random_design(rng))
            self.assertTrue(all(d[k] in SPACE[k] for k in SPACE))
            self.assertNotIn("hard_boost", d)                       # the boost is ruled out
            if not d["hard_lock_days"]:
                self.assertEqual((d["toll_mode"], d["hard_skips_ramp"], d["lock_budget_pct"]), (0, 0, 0))
        rows = [dict(revenue_x=2.0, kept_points=1.0), dict(revenue_x=1.0, kept_points=5.0),
                dict(revenue_x=1.5, kept_points=0.5), dict(revenue_x=0.9, kept_points=4.0)]
        self.assertEqual([r["revenue_x"] for r in frontier(rows)], [2.0, 1.0])


if __name__ == "__main__":
    unittest.main()

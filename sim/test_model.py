"""Sanity checks on the scenario model.  Run:  python3 -m unittest sim.test_model"""

import math
import unittest

from .model import Params, SCENARIOS, competitor_reply, market_volume, our_share, route, run


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
        base = Params(days=200, seed=5).but(**SCENARIOS["twoshock"]).but(days=200)
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


if __name__ == "__main__":
    unittest.main()

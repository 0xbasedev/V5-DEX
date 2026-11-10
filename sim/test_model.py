"""Sanity checks on the scenario model.  Run:  python3 -m unittest sim.test_model"""

import math
import unittest

from .model import Params, SCENARIOS, our_share, run


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

    def test_same_seed_same_result(self):
        p = Params(days=60, seed=7).but(**SCENARIOS["hardlock"]).but(shock_day=30)
        self.assertEqual(repr(run(p)[0]), repr(run(p)[0]))   # repr, because nan != nan

    def test_banked_half_stops_at_the_holding_cap(self):
        out, _ = run(Params(days=120, holding_cap=1_000))
        self.assertAlmostEqual(out["banked"], 1_000)
        self.assertGreater(out["bank_overflow_to_lps"], 0)


if __name__ == "__main__":
    unittest.main()

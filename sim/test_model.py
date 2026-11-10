"""Sanity checks on the scenario model.  Run:  python3 -m unittest sim.test_model"""

import math
import unittest

from .model import Params, SCENARIOS, run


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

    def test_same_seed_same_result(self):
        p = Params(days=60, seed=7).but(**SCENARIOS["hardlock"]).but(shock_day=30)
        self.assertEqual(repr(run(p)[0]), repr(run(p)[0]))   # repr, because nan != nan

    def test_banked_half_stops_at_the_holding_cap(self):
        out, _ = run(Params(days=120, holding_cap=1_000))
        self.assertAlmostEqual(out["banked"], 1_000)
        self.assertGreater(out["bank_overflow_to_lps"], 0)


if __name__ == "__main__":
    unittest.main()

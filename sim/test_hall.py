"""First test of the simulator (spec v1.16, O5): the constant-time claim maths
must equal a brute-force calculation for every position, exactly.

Run:  python3 -m unittest sim.test_hall -v
"""

import math
import random
import unittest
from fractions import Fraction as Fr

from .hall import AccHall, BruteHall


class Pair:
    """Drives both halls with the same operations and insists they agree."""

    def __init__(self, floor, horizon, u0, pol_share):
        self.acc = AccHall(floor, horizon, u0, pol_share)
        self.brute = BruteHall(floor, horizon, u0, pol_share)

    def __getattr__(self, name):
        def call(*args):
            ra, rb = getattr(self.acc, name)(*args), getattr(self.brute, name)(*args)
            assert ra == rb, (name, args, ra, rb)
            return ra
        return call

    def epoch(self, fees=0, bank=0):
        self.add_fees(Fr(fees))
        self.add_bank(Fr(bank))
        assert self.acc.W == self.brute.W, ("total weight", self.acc.e)
        self.end_epoch()

    def check(self):
        a, b = self.acc, self.brute
        a.settle_all()
        assert sorted(a.pos) == sorted(b.pos)
        for pid in a.pos:
            pa, pb = a.pos[pid], b.pos[pid]
            assert (pa.s, pa.earned, pa.paid, pa.owner) == (pb.s, pb.earned, pb.paid, pb.owner), pid
        clean = lambda d: {k: v for k, v in d.items() if v}
        assert clean(a.claimw) == clean(b.claimw), "claims"
        assert a.payout == b.payout and a.pol == b.pol, "payouts"
        # No double counting: claims add up to exactly what was banked.
        assert sum(a.claimw.values()) == a.bank_recorded
        # Every unit of fees is somewhere: paid, held, compounded, in POL, or waiting.
        assert sum(a.payout.values()) + a.held() + a.compounded + a.pol + a.pending_fee == a.fees_in


def half():
    return Pair(Fr(1, 2), 4, Fr(1, 2), Fr(1, 4))


class RandomRuns(unittest.TestCase):
    def test_random_operation_sequences_match_exactly(self):
        seen = set()
        for seed in range(120):
            rng = random.Random(seed)
            horizon = rng.randint(1, 10)
            h = Pair(Fr(rng.randint(0, 9), 10), horizon, Fr(rng.randint(0, 10), 10), Fr(rng.randint(0, 10), 10))
            wallets = ["a", "b", "c", "wrapper"]
            for _ in range(36):
                for _ in range(rng.randint(0, 4)):
                    ids = sorted(h.acc.pos)
                    op = rng.choice(["deposit", "deposit", "claim", "compound", "exit", "transfer", "merge"])
                    if op == "deposit":
                        h.deposit(rng.choice(wallets), Fr(rng.randint(1, 1000)))
                    elif not ids:
                        continue
                    elif op == "transfer":
                        h.transfer(rng.choice(ids), rng.choice(wallets))
                    elif op == "merge":
                        ripe = [i for i in ids if h.acc.age(h.acc.pos[i]) >= horizon]
                        pairs = [(i, j) for i in ripe for j in ripe
                                 if i < j and h.acc.pos[i].owner == h.acc.pos[j].owner]
                        if not pairs:
                            continue
                        h.merge(*rng.choice(pairs))
                    elif op == "compound":
                        pid = rng.choice(ids)
                        # Whole units only, as a contract would; the rest stays unlocked.
                        h.compound(pid, Fr(math.floor(h.unlocked_now(pid))))
                    else:
                        getattr(h, op)(rng.choice(ids))
                    seen.add(op)
                h.epoch(rng.randint(0, 500), rng.randint(0, 500))
            # A refund after a partial draw: only 37% of what was banked comes back.
            part = h.acc.bank_recorded * Fr(37, 100)
            paid = h.refund(part)
            self.assertEqual(sum(paid.values()), part if paid else 0)
            h.check()
        self.assertEqual(seen, {"deposit", "claim", "compound", "exit", "transfer", "merge"})


class NamedCases(unittest.TestCase):
    def test_horizon_crossing_is_exact(self):
        h = half()
        h.deposit("a", Fr(100))
        for _ in range(7):   # horizon is 4, so this crosses it
            h.epoch(60, 20)
        h.deposit("b", Fr(300))
        for _ in range(7):
            h.epoch(60, 20)
        h.check()

    def test_late_deposit_before_sunset_gets_only_its_epochs(self):
        h = half()
        h.deposit("early", Fr(100))
        for _ in range(20):
            h.epoch(0, 100)
        h.deposit("late", Fr(100_000))   # arrives one epoch before the refund
        h.epoch(0, 100)
        paid = h.refund(Fr(2100))
        h.check()
        # 20 epochs alone, then a 1/501 share of the last one (100 vs 100000 * 0.5).
        self.assertEqual(paid["early"], 2000 + Fr(100) * 100 / (100 + 50_000))
        self.assertLess(paid["late"], 100)

    def test_transfer_mid_epoch(self):
        """The receiver owns the position when the epoch closes, so the receiver
        gets that whole epoch. The sender keeps every epoch before it."""
        h = half()
        pid = h.deposit("sender", Fr(100))
        for _ in range(3):
            h.epoch(10, 50)
        h.transfer(pid, "receiver")
        for _ in range(2):
            h.epoch(10, 50)
        h.check()
        self.assertEqual(h.acc.claimw["sender"], 150)
        self.assertEqual(h.acc.claimw["receiver"], 100)

    def test_transfer_inside_the_horizon_keeps_age_and_held_fees(self):
        moved, twin = half(), half()
        pid = moved.deposit("sender", Fr(100))
        twin.deposit("sender", Fr(100))
        for h in (moved, twin):
            h.deposit("other", Fr(400))
        for _ in range(2):
            moved.epoch(80, 40)
            twin.epoch(80, 40)
        moved.transfer(pid, "receiver")   # age 2 of 4
        for _ in range(5):
            moved.epoch(80, 40)
            twin.epoch(80, 40)
        moved.check()
        twin.check()
        a, b = moved.acc.pos[pid], twin.acc.pos[0]
        self.assertEqual((a.earned, a.e0), (b.earned, b.e0))   # the position itself is unchanged
        self.assertEqual(moved.acc.claimw["sender"] + moved.acc.claimw["receiver"], twin.acc.claimw["sender"])

    def test_transfer_then_exit_by_new_owner(self):
        """Held fees travel with the position, so the new owner's early exit
        forfeits them. The sender's deferred claim is untouched."""
        h = half()
        pid = h.deposit("sender", Fr(100))
        h.deposit("other", Fr(100))
        h.epoch(40, 40)
        h.transfer(pid, "receiver")
        h.epoch(40, 40)
        sender_claim_before = None
        h.acc.settle_all()
        sender_claim_before = h.acc.claimw["sender"]
        cash, forfeited = h.exit(pid)     # age 2 of 4: still seasoning
        self.assertGreater(forfeited, 0)
        self.assertEqual(h.acc.payout.get("sender", 0), 0)
        self.assertEqual(h.acc.payout["receiver"], cash)
        for _ in range(3):
            h.epoch(40, 40)
        h.check()
        self.assertEqual(h.acc.claimw["sender"], sender_claim_before)

    def test_transfer_into_a_wrapper_contract(self):
        """A wrapper is just another owner. Each sender keeps what accrued before
        handing over; the wrapper accrues from then on, for all it holds."""
        h = half()
        p1 = h.deposit("alice", Fr(100))
        p2 = h.deposit("bob", Fr(300))
        for _ in range(2):
            h.epoch(0, 80)
        h.transfer(p1, "wrapper")
        h.epoch(0, 80)
        h.transfer(p2, "wrapper")
        for _ in range(4):
            h.epoch(0, 80)
        h.check()
        c = h.acc.claimw
        self.assertEqual(c["alice"], 2 * 20)          # a quarter of two epochs
        self.assertEqual(c["bob"], 3 * 60)            # three quarters of three epochs
        self.assertEqual(c["wrapper"], 7 * 80 - 40 - 180)

    def test_merge_of_two_mature_positions(self):
        h = half()
        a = h.deposit("a", Fr(100))
        b = h.deposit("a", Fr(50))
        h.deposit("c", Fr(70))
        for _ in range(6):
            h.epoch(30, 30)
        h.merge(a, b)
        for _ in range(3):
            h.epoch(30, 30)
        h.check()

    def test_early_exit_forfeit_goes_to_pol_and_seasoned_weight(self):
        h = half()
        stay = h.deposit("stay", Fr(100))
        go = h.deposit("go", Fr(100))
        h.epoch(80)
        cash, forfeited = h.exit(go)      # age 1 of 4: 5/8 unlocked
        self.assertEqual((cash, forfeited), (25, 15))
        self.assertEqual(h.acc.pol, Fr(15, 4))
        h.epoch(0)
        h.check()
        self.assertEqual(h.acc.pos[stay].earned, 40 + Fr(45, 4))


if __name__ == "__main__":
    unittest.main()

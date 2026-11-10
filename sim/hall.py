"""The Epoch Hall's bookkeeping (spec v1.16 §18.3, §18.8, §18.9).

Two implementations of the same rules:

  AccHall    what a contract would do: a running total weight moved by scheduled
             slope changes, two accumulators per stream, O(1) settlement.
  BruteHall  loops over every position every epoch. Slow and obviously right.

`test_hall.py` runs both on the same operations with exact fractions and requires
equality. `model.py` runs AccHall with floats.

Interpretations made where the spec leaves room (flagged, not rulings):
  * Age is counted in whole epochs. A position crosses the horizon at an epoch
    boundary, never partway through.
  * Operations land at the start of an epoch. Whoever owns a position when the
    epoch closes earns that epoch's fees and deferred-claim weight, so a
    "mid-epoch" transfer hands the whole current epoch to the receiver.
  * weight(age)   = floor + (1 - floor) * min(age, H) / H
  * unlocked(age) = (u0 + (1 - u0) * min(age, H) / H) of the fees the position has
    earned so far, less what was already paid or compounded.
  * One unit of fees buys one unit of shares when compounding.
  * The non-POL part of a forfeit joins the fees of the epoch the exit happens in.
  * Held fees travel with a transferred position; deferred claims stay with the
    wallet that earned them.
"""


def ramp(start, age, horizon):
    """Linear from `start` at age 0 to 1 at the horizon, flat after."""
    return start + (1 - start) * min(age, horizon) / horizon


class Pos:
    __slots__ = ("owner", "s", "e0", "last", "earned", "paid")

    def __init__(self, owner, shares, e0, now):
        self.owner, self.s, self.e0 = owner, shares, e0
        self.last = now   # earnings are settled for all epochs before this
        self.earned = 0   # fees earned over the position's life
        self.paid = 0     # fees already paid out or compounded


class _Common:
    """State and rules shared by both halls. Only the weight and earnings
    bookkeeping differs."""

    def __init__(self, floor, horizon, u0, pol_share):
        self.f, self.H, self.u0, self.pol_share = floor, horizon, u0, pol_share
        self.e = 0
        self.pos = {}
        self.next_id = 0
        self.pending_fee = 0    # arrives during the current epoch
        self.pending_bank = 0
        self.payout = {}        # wallet -> fees paid in cash
        self.claimw = {}        # wallet -> deferred-claim weight, in banked units
        self.pol = 0            # POL share of forfeits
        self.compounded = 0
        self.fees_in = 0
        self.bank_recorded = 0  # banked amounts actually attributed to weight

    def age(self, p):
        return self.e - p.e0

    def w(self, p):
        return p.s * ramp(self.f, self.age(p), self.H)

    def unlocked(self, p):
        return p.earned * ramp(self.u0, self.age(p), self.H) - p.paid

    def _credit(self, table, who, x):
        table[who] = table.get(who, 0) + x

    def _new(self, pos):
        pid = self.next_id
        self.next_id += 1
        self.pos[pid] = pos
        self._weight(pos, +1)
        return pid

    # --- operations, all applied at the start of the current epoch ---
    def add_fees(self, x):
        self.pending_fee += x
        self.fees_in += x

    def add_bank(self, x):
        self.pending_bank += x

    def deposit(self, owner, shares):
        return self._new(Pos(owner, shares, self.e, self.e))

    def unlocked_now(self, pid):
        p = self.pos[pid]
        self._settle(p)
        return self.unlocked(p)

    def claim(self, pid):
        p = self.pos[pid]
        self._settle(p)
        x = self.unlocked(p)
        p.paid += x
        self._credit(self.payout, p.owner, x)
        return x

    def compound(self, pid, amount=None):
        """Compound unlocked fees at the position's current age. `amount` caps it."""
        p = self.pos[pid]
        self._settle(p)
        x = self.unlocked(p)
        if amount is not None:
            x = min(x, amount)
        p.paid += x
        self.compounded += x
        self._weight(p, -1)
        p.s += x
        self._weight(p, +1)
        return x

    def exit(self, pid):
        """Returns (cash paid, fees forfeited). Principal is the caller's business."""
        p = self.pos[pid]
        self._settle(p)
        x = self.unlocked(p)
        p.paid += x
        self._credit(self.payout, p.owner, x)
        locked = p.earned - p.paid
        self.pol += locked * self.pol_share
        self.pending_fee += locked * (1 - self.pol_share)
        self._weight(p, -1)
        del self.pos[pid]
        return x, locked

    def transfer(self, pid, new_owner):
        p = self.pos[pid]
        self._settle(p)       # accrued claim weight stays with the sender
        p.owner = new_owner   # age and held fees travel with the position

    def merge(self, a, b):
        pa, pb = self.pos[a], self.pos[b]
        assert pa.owner == pb.owner, "merge needs one owner"
        assert self.age(pa) >= self.H and self.age(pb) >= self.H, "only mature positions merge"
        self._settle(pa)
        self._settle(pb)
        self._weight(pa, -1)
        self._weight(pb, -1)
        m = Pos(pa.owner, pa.s + pb.s, self.e - self.H, self.e)
        m.earned, m.paid = pa.earned + pb.earned, pa.paid + pb.paid
        del self.pos[a], self.pos[b]
        return self._new(m)

    def settle_all(self):
        for p in self.pos.values():
            self._settle(p)

    def refund(self, amount):
        """Split refund USDC by recorded claim weights. Returns wallet -> USDC."""
        self.settle_all()
        total = self.bank_recorded
        if not total:
            return {}
        return {k: amount * v / total for k, v in self.claimw.items() if v}

    def held(self):
        return sum(p.earned - p.paid for p in self.pos.values())


class AccHall(_Common):
    """Constant-time bookkeeping."""

    def __init__(self, *a):
        super().__init__(*a)
        self.W = 0
        self.slope = 0
        self.slope_changes = {}
        self.cp = [(0, 0, 0, 0)]  # accumulators as they stood before epoch i

    def _weight(self, p, sign):
        self.W += sign * self.w(p)
        mature_at = p.e0 + self.H
        if self.e < mature_at:
            d = sign * p.s * (1 - self.f) / self.H
            self.slope += d
            self.slope_changes[mature_at] = self.slope_changes.get(mature_at, 0) - d

    def span(self, s, e0, a, b, ia, ib):
        """What `s` shares that started at epoch e0 earn over epochs [a, b),
        from the accumulator pair (ia, ib)."""
        if b <= a:
            return 0
        m = e0 + self.H
        total = 0
        x = min(b, m)
        if x > a:   # still ramping
            alpha = s * (self.f - (1 - self.f) * e0 / self.H)
            beta = s * (1 - self.f) / self.H
            total += alpha * (self.cp[x][ia] - self.cp[a][ia]) + beta * (self.cp[x][ib] - self.cp[a][ib])
        y = max(a, m)
        if b > y:   # mature
            total += s * (self.cp[b][ia] - self.cp[y][ia])
        return total

    def _settle(self, p):
        if p.last == self.e:
            return
        p.earned += self.span(p.s, p.e0, p.last, self.e, 0, 1)
        self._credit(self.claimw, p.owner, self.span(p.s, p.e0, p.last, self.e, 2, 3))
        p.last = self.e

    def end_epoch(self):
        A, B, A2, B2 = self.cp[-1]
        if self.W > 0:
            A += self.pending_fee / self.W
            B += self.e * self.pending_fee / self.W
            A2 += self.pending_bank / self.W
            B2 += self.e * self.pending_bank / self.W
            self.bank_recorded += self.pending_bank
            self.pending_fee = self.pending_bank = 0
        self.cp.append((A, B, A2, B2))
        self.W += self.slope
        self.e += 1
        self.slope += self.slope_changes.pop(self.e, 0)


class BruteHall(_Common):
    """Per-position, per-epoch bookkeeping."""

    def _weight(self, p, sign):
        pass

    def _settle(self, p):
        pass  # already credited every epoch

    @property
    def W(self):
        return sum(self.w(p) for p in self.pos.values())

    def end_epoch(self):
        total = self.W
        if total > 0:
            for p in self.pos.values():
                share = self.w(p) / total
                p.earned += self.pending_fee * share
                self._credit(self.claimw, p.owner, self.pending_bank * share)
            self.bank_recorded += self.pending_bank
            self.pending_fee = self.pending_bank = 0
        self.e += 1

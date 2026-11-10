# Review — handoff prompt v13 (The Machine)

Reviewed 2026-11-10. Companion file: `Exchange_prompt_v14-proposed.md` (the brief rewritten with every change below applied).

**What I reviewed.** The v12 and v13 briefs only. v13 differs from v12 by one paragraph (the developer platform). I have not seen spec v1.13, so some points may already be answered there. Everything I changed is a PROPOSAL awaiting your ruling; I have not overridden any LOCK silently — the two LOCKs I think should be reopened are called out as such.

**One fact check.** A contract does exist at `0x8366a39C…0951` on chain 5042, deployed through the standard deterministic deployer. Its creation timestamp is 2026-05-27, about four months before the brief's "mainnet live since 2026-09-16". I did not confirm it is a PoolManager. Worth reconciling the date in the spec.

---

## Verdict

V5 (seasoned liquidity paid from real fees) is a real, differentiated idea and the engineering is tractable — more tractable than the brief implies (see C1). The viability problems are around it:

- The programme is five to ten products, not one.
- As written the venue earns roughly nothing at launch.
- Several rules made under earlier premises now contradict later rulings.
- There are 13 versions of the brief and no code. The open parameters cannot be settled by deliberation; they need a simulator.

---

## A. Things that break as written

**A1. Free Bonfire + "equal per attendee" is a sybil farm.** R8 was ruled when entry was paid, which made equal splits safe. With free entry, one person with 1,000 wallets takes 1,000 shares. The deferred sub-choice is no longer open: prizes must be weighted by something costly to fake (seasoned weight). *Changed in v14.*

**A2. The Burn Vault cannot be both one-way and the pre-token bank.** Pre-token it holds USDC and fee tokens, which must leave to buy the token — that is an exit, it needs the token address set by someone (an admin role), and it needs swap logic exposed to MEV. And if the token never launches, the money is locked forever. *Fix:* split it. A **Buyback Engine** holds stables and streams buys; the **Burn Vault** only ever holds the token and only burns. The engine carries a dated sunset: no token by the deadline, banked funds go to LPs through the hall, never to the team. This requires amending LOCK §5b.

**A3. The panic-exit slash is priced on something that is zero.** A proportional exit from a weighted or stable pool has no price impact; it reduces depth, it does not move price. So "price impact plus fees earned before maturity" collapses to "fees earned before maturity". Worse, any slash computed from live pool state can be lowered by the exiter manipulating that state in the same transaction. *Fix:* exit cost is a pure function of tier, age and fees already paid to the position. Proportional exits only on the penalty path.

**A4. "Launch-low fee is the LP fee only" means the venue cut starts near zero.** Then the build fund, prize slice, buyback bank, POL seeding and integrator share are all percentages of nothing, during the period with the highest costs (audits). And step-ups that land on top of a flat LP share raise the trader's all-in price, which is exactly what aggregators route away from. *Fix:* competitive gross fee from day one, with a small venue cut inside it, and a pre-announced, code-capped schedule. Plus revenue that does not depend on the cut (B-list below).

**A5. Gauges have nothing to direct.** The waterfall fixes the LP share and fixes the venue split, and there are no emissions. That leaves POL placement only, which is small for a long time. Bribes will be worth roughly nothing, so the ve/gauge machinery is cost without a market. *Fix:* carve a **boost budget** out of the venue cut; gauge votes allocate that real-fee budget to pools' halls. A bribe then buys something measurable.

**A6. Credits are wash-farmable if volume counts.** Trading against your own liquidity costs only the venue cut — near zero under A4. *Fix:* LP credits accrue on dollars × seasoned time; trader and integrator credits accrue on **venue fee actually paid**, which cannot be faked cheaply.

**A7. "V4 with hooks" cannot be our core.** Uniswap v4 core is BUSL-licensed until its change date (2027 by my recollection — verify). The brief already implies the right answer on Arc: use the canonical PoolManager. Say it as a rule: V4 means our hook suite and routing on Uniswap's deployment, never a fork, and only on chains where it exists. "Immutable cores, same address everywhere" does not apply to that engine.

**A8. Independent fixed-supply tokens per chain.** N tokens with one name and N prices, no arbitrage path between them, fragmented liquidity and a confusing listing story. "No bridges" is a good security rule, but it does not force this. *Fix:* one token on one home chain. Other chains send their buyback and ve shares home as USDC over CCTP — already an accepted building block, and it moves USDC, not our token. Remote chains run on config defaults until you rule on how vote results reach them.

---

## B. Feasible, but should be cut or deferred

| Item | Problem | Recommendation |
|---|---|---|
| V2, V3, weighted engines at launch | Commodity engines with no emissions give LPs no reason to leave incumbents; each is an audit; liquidity fragments five ways | Launch V5 + router. Add engines when there is flow to fill them |
| Solana "behind identical interfaces" | A full rewrite in a different account model; interface identity is not achievable on-chain | Drop from v1. Parity at SDK level only, V5 only, later |
| Compounders for other protocols' farms | Every external strategy is its own risk surface | Ship the V5 vault only. External farms later — though note they are the fastest fee revenue, so not never |
| Platform oracles | A thin pool's TWAP is a manipulable pitch | External feed primary where available, platform TWAP as cross-check, fixed pitch for stable pairs |
| "Permit2-style contract" | A new allowance contract is new approval risk | Use canonical Permit2 where deployed |
| Decay of unclaimed rewards to burn | Takes fees from passive LPs | Keep, but with a long window, and auto-claim on any position touch |

---

## C. V5 — design changes

**C1. Make the curve linear with a floor, quantized to epochs.** Weight = floor + (1 − floor) × min(age, horizon) / horizon. Three consequences:

- *Claims are O(1).* Total weight moves on a schedule of slope changes at epoch boundaries (the vote-escrow technique, run upward). A position's reward over any span is `α·A + β·B` using two global accumulators per fee token, `A = Σ fees/weight` and `B = Σ epoch·fees/weight`. No loops, no keepers.
- *Blending equals tranching exactly.* On a linear ramp with the age cap already in the brief, a blended position carries precisely the weight its separate tranches would. Split/merge gaming disappears. Any curved shape leaks value one way or the other.
- It still "starts low and rises".

**C2. Let age travel with the position.** Resetting on transfer cannot be enforced — hold the position in a contract wallet and sell the wallet — and it does not protect what matters. The goal is that liquidity stays; a sold position is liquidity that stayed. Keeping age makes positions usable as collateral, gives early leavers a market exit instead of a toll, and removes the vault sub-ledger machinery. This reverses an endorsed mechanic, so it needs your ruling.

**C3. One exit, one price.** The brief has mature exit, tolled exit, panic exit and hard-lock — four states for a user to understand. Collapse to a single `exit()` whose cost is a published function of (tier, age), melting to zero. "Panic exit" becomes that same function read on a locked position. One number on screen.

**C4. Go easier on principal.** New capital already earns less while it seasons. Stacking a principal toll on top is two penalties against entering at all, competing with venues where exit is free. Recommended default for the soft tier: early exit forfeits *seasoning-period fees* first, with a small, short principal toll only as an anti-churn floor. Keep the heavy toll for the hard-lock tier, which is paid for it.

**C5. Mind the steady-state growth trap.** Once incumbents are mature, new capital in a successful pool earns below market until it seasons, so TVL stalls where it should grow. Mitigate with a meaningful floor and a horizon in weeks, not months. This is the first thing the simulator should measure.

**C6. Compound atomically.** "Rejoins at current age, verified against what the hall paid" needs a stored credit ledger. A single `claimAndCompound` call needs none and is the same rule for wallets and vaults.

**C7. Toll destination (§14.13).** Recommend a split: most to seasoned weight, a ruled share to POL. That POL earns fees for the venue permanently — it is the treasury's compounding asset and the best pre-token revenue line in the design.

**C8. Depeg waiver must read an external reference**, never the pool's own price, or a large locker can buy their own release.

**C9. Guarded launch.** Immutable cores plus new math means no patch path. Add per-pool deposit caps that only ratchet upward, and state as an invariant that pause never blocks exit.

---

## D. Keep — these are right

Fees to a ledger rather than reserves. Real fees only, no emissions. Burn Vault with no withdraw. Meter counts burned, not deposited. Guardian can pause, never set. Hooks never on the exit path. Tuning-fork fee charged over the whole move against an external pitch (add a cap on the away-fee). Tiered POL with an outflow cap. Pay-to-open limited to access, never yield. ERC-20 face of USDC as canonical on Arc. Streaming buyback over a single launch-day buy.

One rule to add: **the swap path stays dumb and cheap.** With no emissions, volume comes from aggregators, and they need exact view quotes and low gas. Seasoning, tolls and hooks must never touch swap execution cost.

---

## E. Not mine to decide — get counsel

Prize games with any element of chance; fees pre-committed to buy a future token; a promised airdrop allocation. These are legal-classification questions that differ by jurisdiction, and the Bonfire weighting in A1 (requires holding capital) may bear on the first.

---

## F. Rulings needed from you

1. Bonfire prizes weighted by seasoned weight (A1).
2. Reopen LOCK §5b: Buyback Engine + sunset (A2).
3. Day-one venue cut inside a competitive gross fee (A4).
4. Boost budget as what gauges direct (A5).
5. One home-chain token vs per-chain instances (A8).
6. Age travels with the position (C2).
7. Soft-tier exit forfeits fees before principal (C4).
8. v1 scope: V5 + router + hall + V5 vault only (B).

---

## G. What I would do next

Stop versioning the brief. Build two things in this repo:

1. **A simulator** for V5 (floor, horizon, toll, POL share as inputs; LP returns by cohort, depth retention, venue revenue as outputs). Rulings 3, 4, 7 and every unruled V5 parameter fall out of it.
2. **The hall and pool core in Foundry** with invariant tests — the accumulator in C1 is about two hundred lines and proves the idea is buildable.

Then the interface: a position screen built around one live number — what leaving costs right now — with the toll visibly melting. That is the product's nudge, and it only works if C3 holds.

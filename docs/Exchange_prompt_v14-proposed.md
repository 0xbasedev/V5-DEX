# Handoff prompt — The Machine (v14 PROPOSED, 2026-11-10)

> **Status: not ruled.** This is v13 rewritten with the changes argued in `review-v13.md`. Passages marked **[CHANGED]** or **[NEW]** are proposals awaiting Jess's ruling; until ruled, v13 and spec v1.13 govern. Two changes reopen LOCKED items (§5b pre-token banking, and by implication the per-chain token recommendation in §7) and are flagged where they occur. No number in this document is settled; where a parameter is named without a value, it comes from simulation, not from invention.

We are designing a new chain-agnostic exchange. Build to this brief, and flag anything you think is wrong rather than silently changing it. The spec governs: it marks every item LOCK, PROPOSAL, or OPEN — where the spec and this brief differ, the spec wins; where the spec is silent, ask instead of inventing numbers.

## Scope and phases [CHANGED]

**v1 ships one thing well:** V5 pools, the epoch hall, an immutable router, the fee-config registry, the V5 auto-compounding vault, and the app. EVM only.

**Later phases, each gated on real flow through the previous one:** our hook suite on Uniswap's canonical v4 PoolManager; V2-style, V3-style and weighted engines under the same shell; compounders for other protocols' farms; the token, ve-locks and gauges; a Solana implementation with parity at the SDK level only.

**V4 rule [NEW]:** V4 means our hooks and routing on Uniswap's own deployment. We never fork or redeploy v4 core, and the engine exists only on chains where the canonical PoolManager does. "Immutable cores at the same address everywhere" applies to our engines, not to this one.

**Swap-path rule [NEW]:** volume comes from aggregators, so swap execution stays simple, cheap and exactly quotable by a view call. Seasoning, exit pricing and hooks never add cost or uncertainty to a swap.

## V5

The swap curve is a weighted or stable-amplified pool; the LP share is a seasoned position. V5 runs as its own pool contract reusing audited curve math, with swap fees routed to a separate ledger — never into reserves, where they would pay unseasoned holders. Positions stake in an epoch hall and are paid by pull-claim from that ledger every 6-hour epoch, from REAL fees, never printed tokens.

**Seasoning curve [CHANGED]:** weight rises linearly from a floor to full over a maturity horizon, with age counted in whole epochs and capped at the horizon. Linear is a requirement, not a taste: it makes a blended position carry exactly the weight its separate tranches would (no split/merge gaming), and it lets the hall settle any claim in constant time from two global accumulators per fee token, with total weight moved by scheduled slope changes at epoch boundaries. Floor and horizon are unruled; the horizon is expected in weeks, and the floor high enough that new capital in a mature pool is not starved.

**Positions [CHANGED]:** a position is a transferable token and its age travels with it. Liquidity that changes hands is liquidity that stayed, which is the goal; a reset on transfer is unenforceable against contract wallets and costs composability. Vaults hold ordinary positions and need no special sub-ledgers. New capital added to a position blends in at age zero.

**Compounding [CHANGED]:** fees rejoin a position at its current age only through an atomic claim-and-compound call, limited to what the hall paid in that call. Same rule for wallets and vaults; manual compounding stays free; compounding never resets seasoning.

**Exit [CHANGED]:** one exit function, one price. The cost of leaving is a published function of tier and age that melts to zero at maturity, and depends on nothing an exiter can move in the same transaction. On the soft tier, leaving early forfeits fees earned during seasoning first; a principal toll, if any, is small and short. The hard-lock tier locks for a minimum term, earns a higher weight, and pays a heavier early-exit cost — "panic exit" is that same function read on a locked position, always available. Penalty exits are proportional only. Forfeits and tolls stay in the pool as depth: a ruled share becomes protocol-owned liquidity, the rest goes through the hall to seasoned weight. Never count them twice.

**Waivers:** exit costs are waived automatically on a guardian pause or a time-weighted depeg window measured against an external reference — never the pool's own price, never a single block.

**Tuning-fork fee:** peg and target pools charge a fee over the whole price move, measured against a configured pitch (fixed price, or an external feed cross-checked by a platform TWAP — never the pool's own drifting TWAP), with a nonzero floor toward the pitch and a cap away from it **[NEW: the cap]**.

**Guarded launch [NEW]:** every pool has a deposit cap that can only be raised. Pause never blocks exit — this is an invariant, tested as one.

## Fees and revenue [CHANGED]

Gross fee = LP share + venue cut. The gross fee is competitive for the pair from day one and the venue cut sits inside it — small at launch, on a pre-announced schedule with a ceiling fixed in code. The venue cut splits only across: build fund, protocol-owned liquidity, buyback, ve share, prizes, and a boost budget — summing to 100%. Pre-token, the ve share and boost budget are zero and their weight goes to the other lines under one written split (percentages OPEN).

Revenue that does not depend on the cut: fees earned by protocol-owned liquidity, a performance fee on vault harvests, one-time "pay to open" unlocks (access and operator features only — nothing that multiplies earnings or credits may ever be sold), and integrator fees. Integrators may add their own fee on their own routed flow **[NEW]**, and also earn a share of the venue cut on that flow (size OPEN).

## Token

The exchange launches TOKENLESS. When it comes, the token is fixed-supply and DEFLATIONARY ONLY.

**One token, one home chain [CHANGED — reverses the per-chain recommendation]:** the token never leaves its home chain and is never bridged. Other chains send their buyback and ve shares home as USDC over CCTP. How vote results reach remote chains is OPEN; until ruled, remote chains run on config defaults.

**Buyback Engine and Burn Vault [CHANGED — amends LOCK §5b]:** two contracts. The Buyback Engine holds stables and buys the token in a continuous, oracle-bounded stream — never one predictable purchase. The Burn Vault holds only the token: no withdraw function, no admin role, no voting weight, one permissionless time-gated burn() on Burn Day; the public meter counts tokens burned, not deposited. Pre-token, buyback-earmarked fees bank in the Engine, which carries a dated sunset: if no token is wired by the deadline, the banked funds are paid to LPs through the hall and can go nowhere else.

**Burn sources:** buybacks; the burn slice of ve-lock early-exit fees (the rest goes to lockers who stayed — the LP exit cost and the lock fee are different charges, never merged); decayed unclaimed rewards after a long window, with rewards auto-claimed whenever a position is touched **[NEW]**. Event money never mixes with burn money.

**Locks and gauges [CHANGED]:** holders may lock for a receipt (longer lock = more fee share and gauge weight; early exit allowed for the split fee). Gauges direct two things, both real: placement of protocol-owned liquidity, and the boost budget — a slice of the venue cut paid into the halls of voted pools. Never emissions. Bribes are permitted; they now buy something measurable. POL placement stays tiered: bribes can arrive at once, POL moves only into pools passing age, depth and oracle checks, under a per-epoch outflow cap.

## Credits and airdrop [CHANGED]

Non-transferable credits accrue toward a later airdrop from a fixed allocation, by Merkle snapshot computed with a published script and a dispute window. LP credits accrue on dollars × seasoned time. Trader and integrator credits accrue on venue fee actually paid — never on raw volume, which can be manufactured against one's own liquidity.

## The Bonfire

A monthly ritual burn event (name open), FREE to enter at every phase, with games and prizes funded from the prize slice of fees — never the burn pot. **[CHANGED]** Prizes split by fixed rule weighted by seasoned weight; equal-per-attendee is withdrawn, because with free entry it pays whoever brings the most wallets. Pre-token the proposed prize is a time-limited, capped credit multiplier; post-token, boosts come from a real fee slice, never minted. Any game with an element of chance needs legal review before it ships.

## Developer platform

SDK and API at parity with the venues developers already integrate; copy-paste snippets; plug-and-play zapping; native LP-position swaps. Router versions are immutable and take no unlimited approvals — per-transaction permits through canonical Permit2 where it is deployed **[CHANGED]**. Canonical addresses live in an onchain registry and snippets verify against it before requesting a signature. A zap out of a position discloses its exit cost before signing, in our app and in partner snippets by default. Hooks: a parameterized library plus custom hooks inside a capability-scoped skeleton, code-hash-pinned, gas-bounded and isolated so that no third-party code can block or reprice an exit. The MCP server builds transactions only against our own router and factory, defaults the recipient to the signer, shows a plain-language preview, and never holds keys.

## USDC and Arc

USDC is the load-bearing stable (LOCKED, spec §8b): default quote and settlement asset and the denomination for the platform's money plumbing, with Circle products (CCTP, Wallets) as config-gated building blocks. The shell resolves a "primary stable" role per chain: USDC where it is native, another asset where it is not. Arc (chain 5042): Uniswap v4 is on mainnet (PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951) but not on testnet, so rehearsal is a local mainnet fork under Circle's arc-foundry. Arc's USDC has two faces over one balance — native with 18 decimals and the ERC-20 at 0x3600000000000000000000000000000000000000 with 6 — and v4 treats them as different currencies: profiles pin the ERC-20 face as canonical and never create native-currency USDC pools. **[NOTE]** The contract at the PoolManager address was created 2026-05-27, before the "mainnet live since 2026-09-16" date in v13; reconcile in the spec.

## Platform rules

Everything is config (percentages, precision per spec §14.11 — never bps or wei in config files). Deployments are deterministic (CREATE3, same addresses on every standard EVM chain; non-standard chains are exceptions). No bridges. New chains are entered on testnet before mainnet, subject to the chain-health question in spec §14.8. Admin authority: cores are immutable; the fee-config registry is the only mutable surface (code-bounded, timelocked, per-chain signer sets); a guardian may pause and waive but never set values. A deploy wizard deploys; an Admin panel maintains and previews consequences before confirming.

## How open items get settled [NEW]

Parameters are settled by a simulator checked into this repo, not by further rounds of deliberation: floor, horizon, exit-cost schedule, POL share, venue cut and boost budget go in; LP returns by cohort, depth retention and venue revenue come out. A ruling cites a run.

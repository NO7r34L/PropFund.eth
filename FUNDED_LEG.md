# PropFund — Funded Leg & Performance Scaling (Design Spec)

> Status: **proposal — for sign-off before contract changes.** Branch: `feat/funded-leg-scaling`.
> This document specifies turning PropFund's *funded* phase from a virtual construct into
> real, performance-scaled capital deployed on an on-chain perp venue, and the economics
> ($1 eval) that the scaling model makes safe.

## 1. Motivation

Today PropFund has two phases, both fully virtual:

- **Eval** — synthetic `virtualBalance *= spot/entry`, priced off Pyth, 1× long-only, no real capital.
- **Funded** — `openTrade` moves USDC *inside the pool* (`PropFund.sol:1017`) priced off Pyth. Still virtual: no external position exists anywhere.

The goal of this work is to keep the eval virtual (its strength — zero custody risk while proving skill)
and make the **funded leg real**: a passing trader's signal is mirrored into an actual leveraged
perp position, capital scaling up with proven performance and down with losses.

## 2. Venue decision

Per the venue research (see commit notes), the funded leg targets **Base** to keep gas a fraction of a
fraction (sub-cent), and stays **Pyth-native** end-to-end so the funded price process matches the eval.

| | Primary | Runner-up | Rejected |
|---|---|---|---|
| Venue | **Avantis (Base)** | **Synthetix Perps V3 (Base)** | GMX (Arb/Chainlink), Gains (Chainlink/EOA), Hyperliquid/Drift/Aevo (own L1s), Vertex (off-chain sequencer), Aave-loop (high gas, no funding) |
| Oracle | Pyth Pro + Chainlink | Pyth (SIP-285) | — |
| Exec | **Atomic** single-tx `openTrade{value: execFee}(...)` | Async `commitOrder` → keeper settle | — |
| Why | Maps 1:1 to our atomic-router pattern; simplest accounting | Cross-margin, NFT account a contract can own, 20% integrator fee rebate | — |

**Decision:** build the adapter interface generic; ship **Avantis** first (atomic execution matches the
existing `PropFundRouter` pattern). Keep Synthetix V3 as a second adapter once the interface is proven.

### Adapter boundary
The funded leg is an **optional adapter behind a stable interface** — `PropFund` stays synthetic by
default; a `IFundedVenue` adapter (`AvantisAdapter`, later `SynthetixV3Adapter`) is wired in only when
real trading is enabled. This preserves the current clean design boundary and lets us deploy on Base
**testnet first**, mainnet only when ready.

```solidity
interface IFundedVenue {
    function openPosition(uint8 assetId, uint256 collateral, bool isLong, uint8 leverage, uint64 tp, uint64 sl)
        external payable returns (bytes32 positionKey);
    function closePosition(bytes32 positionKey) external payable returns (int256 realizedPnl);
    function positionPnl(bytes32 positionKey) external view returns (int256);
}
```

> Note: Avantis charges funding rates, dynamic hourly fees, spread, and **caps max profit per position**.
> These are real frictions on the funded capital (gas is ~free, trading frictions are not). The adapter
> surfaces them so internal PnL accounting reflects venue reality, not the frictionless eval.

## 3. Eval-fee economics

**Eval fee = $1** (token amount; configurable). What it does — and explicitly does *not* — do:

- ✅ **Covers operating cost** — eval is virtual + sub-cent Base gas; $1 is 100×+ the real per-eval cost.
- ✅ **Sybil / brute-force tax** — on a permissionless chain a free eval invites bots retrying until
  variance flukes a pass. The eval is hard to fluke (+8% over ≥3 trades, ≤5% drawdown), so expected
  attempts-to-fluke is high and $1×attempts is a real deterrent.
- ❌ **Does NOT subsidize funding losses.** At a 10% pass rate, $1 fees back only ~$10 per funded account —
  trivial vs. capital at risk. **The funded leg must therefore be self-sustaining on its own** (drawdown
  stop + profit split + integrator rebates), independent of eval-fee revenue.

**What makes $1 safe:** the scaling model in §4. A fluke pass yields a *tiny* starting account; meaningful
capital is unlocked only by sustained, rule-abiding real performance. The attacker can't convert one lucky
pass into a payday.

## 4. Performance scaling model (the core)

Funding scales **up** with proven performance + rule adherence, **down** with losses. Bidirectional.

### 4.1 Current state & the one contradiction
`_leverageLevel(cumulativePnl)` already derives a tier from lifetime realized PnL:

| cumulative PnL | tier |
|---|---|
| baseline | 2× |
| ≥ +$50 | 3× |
| ≥ +$150 | 5× |
| ≥ +$400 | 8× |
| ≥ +$1000 | 10× |

This curve is bidirectional **in spirit** (pure function of `cumulativePnl`), but the trade gate uses
`f.lastLevel`, which **only ratchets up** (`PropFund.sol:996` — "once earned, the tier sticks even after a
drawdown"). A trader who spikes to 10× then bleeds keeps 10×. **This directly contradicts "scales down
with losses."**

### 4.2 Change 1 — live-tier gating (bidirectional)
Gate trades on the **live** `_leverageLevel(cumulativePnl)` instead of the ratcheted `lastLevel`. A losing
trader is automatically demoted the moment cumulative PnL falls through a threshold — no new machinery.
Keep `lastLevel` **only** for achievement NFT mints (so "reached level 8" still mints), never for risk.

### 4.3 Change 2 — scale the capital, not just leverage
Today allocation (`f.deposit`) is static; only leverage scales. Real prop scaling grows the *funded
amount*. Tie the effective allocation cap to the same live tier:

```
allocation A = baseAllocation × tierMultiplier(cumulativePnl)
```

Funding and leverage both scale off one proven metric, both directions. Bigger A → bigger absolute payouts
(trader's split of profit on a bigger base). Losses shrink A → smaller pool risk → self-correcting.

### 4.4 Change 3 — rule-adherence promotion gate
Scaling **up** requires rule adherence, not just a lucky PnL print. Enforced conditions:

- Never breached the max-drawdown stop (5%/level floor).
- Respected per-trade margin cap and mandatory TP/SL.
- Minimum N closed trades at the current tier before promotion (no single-trade jumps).
- Hard-rule break (drawdown breach) → **demote a tier or terminate funding**, not just pause.

### 4.5 End-to-end lifecycle
1. Pass virtual eval (pay $1) → funded at **tier 2, small base allocation** (fluke-safe).
2. Trade real on Avantis, sized off `A × tier`, drawdown-stopped.
3. Sustained profit + clean record → `cumulativePnl` climbs → tier + allocation step up → bigger payouts.
4. Losses → `cumulativePnl` falls → tier + allocation step **down** automatically.
5. Drawdown breach → demote / terminate.

## 5. Risk bounds
- **Floor:** start tier 2, minimal base allocation — caps fluke-pass extraction.
- **Ceiling:** hard max allocation per trader + global funded cap (`MAX_FUNDED_TRADERS`) — bounds pool risk.
- **Drawdown stop** on the live Avantis position, enforced by the keeper.
- **Pool buffer:** retain a USDC reserve to absorb venue-level / liquidation tail risk.
- **Venue risk:** perp protocols carry smart-contract + liquidation + keeper-liveness risk (cf. Drift
  exploit). Diversify venues over time; cap exposure per venue.

## 6. Contract changes (diff plan — for sign-off)
1. **Live-tier gate** — replace `leverage > f.lastLevel` check with `leverage > _leverageLevel(f.cumulativePnl)`; keep `lastLevel` for NFTs only.
2. **Allocation scaling** — `_effectiveCap` / margin sizing scales with `tierMultiplier(cumulativePnl)`.
3. **Promotion gate** — track trades-at-tier + drawdown-clean flag; require both for step-up; demote/terminate on breach.
4. **`IFundedVenue` interface** + `AvantisAdapter` (Base) wired behind a feature flag; `PropFund` stays synthetic unless enabled.
5. **Eval fee** — add a configurable fee (default $1) collected on eval start; revenue to treasury/pool.
6. Tests: bidirectional scaling, demotion on loss, promotion-gate enforcement, adapter open/close, fee accounting. Recheck EIP-170 size budget (currently 68 bytes spare).

## 7. Open decisions
- **Up/down rates** — keep the existing $50/$150/$400/$1000 PnL thresholds, or recalibrate for allocation scaling?
- **`baseAllocation`** starting size and **max allocation** ceiling.
- **Profit split** (trader vs. pool) and whether integrator rebates go to pool or are shared.
- **Eval fee token** — USDC $1, or ETH-equivalent? Refundable on pass (some firms refund the fee to passers)?
- **Termination vs. demotion** on first drawdown breach — hard cut or one-tier demote with a strike system?
- **Testnet-first** Avantis (Base Sepolia availability TBD) vs. straight to a capped mainnet pilot.

---
*Eval stays virtual and custody-free. Funded capital flows only toward demonstrated, rule-abiding
performance, bounded at every step — which is what lets the eval fee be $1.*

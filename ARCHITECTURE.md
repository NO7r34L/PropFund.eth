# PropFund — Architecture

A single immutable trading contract that runs an oracle-settled prop firm. Users connect with their own wallet (or via a delegated controller) and call the contract directly. No backend, no upgrades. The treasury wallet has emergency pause, `addFeeds`, and `withdrawTreasury` only — it cannot change rules, withdraw user funds, or alter accounting.

---

## Money flow

```
                   ┌─────────────────────────────────────────┐
                   │                                         │
   ┌──────────┐    │   ┌──────────────────────────────┐      │   ┌──────────┐
   │   LPs    │ ──── ▶ │                              │ ◀──────── │ Traders  │
   │ (USDC)   │    │   │      PropFund.sol            │      │   │  (eval   │
   └──────────┘    │   │                              │      │   │  + dep)  │
                   │   │  poolBalance ─────────┐      │      │   └──────────┘
                   │   │                       ▼      │      │
                   │   │  ┌─────────────────────────┐ │      │
                   │   │  │  USDC.balanceOf(this)   │ │      │
                   │   │  └─────────────────────────┘ │      │
                   │   │                              │      │
                   │   │  priceIds[i] ─▶ Pyth ────────────────── ▶ Hermes (signed VAA)
                   │   └──────────────────────────────┘      │
                   │              │           │              │
                   │              ▼           ▼              │
                   │     treasury (5% fee)   trader (80%)    │
                   │                                         │
                   └─────────────────────────────────────────┘
```

**Inflows to the pool:**
- LP `deposit(amount)` — mints shares
- Trader `startEval()` — pays `EVAL_FEE`
- Trader `claimFunding()` — pays `TRADER_DEPOSIT` (or escrows it on the FIFO queue)
- Trader closes a losing trade — counterparty win, deposit absorbs first up to position margin
- Liquidation — failing trader's position margin forfeits

**Outflows from the pool:**
- LP `withdraw(shares)` — burns shares, returns prorata pool value
- Trader closes a winning trade — 80% of PnL compounds into deposit
- Trader `withdrawProfit(amount)` — withdraws above-deposit balance
- Trader `resignFunding()` — returns full current deposit
- Treasury accrues 5% of every winning trade (pulled later via `withdrawTreasury`)

---

## State machines

### Eval lifecycle

```
   ┌──────────┐  startEval() $10  ┌──────────┐
   │ inactive │ ─────────────────▶│  active  │ ◀───┐
   └──────────┘                   └──────────┘     │
        ▲                              │           │
        │                              ▼           │
        │       failed (-5% drawdown) ┌──────────┐ │
        ├──────────────────────────── │  trade   │ │
        │       expired (block #)     └──────────┘ │
        │                              │           │
        │                              ▼           │
        │                         ┌──────────┐     │
        │                         │  closed  │ ────┘ openEvalTrade(assetId)
        │                         └──────────┘       (different asset OK)
        │                              │
        │       passed (+8%, ≥3 trades)│
        │                              ▼
        │                         ┌──────────┐
        │  cancelEval()           │  passed  │
        │  (100-block cooldown    └──────────┘
        │   between cancels)           │
        │                              │ claimFunding() $100
        │                              ▼
        │                         ┌──────────┐
        └─────────────────────────│  funded  │
                                  └──────────┘
```

### Funded trader lifecycle

```
                            ┌──────────┐
                            │  funded  │
                            └──────────┘
                              │   │   │
                openTrade ────┘   │   └──── resignFunding ──▶ inactive (deposit returned)
                (mandatory tp+sl) │
                              ▼   │
                        ┌──────────┐
                        │  inTrade │
                        └──────────┘
                              │
        ┌────────┬────────────┼─────────────┬─────────────┬──────────────┐
        ▼        ▼            ▼             ▼             ▼              ▼
  closeTrade  exec-exit  liquidate   force-close    emergency      (open lasts
  (trader)   (any kpr,   (any kpr,   (any kpr,      Close          ≤ 14 days)
              TP/SL hit)   loss ≥     pos > 14d)    (cached spot)
                          margin)
        │           │           │             │             │
        └─────┬─────┴───────────┴─────────────┴─────────────┘
              ▼
       winner: 80% to deposit, 15% LP, 5% treasury
       loser:  loss capped at margin; deposit/2 preserved
```

### Funding queue

```
   pass eval              pool/cap full?
   ──────────▶ claimFunding ───┬─────── yes ──▶ deposit escrowed,
                               │                FIFO-queued
                               │                                ▲
                               └──── no  ──▶ funded immediately │
                                                                │
                anyone calls processFundingQueue(max) ──────────┘
                — drains while pool capacity exists
                — leaveFundingQueue() refunds anytime
```

### Delegation

```
   principal:        setController(controller, maxNotional, expiry)
                     approves USDC for budget
                            │
                            ▼
   controller acts:  *For(principal, ...) variants on every trader function
                     EXCEPT withdrawProfit + resignFunding  (principal-only)
                     EXCEPT setController + revokeController (principal-only)
                            │
                            ▼
   on revoke OR expiry:  *For() reverts NotAuthorized / AuthorizationExpired
                         existing positions unaffected
```

### Emergency pause

```
   treasury calls setPaused(true)
            │
            ▼
   blocks: deposit, startEval, openEvalTrade, claimFunding, openTrade
   permits: withdraw, closeTrade, cancelEval, executeExit, liquidate,
            forceClose, processFundingQueue, withdrawProfit, resignFunding,
            leaveFundingQueue, updateExit, emergencyClose
            (i.e., users always have an exit path)
```

---

## Contract layout

```
src/
  PropFund.sol             — main contract (~1340 LOC, deployed bytecode ~24,530 bytes / 24,576 limit)
  EvalCert.sol             — minimal ERC-721 (mint-only by PropFund, swappable renderer pointer)
  EvalCertRenderer.sol     — fully on-chain SVG renderer, procedural per-trader candlestick chart
  interfaces/
    IERC20.sol
    IPyth.sol              — minimal interface: getPriceUnsafe, updatePriceFeeds, getUpdateFee
  lib/
    SafeTransferLib.sol    — wrapped USDC transfers + tryTransfer (no-revert path for liquidations)

lib/
  solady/                  — vendored: DynamicBufferLib, Base64, LibString (renderer deps)
```

**No upgradeable proxies. No diamond pattern. No external libraries to delegatecall to.** EvalCert's `setRenderer` swaps a stored address — there is no delegatecall surface; the renderer is invoked via standard external `view` call.

---

## Key constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `EVAL_PROFIT_BPS` | 800 | +8% required to pass eval |
| `EVAL_DRAWDOWN_BPS` | 500 | −5% drawdown fails eval |
| `MIN_EVAL_TRADES` | 3 | Minimum closed eval trades before pass |
| `MIN_TRADE_BLOCKS` | 10 | Minimum blocks between open and close |
| `EVAL_CANCEL_COOLDOWN` | 100 | Min blocks between successful eval cancels |
| `CIRCUIT_BREAKER_BPS` | 5000 | 50% max price-move used in PnL calculation |
| `MAX_LEVERAGE` | 10 | Maximum leverage per trade (level-gated) |
| `ORACLE_MAX_STALE` | 48 h | Upper bound on per-feed staleness window |
| `ORACLE_MIN_STALE` | 5 min | Minimum heartbeat accepted at install |
| `TARGET_PRICE_EXPO` | −8 | Required Pyth expo (validated at install) |
| `MAX_CONF_BPS` | 50 | Reject Pyth reads with conf > 0.5% of price |
| `MAX_POSITION_BLOCKS` | 604 800 | ~14 days at 2 s blocks (Base); anyone can `forceClose` after |
| `MAX_FUNDED_TRADERS` | (config) | Cap on simultaneously-funded traders (queue overflow → FIFO) |
| `EVAL_FEE` | (config) | Eval fee in USDC |
| `TRADER_DEPOSIT` | (config) | Funding deposit in USDC |
| `FUNDED_ALLOCATION` | (config) | Reference number for events; real cap is `effectiveCap` |
| `TRADER_PROFIT_BPS` | 8000 | 80% of profit to trader |
| `TREASURY_FEE_BPS` | 500 | 5% of profit to the treasury (accrued; pulled via `withdrawTreasury`) |

**Trade sizing model:**
- `maxMargin = deposit / 2` — the other 50% is always preserved
- `notional = margin × leverage`, leverage in [1, MAX_LEVERAGE]
- Per-trade max loss = `margin` (absorbed by deposit; pool eats overflow as counterparty)
- Effective max notional per trade: `min((deposit × MAX_LEVERAGE) / 2, poolBalance / fundedTraderCount)` — fair partition prevents one trader from soaking the whole pool

**Splits:** 80% trader / 15% LP / 5% treasury on profits. Deposit absorbs loss up to `margin`, then pool eats the rest as counterparty.

**Mandatory exits:** Every funded `openTrade` must specify both TP and SL. Long: tp > entry; short: tp < entry. SL is allowed past entry (trailing/breakeven stop) but never inverted past TP.

---

## External dependencies

| Dependency | Risk | Mitigation |
|------------|------|------------|
| Pyth Network | Compromise / publisher disagreement → wrong settlement | Conf-interval guard (`MAX_CONF_BPS`); per-feed staleness; expo locked at install; emergency-close uses cached spot |
| USDC | Issuer blacklist / depeg | Documented as residual; `_tryTransfer` no-revert pattern keeps state consistent during settlement |
| Solidity 0.8.26 + EVM Cancun | Compiler bugs | Tested with `via_ir = false` (avoid known 0.8.26 + IR mis-folding); transient-storage reentrancy guard from EIP-1153 |
| Solady (`DynamicBufferLib`, `Base64`, `LibString`) | Library bug → bad SVG | Renderer is `view` only — no funds at risk. Renderer is hot-swappable via `setRenderer` |

No other dependencies. No DEX integration. No bridges. No off-chain components are required for the contract to operate — the CLI and keeper bot are reference implementations, not load-bearing.

---

## Deployment topology

A typical deploy:
1. Deploy `PropFund` with config (USDC, Pyth, treasury, fees, durations, asset feeds + staleness windows). The constructor deploys `EvalCert` internally with `treasury` as cert admin.
2. Deploy `EvalCertRenderer` with the new PropFund address (renderer reads trader stats via `evals(addr)` / `funded(addr)`).
3. As the treasury wallet, call `cert.setRenderer(rendererAddr)`. (The Base Sepolia deploy script does steps 2 + 3 automatically; the Base mainnet script leaves it as a separate treasury action so it can be done from a multisig.)
4. (Optional) Hand off `cert.admin` to a multisig for production.

Contract addresses are tracked in `cli/src/networks.js` as the canonical source.

# PropFund — Threat Model

This document is the self-disclosed risk surface. Each section pairs an attack vector or design tradeoff with the mitigation in code.

---

## Trust assumptions

- **Pyth Network** is trusted to report a fair USD price (within its stated confidence interval) per published update. Compromise of Pyth's signing keys, mass publisher disagreement, or a bug in the Pyth deployment can cause incorrect settlement.
- **USDC issuer (Circle)** can blacklist any address, including the contract itself. A blacklist halts transfers. Mitigated where possible by `_tryTransfer` (no-revert) so state stays consistent.
- **`treasury` address** (set at construction, immutable) has limited privileges:
  - `addFeeds(...)` — append new Pyth feeds. Cannot remove or modify existing ones.
  - `setPaused(bool)` — emergency stop; blocks new opens; exits remain callable.
  - Receives 5% of every winning trade as a fee.

  Recommended operational practice: the treasury wallet should be a multisig (e.g., Safe). Even better with a timelock wrapper.

- **EvalCert admin** (`cert.admin()`, set at construction to `treasury`, settable) can swap the SVG renderer. Renderer is `view`-only; risk is bounded to metadata corruption, not funds.

No other trusted parties. No proxy. No on-chain governance.

---

## Core invariants (proven by `test/Invariants.t.sol`, 12 invariants × thousands of fuzz sequences)

| # | Invariant | Why it matters |
|---|-----------|----------------|
| 1 | `USDC.balanceOf(this) >= sum(deposit)` | Pool always covers trader resign payouts |
| 2 | `position.deployed <= 2 × funded.deposit` | Per-trader leverage cap holds |
| 3 | `totalDeployed == sum(active position.deployed)` | Accounting consistency |
| 4 | `eval.active && eval.passed` impossible | Eval state-machine consistency |
| 5 | `position.active ⇒ entryPrice > 0` | No zombie positions |
| 6 | `funded count <= MAX_FUNDED_TRADERS` | Bounded growth |
| 7 | `poolBalance <= USDC.balanceOf(this)` | Internal accounting bounded by physical USDC |
| 8 | `totalShares > 0 ⇒ poolValue > 0` | Shares always backed |
| 9 | Treasury fee balance bounded by total system inflow | No silent treasury overpay |
| 10 | Active eval never below drawdown floor | Drawdown cap holds at all times |
| 11 | `startBlock` never in the future | State integrity |
| 12 | Active funded always has `deposit > 0` | Auto-withdraw removal verified |

---

## Attack vectors considered

### 1. Sybil drain on the LP pool
**Vector:** A coordinated set of wallets pays $10 evals, fails them on purpose, then claims the pool by other means.

**Mitigation:** Failing an eval costs $10 and gives the attacker nothing back. Pool grows on failures, doesn't shrink. To extract anything they'd have to pass eval (+8% on virtual balance), claim funding ($100 deposit at risk), then trade profitably — at which point they're a legitimate trader.

**Worst case attacker spend → max LP drain:** $0. Asymmetric in the LP's favor.

### 2. Oracle manipulation against Pyth
**Vector:** Attacker tries to push a bad Pyth update, or sandwiches a legitimate update to settle a position favorably.

**Mitigation:** Pyth updates are signed by a federated set of publishers; on-chain `updatePriceFeeds` verifies signatures. An attacker can't inject prices without compromising publisher keys. The `MAX_CONF_BPS` guard rejects reads where `conf > 0.5% × price` — even if publishers temporarily disagree, the contract treats those windows as stale.

`MIN_TRADE_BLOCKS = 10` between eval open and close (~20s) ensures any flash-style attack has to hold position long enough to ride a real Pyth update cycle.

### 3. Stale or misbehaving oracle blocking liquidation
**Vector:** Trader goes deep underwater, Pyth feed stops updating or reports wide conf, contract refuses to read price → liquidation reverts → bad debt accumulates.

**Mitigation:** `_tryReadSpot` returns `(price, fresh=false)` on stale feeds, on `conf > MAX_CONF_BPS`, AND on non-positive answers. `liquidate()`, `forceClose()`, `executeExit()`, and `emergencyClose()` all use the no-revert path so a misbehaving feed never bricks the system. The 50% circuit breaker in `_calcPnl` then bounds settlement at ±50% of deployed even if `spot==0`. Normal trades still revert via `_readSpot` so traders can't open positions on a known-bad feed.

### 4. Malicious trader contract blocking liquidation
**Vector:** A trader uses a contract wallet whose `transfer` callback reverts. Without protection, refunding the deposit on liquidation would revert, wedging the position.

**Mitigation:** `_tryTransfer` uses a low-level `.call` that returns `bool` instead of reverting. Failed transfers leave funds in the pool but never block state changes. Verified by the liquidation invariant suite.

The trader-profit and treasury-fee paths are also pull-based for the same reason: profits compound into `f.deposit` and are pulled via `withdrawProfit`; treasury fees accrue in `treasuryBalance` and are pulled by `TREASURY` via `withdrawTreasury`. A blacklisted treasury (or a treasury contract that rejects USDC) cannot block trader settlements — the fee just stays accrued until the treasury can receive again.

### 5. Front-running trade open / close
**Vector:** Searcher bot sees a profitable trade in the mempool, copies it, gets in first.

**Mitigation:** Settlement is at the cached Pyth price after `pushPyth`, not at the trader's stated price. There is no slippage to capture, no pool to deplete, no MEV-favorable ordering. Front-running gains nothing.

### 6. Reentrancy via USDC transfer or NFT mint
**Vector:** Without care, state writes after external calls (transfers, NFT mints) could create cross-function reentrancy windows.

**Mitigation:** Four layers, in order of strength:
1. **CEI ordering** — `_closeTrade` deletes the position before invoking `_handleProfit`. `_handleProfit` writes `f.deposit`, `poolBalance`, and `f.lastLevel` before any external call. `_revokeFunding` writes `f.active`, `f.deposit`, and credits `poolBalance` before transferring.
2. **`nonReentrant` guard** on every external mutating entry point (transient-storage based, EIP-1153). Re-entry into any guarded function during an in-flight call reverts with `Reentrancy()`.
3. **USDC has no callback** on `transfer`. Standard ERC-20.
4. **`EvalCert.mint`** only writes storage and emits `Transfer`; no recipient hook. Wrapped in `try/catch` so a malicious renderer can't block parent settlement.

Slither flags two warnings in `_closeTrade` related to its self-recursion (when partial close drops the deposit below `MIN_DEPOSIT`, it recursively closes the remainder). False-positive: the recursion only enters via the same `nonReentrant`-guarded call frame, and all state writes inside the recursive call are themselves CEI-ordered.

### 7. Eval gaming — open and close in the same block to lock a price
**Vector:** Trader opens at oracle's last price, closes immediately if price moved favorably, generating risk-free profit.

**Mitigation:** `MIN_TRADE_BLOCKS = 10` between open and close. `MIN_EVAL_TRADES = 3` minimum trades to pass. Combined with Pyth's update cadence and the conf-interval guard, eval cannot be passed without taking real directional risk over multiple blocks.

### 8. Circuit-breaker bypass on a flash crash
**Vector:** ETH crashes 50% in one block (oracle outage + recovery prints a wide gap). Funded trader is +50% short. Pool pays massive profit.

**Mitigation:** `CIRCUIT_BREAKER_BPS = 5000` (50%) caps the price move used in `_calcPnl` in either direction. A 50% adverse move pays the trader 50% of notional, no more. Combined with the **50% margin rule**, trader's deposit can never lose more than `margin = deposit / 2` per trade — the other 50% always survives.

### 9. Single-trade blowup of the trader (50% margin rule)
**Vector:** A trader sizes a single trade at full deposit, takes a bad fill, loses everything in one tx.

**Mitigation:** Each trade can only post up to **50% of deposit** as margin. Loss on the trade is capped at `position.margin`; anything beyond is the pool's cost as counterparty. The remaining `(deposit - margin)` is preserved no matter what. Liquidation triggers when `unrealizedLoss >= position.margin`, closes the position, leaves the trader funded with the protected half-deposit.

### 10. Mandatory-exit footgun
**Vector:** With mandatory TP/SL on every funded trade, can a trader open a position whose SL would trigger immediately?

**Mitigation:** `_validateExit` enforces TP on the profit side of entry (long: `tp > entry`; short: `tp < entry`) and SL not inverted past TP. The intentional flexibility of "SL allowed past entry" enables trailing/breakeven stops; if a trader sets SL too tight, `executeExit` simply settles the position at near-zero PnL. Self-correcting; not catastrophic.

### 11. Oracle-latency arbitrage at high leverage
**Vector:** Pyth updates on demand (when someone pushes). Between updates, on-chain price lags real markets. At high leverage, a sophisticated trader could open ahead of an update, wait for the catch-up tick, close for guaranteed profit.

**Mitigation:** `MAX_LEVERAGE = 10` is the binding constraint. Leverage tiers are level-gated: traders need cumulative PnL milestones to unlock 5×, 8×, 10× — meaning they've already proven enough to be playing seriously. The 50% margin rule + 50% circuit breaker bound per-trade pool loss. The conf-interval guard rejects opens during illiquid windows.

### 12. First-depositor share inflation
**Vector:** Attacker deposits 1 wei, donates large USDC to inflate share value, then second depositor's shares round to zero.

**Mitigation:** First deposit mints `DEAD_SHARES = 1000` to the contract itself (standard ERC-4626 inflation defense). First real LP cannot inflate share price meaningfully.

### 13. USDC blacklist of the contract
**Vector:** Circle blacklists the contract address (sanctioned trader interaction). All transfers fail.

**Mitigation:** Out of our control. Documented as a residual risk. Mitigated by:
- Pure read-on-chain functions (`getTraderStats`, etc.) keep working
- `_tryTransfer` returns false rather than reverting, so state changes still progress
- Same residual exposure as every USDC-denominated contract in DeFi

### 14. USDC depeg
**Vector:** USDC loses parity with USD.

**Mitigation:** All amounts are denominated in USDC tokens, not USD. A depeg affects everyone proportionally. Same residual exposure as every USDC-denominated contract in DeFi.

### 15. Centralization risk on the treasury key
**Vector:** Treasury key compromised → attacker calls `addFeeds` with malicious oracles, OR `setPaused(true)` to grief.

**Mitigation:**
- `addFeeds` is append-only; can't modify existing feeds. Malicious feed only affects newly-added assets.
- `setPaused` blocks new positions but does NOT block exits — users can always close, withdraw, cancel, run keeper sweeps.
- Treasury cannot drain funds, change rules, or upgrade.

**Strongly recommended:** `treasury` should be a multisig (e.g., Safe) for production. Add a timelock wrapper before `setPaused` and `addFeeds` for additional defense.

### 16. Liquidator MEV competition
**Vector:** Multiple bots race to call `liquidate(trader)` first when it becomes profitable.

**Mitigation:** Permissionless by design. First liquidator wins. No on-chain bounty (intentional — avoid gas-griefing). Liquidators run for protocol-health reasons or as part of a broader MEV strategy. Adding a per-settle keeper fee is on the mainnet roadmap.

### 17. Eval expiry griefing
**Vector:** Anyone can call `expireEval(trader)` after the deadline. A griefer expires every eval the moment its deadline passes.

**Mitigation:** The eval deadline is published at startEval. Traders plan around it. Griefer pays gas; trader can re-eval for $10. Not a meaningful attack.

### 18. Compromised agent key drains principal via cancel-restart
**Vector:** Attacker steals an agent EOA, repeatedly calls `cancelEval` + `startEval` to drain the principal's USDC at $10 per cycle.

**Mitigation:** `EVAL_CANCEL_COOLDOWN = 100` blocks between successful cancels (audit I-6). Caps drain rate at $10 per ~200 seconds (~$0.05/s). The principal can still revoke the controller at any time. Per-trade notional cap on the authorization bounds further damage.

### 19. Compromised renderer admin
**Vector:** EvalCert admin key compromised; attacker swaps in a malicious renderer that returns a billion-byte SVG (DOS) or returns malicious metadata.

**Mitigation:** Renderer is `view`-only — no funds at risk. Worst case: NFT metadata becomes garbage; no token transfer or balance is affected. Recommended: hand off `cert.admin` to a multisig + timelock for production.

### 20. Funding queue griefing
**Vector:** Attacker spam-claims funding to fill the queue, blocking legitimate traders.

**Mitigation:** Each queue entry costs the full `TRADER_DEPOSIT` (~$100) which is escrowed. Spamming the queue at $100/slot is asymmetric in the protocol's favor. `processFundingQueue(max)` is gas-bounded so a long queue can't brick advancement.

---

### 21. Atomic-update router (`PropFundRouter`) periphery

**Vector:** The router is an optional, redeployable periphery (`src/PropFundRouter.sol`) that a trader authorizes as a controller (`setController`) so it can apply a Pyth update and trade in one tx (`updatePriceFeeds` + `*For(msg.sender, ...)`). Risks: (a) a trader authorizes a *malicious* router; (b) the router is misconfigured to point at the wrong contract/oracle; (c) value/refund handling.

**Mitigations:**
- **No custody, ever.** The router is stateless and holds no position, deposit, or balance. PropFund settles every value flow to the principal; unused `msg.value` is refunded to the caller in the same call. Authorizing a router grants only *controller* powers — bounded by `maxNotionalPerTrade` and `expiry` — never custody: `withdrawProfit` and `resignFunding` remain principal-only, so a hostile router can at worst drive an in-cap trade, not extract funds. Revoke any time via `revokeController`.
- **Pointing is fixed and verifiable.** `FUND` and `PYTH` are `immutable` (set at construction) and exposed as public getters. A valid deployment requires `router.PYTH() == FUND.PYTH()` — it must update the same oracle the contract reads from. This is checkable on-chain and on the verified source, and cannot change after deploy. (Live Eth Sepolia router `0xFb99…833ee` → `FUND 0xd566…937c`, `PYTH 0xDd24…bd21`, both matching the deployed PropFund.)
- **Trust boundary unchanged.** The router only composes existing public delegation entrypoints; it adds no new PropFund powers and PropFund's bytecode is untouched. The core's immutability/no-admin guarantees are unaffected — the router is opt-in and lives entirely outside the trust-critical contract.

---

## Known issues / accepted tradeoffs

1. **No bug-fix path** for the trading contract — PropFund is immutable. A bug discovered post-deploy cannot be patched in place; would require a redeploy + LP migration. Mitigation: extensive testing (99 tests + invariants), formal audit, conservative scope. The renderer is hot-swappable but the trading core is not.
2. **Pause is binary** — no per-asset or per-feature granular pause. Treasury can stop the protocol entirely or not at all. Acceptable given the small surface and the "exits always callable" guarantee.
3. **No keeper fee on-chain** — keepers run for protocol-health or as part of an MEV strategy. Adding a per-settle fee (e.g., 0.1% to msg.sender) is roadmap.
4. **Single asset (USDC) — no multi-collateral** — by design. Multi-asset adds significant complexity for marginal benefit.
5. **Pyth-only oracle** — by design. Multi-oracle adds attack surface (e.g., outlier-rejection logic) without commensurate benefit on supported assets.

---

## Out of scope

- CLI and keeper-bot code paths that live off-chain (`cli/`). Auditable separately; on-chain authority is gated by `setController` + the principal's USDC allowance regardless.
- Off-chain integrations (TradingView relays, Hummingbot bots).
- USDC, Pyth, and Solady security — trusted dependencies.
- Cross-chain bridge security — Base-native.

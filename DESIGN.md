# PropFund — Design

## What this is

On-chain prop trading fund. Oracle-settled multi-asset perps. The LP pool is the
counterparty. No DEX dependency, no off-chain matching, no central admin (the treasury
wallet has emergency-pause + add-feeds + treasury-withdraw only — no rule changes).

## Lifecycle

```
PAY $10 EVAL FEE
      ↓
VIRTUAL TRADING (3+ trades, ≥10 blocks each, Pyth prices, 30-day window)
  Pick any of 8 listed assets per trade — long-only.
  Net +8% with ≤5% drawdown = PASS (EVAL_PASS NFT minted)
  Cancel cooldown: 100 blocks between successful cancels.
      ↓
PAY $100 DEPOSIT
  → Funded immediately if pool capacity available
  → FIFO-queued with deposit escrowed otherwise
      ↓
TRADE (any listed asset)
  long or short, 1-10× leverage (level-gated)
  50% margin rule — at-risk capital capped at deposit/2 per trade
  fair partition — notional capped at min(perTraderCap, pool/N)
  position max-duration ~14 days (anyone can force-close after)
  MANDATORY tp + sl on every trade (long: tp>entry>sl; short: sl>entry>tp; SL allowed
    past entry as trailing breakeven stop, never inverted past TP)
  partial close, exit updates, emergency close
  profit: 80% compounds into deposit / 15% LP / 5% treasury (accrued; pulled via withdrawTreasury)
  loss: deposit absorbs up to position margin / pool absorbs remainder
  margin consumed in single trade → permissionless `liquidate` callable
      ↓
LEVEL UP (deploy cap grows; LEVEL_UP NFT minted on first cross of each tier)
  Level 2:  2×    (RECRUIT — spawn level)
  Level 3:  3×    APPRENTICE   after $50 cumulative profit
  Level 5:  5×    SKILLED      after $150
  Level 8:  8×    EXPERT       after $400
  Level 10: 10×   MASTER       after $1000
      ↓
WITHDRAW PROFIT (principal-only) or RESIGN (deposit returned)
```

## Settlement model

The LP pool is the counterparty to every trade:
- Trader profits → pool pays
- Trader loses → pool keeps it (capped at the position's margin; anything beyond is
  absorbed by LPs as cost of business)

No swaps. No slippage. No order book. No MEV-able fills. PnL settles against Pyth at
the trader's open and close times. Pyth is **pull-based**: callers (traders, keepers)
push fresh signed VAA bundles via `pushPyth(updateData)` before any price-sensitive
write so the contract sees live prices.

## Pyth integration specifics

- Every wired feed is **locked at expo = −8** at install time. Single-path PnL math,
  no expo-shift surface.
- Per-feed `staleAfter` heartbeat. Read returns `(price, fresh=false)` if
  `block.timestamp - publishTime > staleAfter`.
- **Confidence-interval guard**: reads where `conf * 10000 > price * MAX_CONF_BPS`
  (default 0.5%) are marked stale. Prevents trading during illiquid windows where
  publishers disagree.
- Negative or zero price → `(0, false)` so emergency-close + liquidate can still
  settle from the cached entry price.

## Delegation

A principal authorizes a controller EOA to drive their entire trader lifecycle:

```solidity
struct Authorization {
    address agent;                  // controller's EOA
    uint128 maxNotionalPerTrade;
    uint64 expiry;
}
```

The controller gets `*For(principal, ...)` variants of every trader action **except**
`withdrawProfit` and `resignFunding` — those are principal-only. The controller
operates positions; the principal pulls funds. All USDC flows route to the principal.
Budget is enforced by the principal's USDC allowance to the contract; per-trade
notional is bounded by the authorization. `_checkController` rejects expired or
non-matching controllers.

## Keeper paths (public)

Anyone can call:
- `liquidate(addr)` — when unrealized loss has consumed the position margin
  (last-line failsafe; explicit SL fires first under normal conditions)
- `executeExit(addr)` — when TP or SL has crossed at the current oracle price
- `forceClose(addr)` — when a position is older than `MAX_POSITION_BLOCKS` (~14 days)
- `processFundingQueue(max)` — drain the FIFO queue while pool capacity exists
- `expireEval(addr)` — clean up an active eval whose deadline has passed

A reference keeper bot ships in `cli/src/commands/keeperBot.js`. It:
1. Walks the funded-trader list (via `fundedTraderCount` + `fundedTraders(i)`)
2. Reads each trader's `positions`, `isLiquidatable`, `positionExpired`
3. Computes TP/SL hits client-side from the current spot
4. Pushes fresh Pyth state once per tick if any work is queued
5. Submits all actions in parallel (NonceManager wraps the keeper key)

**Caveat:** the contract pays no keeper fee today. Keepers run for protocol-health
reasons or as part of an MEV strategy. Adding a fee (e.g., 0.1% of settled notional
to msg.sender) is on the mainnet roadmap.

## Assets

Pyth Network feeds. Installed via `addFeeds(ids[], staleAfter[])` (treasury-only,
append-only, locked-expo validation). Each feed has its own staleness ceiling matching
Pyth's publisher cadence (5 min for crypto majors, longer for less-liquid assets).

The Base mainnet deploy lists 8 assets: ETH, BTC, SOL, AVAX, LINK, AAVE, DOGE, ARB.

## Roles

| Role     | What they do                                                                  | What they earn                                                  |
| ---      | ---                                                                           | ---                                                             |
| Trader   | Pay eval, prove skill, trade                                                  | 80% of profit (compounds into deposit)                          |
| LP       | Deposit USDC                                                                  | Failed eval fees + 15% of trader profit + counterparty wins     |
| Treasury | Deploy, `addFeeds`, `setPaused`, `withdrawTreasury`                           | 5% of trader profit — funds operations, maintenance, version support |
| Keeper   | `liquidate`, `executeExit`, `forceClose`, `processFundingQueue`, `expireEval` | None on-chain yet (TODO)                                         |

## NFT certificates

- **EVAL_PASS** — minted on passing. SVG shows the trader's actual return as a
  procedural candlestick chart, seeded from `keccak256(trader, passBlock)`. Each
  trader's NFT is unique but the walk always lands at their real return.
- **LEVEL_UP** — minted on each new tier crossed. Names: APPRENTICE / SKILLED /
  EXPERT / MASTER.
- **Fully on-chain SVG, no IPFS.** Renderer is hot-swappable via
  `EvalCert.setRenderer()` — admin-gated, lets the art evolve without redeploying the
  NFT (existing tokens automatically reflect updates).
- Mint failures (e.g., out-of-gas in renderer) emit `CertMintFailed` and the parent
  settlement still completes — NFTs are commemorative, not load-bearing.

## Safety properties

- **50% margin rule** — every trade caps at-risk capital at deposit/2; the other half
  always survives a single blowup
- **10× leverage cap, level-gated** — leverage tiers (3×, 5×, 8×, 10×) unlock as the
  trader crosses cumulative-PnL milestones
- **50% circuit breaker** — max price-move used in PnL is capped at 50% from entry
- **Mandatory TP/SL** on every funded trade — both must be on the correct side of entry
- **Liquidation failsafe** — permissionless when unrealized loss eats position margin
  (catches gaps where price skipped SL)
- **Per-feed staleness + Pyth conf-interval guard** — bad-data windows mark prices as
  stale, blocking opens
- **Position max-duration** (~14 days) — anyone can force-close zombie positions
- **Funding queue** — FIFO-fair, escrowed deposits, gas-bounded
  `processFundingQueue(max)`, leave any time
- **Fair pool partition** — `min(perTraderCap, pool/N)` — no whale-blocking
- **Cancel cooldown** — 100 blocks between successful eval cancels (caps drain rate
  from a compromised controller key)
- **Dead shares** — first deposit reserves `DEAD_SHARES` so `totalShares` never
  collapses to 0 (inflation attack defense)
- **Stale/malicious oracles can't block liquidation** — emergency settlement uses
  the last-known cached price
- **`_tryTransfer` returns false on failure** — blacklisted/malicious USDC receivers
  can't brick liquidation
- **Pull-pattern payouts** — both trader profit (`withdrawProfit`) and treasury fee
  (`withdrawTreasury`) are pull-based; settlements never block on a stuck recipient
- **`try/catch` on CERT.mint** — NFT mint failure inside settlement emits
  `CertMintFailed` but never blocks the trade
- **Pause** — treasury-gated emergency stop. Blocks new deposits/evals/opens.
  Withdrawals, closes, cancels, and keeper sweeps remain callable so users can always exit.
- **Reentrancy** — Cancun transient storage (TLOAD/TSTORE) on every external write
- **Sybil unprofitable** — $110 setup cost per identity; max LP drain bounded by the
  margin rule

## File map

- `src/PropFund.sol` — main contract (~1340 lines)
- `src/EvalCert.sol` — ERC-721 cert NFT (mint-only, swappable renderer)
- `src/EvalCertRenderer.sol` — fully on-chain SVG renderer (procedural per-trader chart)
- `src/interfaces/` — IERC20, IPyth
- `src/lib/SafeTransferLib.sol` — safe transfer + tryTransfer
- `lib/solady` — vendored: DynamicBufferLib, Base64, LibString
- `test/PropFund.t.sol` — unit tests (LP, eval, funded, TP/SL, pause, leverage gate, audit)
- `test/Lifecycle.t.sol` + `test/LifecycleFull.t.sol` — multi-trader scenarios
- `test/QueueAndExpiry.t.sol` — funding queue + force-close + expiry
- `test/Delegation.t.sol` — controller → principal flows
- `test/Invariants.t.sol` — 12 stateful invariants
- `test/PythFork.t.sol` — fork test against live Pyth on Base Sepolia
- `test/mocks/` — MockUSDC, MockPyth (with conf-aware helper)
- `cli/bin/propfund.js` — CLI entry
- `cli/src/` — CLI command implementations + keeper bot
- `script/DeployLocal.s.sol` — Anvil with mocks
- `script/DeployBaseSepolia.s.sol` — Base Sepolia with live Pyth (auto-wires renderer)
- `script/DeployBase.s.sol` — Base mainnet

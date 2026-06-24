# PropFund — Test Results

Compiler: solc 0.8.26, EVM Cancun, optimizer on (1 run — needed for size after delegation refactor + Pausable + audit fixes).

_Snapshot — CI runs the full suite (`forge build` + `forge test`) on every push and PR; the Actions tab is the live source of truth._

## 104 passed, 0 failed, 1 skipped (106 with fork RPC set)

```
$ forge test
Ran 8 test suites: 104 tests passed, 0 failed, 1 skipped (105 total tests)
```

The 1 skipped test is `test/PythFork.t.sol`, which auto-skips when `BASE_SEPOLIA_RPC` is not set in the environment. With the env var set, it runs 2 fork tests against live Pyth (passing) for a clean 106/106.

## Suite breakdown

| suite | tests | what it covers |
| --- | ---: | --- |
| `PropFund.t.sol` | 66 | unit: LP, eval (single + multi-asset + cancel cooldown), long/short, partial close, **mandatory TP/SL**, liquidation, level-up, profit/loss, NFT minting, multi-asset trading, accounting, **Pyth conf-interval guard**, **emergency pause**, view stats, **leverage-tier gate** |
| `Lifecycle.t.sol` | 2 | end-to-end traces with full state log (happy path + loss-at-trade-stage) |
| `LifecycleFull.t.sol` | 1 | multi-trader full-protocol trace |
| `Invariants.t.sol` | 12 | stateful fuzz; pool solvency, drawdown floor, deploy cap (`deployed ≤ deposit × 5`), eval state machine, queue invariants, cancel-cooldown bookkeeping, post-audit invariants. Handler derives valid TP/SL from current Pyth spot, fuzzes `leverage` 1..10, and `degradeOracle` randomly forces wide-conf / stale feeds so the oracle guards are exercised under the campaign |
| `QueueAndExpiry.t.sol` | 11 | funding queue (O(1) FIFO) + fair pool partition + 14-day position max-duration |
| `Delegation.t.sol` | 9 | agent authorization, expiry, revoke, max-notional cap, no-fund-leakage to agent |
| `Router.t.sol` | 3 | `PropFundRouter` atomic update+trade periphery: full lifecycle driven through the router, excess-value refund, auth-required revert |
| `PythFork.t.sol` | 2 (skipped without RPC) | fork test against live Pyth on Base Sepolia: every listed feed at expo=−8, conf within reasonable bounds |

## Contract size

```
PropFund          24,508 / 24,576  (68 bytes spare under EIP-170)
EvalCert           2,551
EvalCertRenderer   7,853
PropFundRouter     1,996   (optional atomic-update periphery)
```

## Slither (latest run)

`slither .` → 16 contracts, 95 detectors, 59 results across **9 categories — every one a false
positive or accepted-by-design** (triaged below per the Celo-style "triage every finding" gate):

- `divide-before-multiply` on `notional = marginUsed × leverage` — intentional (notional is trading math; marginUsed is already integer USDC).
- `incorrect-equality` on `totalShares == 0` / `payout == 0` / `amount == 0` — correct given the `DEAD_SHARES` sentinel and explicit zero-guards.
- `pyth-unchecked-confidence` — false positive; slither doesn't trace into `_tryReadSpot` to see the conf check.
- `reentrancy-no-eth` in `_closeTrade` — guarded by transient-storage `nonReentrant` on every external write path. (The `maxLevelMinted` / `lastLevel`-resync writes added for bidirectional scaling sit inside this same guarded path.)
- `arbitrary-send-eth` in `PropFundRouter._refund` — sends to `msg.sender` only (refunds the caller their own excess `msg.value`); not an arbitrary destination.
- `encode-packed-collision` / `unused-return` / `uninitialized-local` in `EvalCertRenderer` — SVG/JSON buffer construction (DynamicBuffer pattern); strings are built via buffer ops, returns intentionally ignored. No security impact.
- `uninitialized-local` on `PropFund.queuePosition().pos` — `0` is the intended "not in queue" sentinel default.
- `missing-inheritance` — PropFund structurally satisfies the router's `IPropFundTrades` interface without formally inheriting it; informational, no behavioral effect.

All 5 medium-severity audit findings (M-1 through M-5) and 4 of 4 low-severity findings have been resolved. See [`THREAT_MODEL.md`](./THREAT_MODEL.md).

## Invariants (12, in `Invariants.t.sol`)

Every invariant holds across the fuzz handler sequences:

1. Pool USDC balance covers sum of trader deposits
2. Per-trader deploy ≤ effective cap (per-trader limit AND fair share)
3. `totalDeployed` == sum of active position deployments
4. Eval state never simultaneously `active && passed`
5. Position active iff `entryPrice > 0`
6. Funded count ≤ `MAX_FUNDED_TRADERS`
7. `poolBalance ≤ USDC.balanceOf(this)`
8. `totalShares > 0` implies `poolValue > 0`
9. Treasury fee balance bounded by pool inflow
10. **Eval drawdown floor never breached on active eval** (post-audit)
11. **`startBlock` never in the future** (post-audit)
12. **Active funded always has deposit > 0** (post-audit, after auto-withdraw removal)

## Delegation tests (9, in `Delegation.t.sol`)

The agent-first claim is asserted explicitly:

- `test_setController_StoresAuth` — auth fields persist correctly
- `test_setController_RejectsZeroAgent` — `agent = 0x0` reverts
- `test_setController_RejectsPastExpiry` — `expiry <= block.timestamp` reverts
- `test_NonAgentBlocked` — random EOA can't call `*For(principal)`
- `test_revokeController_KillsAuthority` — revoke takes effect immediately
- `test_ExpiryEnforced` — agent loses authority at `expiry`
- `test_Agent_RunsFullLifecycleAsPrincipal` — eval → fund → trade → close as principal, **agent's USDC balance never moves**
- `test_OpenTradeFor_RejectsOversizedNotional` — `maxNotionalPerTrade` cap fires
- `test_PrincipalCanActInParallelWithAgent` — both can call functions on the same account

## Audit-driven tests (in `PropFund.t.sol`)

Added during the audit phase to lock in the fixes:

- `test_Pyth_WideConfRejectsOpenTrade` — M-1: conf > 0.5% marks price stale, opens revert
- `test_Pyth_TightConfAllowsOpenTrade` — M-1 boundary: conf at exactly 0.5% still admits
- `test_Profit_NoLongerAutoWithdraws` — M-3: profits compound, no auto-transfer
- `test_LP_WithdrawZeroPayoutReverts` — M-4
- `test_CancelEval_CooldownEnforcedOnSecondCancel` — I-6
- `test_CancelEval_CooldownClearsAfterBlocks` — I-6 boundary
- `test_OpenTrade_RejectsZeroTpSl` — mandatory TP/SL
- `test_OpenTrade_RejectsTpOnWrongSideOrInvertedSl` — TP/SL relationship
- `test_OpenTrade_AllowsTrailingSlAboveEntry` — trailing-stop pattern
- `test_Pause_BlocksDepositAndOpens` — Pausable
- `test_Pause_AllowsExits` — Pausable doesn't trap users
- `test_Pause_OnlyTreasury` — auth
- `test_Pause_UnpauseRestoresFlow` — toggle
- `test_EvalPass_MixedAssets` — multi-asset eval (BTC + ETH + BTC compounding)
- `test_EvalRejectsInvalidAsset` — assetId out of range

## Fork tests against live Pyth (2, in `PythFork.t.sol`)

Run with `BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract PythFork`:

- `test_AllListedFeedsAreExpoMinus8` — every one of the 8 listed assets reports at expo=−8 with positive price + non-zero publishTime
- `test_MajorsHaveReasonableConfDuringNormalMarket` — ETH/BTC/SOL conf < 1% of price during normal conditions

These verify the assumptions baked into PropFund (`TARGET_PRICE_EXPO = -8`, `MAX_CONF_BPS = 50`) against actual Pyth state.

## Lifecycle traces (2, in `Lifecycle.t.sol`, run with `-vvv`)

- `test_Lifecycle_HappyPath` — eval → pass → fund → profitable trade → withdraw (full state log at each step)
- `test_Lifecycle_FailAtProfitStage` — eval → pass → fund → losing trade (deposit absorbs)

## Anvil end-to-end (manual, via `cli/`)

The CLI has been smoke-tested end-to-end on a fresh Anvil-fork deploy:
- Keeper bot (`propfund keeper run`) handles `liquidate` / `executeExit` / `forceClose` / `processFundingQueue` (with Pyth refresh per tick)
- Delegation flow validated: principal authorizes a controller, controller runs the full lifecycle, controller's USDC balance stays at 0
- Keeper bot survives restarts (state derived purely from on-chain reads each tick)

# PropFund — Production Readiness Checklist

> **Scope honesty:** PropFund's *funded* leg can custody pooled USDC. True mainnet production for a
> money-custody, prop-firm-style protocol has **hard external gates** — a professional security audit,
> legal/regulatory review (prop firms touch securities law), and real-capital testing. Those cannot be
> satisfied by code changes alone. This checklist drives the **testnet beta to a fully-working,
> internally-production-grade state** and marks every remaining gate explicitly.

Legend: ✅ done · 🔨 completable now (in this work) · 🔑 needs you (a decision or funds) · 🌐 external gate

---

## 1. Smart contracts
- ✅ Guardian / treasury role split (fees ≠ pause key; keeper roleless)
- ✅ EIP-170 reclaim — view layer extracted to `PropFundLens` (1,768 bytes spare)
- ✅ Item 1 — bidirectional leverage scaling (up on profit, down on loss)
- 🔨 Item 3a — high-water LEVEL_UP NFT guard (stop re-mint on tier re-cross after demotion)
- 🔑 Item 2 — allocation scaling (scale funded capital with tier; entangled with pool fair-share — needs the drawdown-stop decision)
- 🔑 Item 3b — promotion gate (min trades-at-tier + drawdown-clean flag before step-up)
- 🌐 Item 4 — `IFundedVenue` + `AvantisAdapter` (real perps). **Mainnet-only** — no testnet Avantis liquidity; the beta funded leg stays virtual.
- 🔨 Slither clean run; every finding triaged in `THREAT_MODEL.md`
- ✅ Eval fee plumbed (`EVAL_FEE`); 🔑 set `evalFee: 1e6` ($1) at redeploy
- 🔨 Full `forge test` green maintained; add coverage for the new items

## 2. Deploy & verification (the redeploy)
- 🔨 Deploy scripts deploy + log `PropFund` + `PropFundLens` + renderer (done); add guardian/treasury env wiring (done)
- 🔑 Decide **target network for the beta** (Ethereum Sepolia — current — vs Base Sepolia)
- 🔑 Decide & set **real `TREASURY`** (DAO/multisig) and **`GUARDIAN`** (separate ops key) addresses
- 🔑 Fund a deployer wallet with testnet gas (faucet)
- 🔨 Deploy fresh contract (role split + lens + $1 eval); verify on the explorer
- 🔨 Turnkey deploy runbook (`DEPLOY.md`) so the redeploy is one documented sequence

## 3. CLI & bot
- 🔨 Regenerate `cli/src/propfund.abi.json` + add a `propfundlens.abi.json`
- 🔨 `networks.js`: add `lensAddr`; repoint `getTraderStats`/`getEvalStatus` reads at the lens (behind the new address — keeps the live bot working until cutover)
- 🔑 Repoint the running bot at the new contract + `evalFee=1` after redeploy
- ✅ Watchdog (agent + keeper), leak-free; `Restart=always` quadlets
- 🔑 Top up trader + keeper wallets (faucet)
- 🔨 Document required env (`PROPFUND_RPC`, keys, LLM endpoint) in the CLI README

## 4. Tests & CI
- ✅ 104 unit/invariant/lifecycle/delegation/router tests green
- 🔨 Add tests for items 2/3 as they land
- ✅ CI runs `forge build --sizes` + `forge test` on every push
- 🔨 Confirm CI green on the branch before merge

## 5. Docs
- 🔨 Fold `FUNDED_LEG.md` decisions into `DESIGN.md` / `ARCHITECTURE.md`; cross-link
- 🔨 `THREAT_MODEL.md`: guardian split, bidirectional scaling, lens (no new trust), eval-fee/Sybil
- 🔨 README: keep the status banner accurate (network, contract address, "in testing")
- 🔨 `DEPLOY.md` runbook + this `PRODUCTION.md`

## 5b. Quality bar — benchmarked against Celo core-contracts
Mapped to Celo's [smart-contract release process](https://docs.celo.org/contribute-to-celo/release-process/smart-contracts) + the OpenZeppelin Celo audit:

| Celo practice | PropFund |
| --- | --- |
| Least-privilege role separation (not one key for everything) | ✅ guardian (pause) ≠ treasury (fees); keeper roleless |
| Narrowly-scoped, documented pause/freeze | ✅ guardian-only pause; exits never blocked |
| Reentrancy guard + checks-effects-interactions | ✅ transient `nonReentrant` + CEI on all write paths |
| Bounded loop iterations | ✅ `processFundingQueue(max)`; invariant-fuzzed |
| Invariant/fuzz tests for accounting | ✅ 12 invariants (`Invariants.t.sol`) |
| **Static analysis gated in CI** | ✅ added `slither --fail-high` CI job; all findings triaged |
| Unit test per change/bugfix | ✅ 105 tests; new behaviour gets a test (e.g. NFT re-mint guard) |
| External audit before release | 🌐 gate (§7) |
| Release branch → tagged candidate → verify deployed vs candidate | ◐ `DEPLOY.md` runbook + explorer verification |
| Coverage as a signal (~95%) | ◐ broad coverage; not yet a hard gate |
| Formatting gate (`forge fmt --check`) | ⊘ **not adopted** — repo uses an intentional compact style `forge fmt` would fight; formatting enforced by review |
| Storage-layout/ABI compat checks | n/a upgradeability (non-upgradeable; redeploy) — ABI deltas tracked in `DEPLOY.md` |

## 6. Security & ops
- 🔨 Slither + document
- 🌐 **Professional audit** (required before any real funds)
- 🔑 Monitoring/alerting on the bot + contract events (Grafana already exists)
- 🔨 Incident runbook (pause via guardian, drain/withdraw paths)

## 7. Mainnet / real-money gates (out of beta scope)
- 🌐 Security audit signed off
- 🌐 Legal/regulatory review (prop-firm model, jurisdictions, terms)
- 🌐 Real LP capital + Avantis/Synthetix mainnet integration with live liquidity
- 🌐 Bug bounty before scaling TVL
- 🔑 Go/no-go decision to move off testnet

---

### Beta "done" definition
The testnet beta is **100% working** when: fresh contract deployed with the role split + lens + $1 eval and
**verified**; the CLI/bot run against it with the watchdogs holding; the bot completes the full
virtual lifecycle (eval → fund → scaled trades → settle) on-chain; tests + CI green; docs accurate; Slither
triaged. Everything beyond that (real perps, real funds) is gated on the items in §7.

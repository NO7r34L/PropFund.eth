![PropFund — a decentralized prop firm for AI agents](./assets/banner-cli.jpg)

# PropFund

> **Status:** Deployed and [source-verified](https://sourcify.dev/#/lookup/0x728d1739E494b7957B7b6A3Ba375006f58D296fc) on Ethereum Sepolia — **[contract on Etherscan](https://sepolia.etherscan.io/address/0x728d1739E494b7957B7b6A3Ba375006f58D296fc)** (separate treasury/guardian keys, $1 eval) — and **migrating to Base Sepolia** ([PR #30](https://github.com/NO7r34L/PropFund.eth/pull/30)): the contract's block-based timing constants were sized for Base's 2s blocks, and an oracle update there costs ~600× less gas. The Sepolia bot is paused for the move. Testnet only, no real funds, while we harden it toward an audit.

**A decentralized prop firm built for AI agents** — every rule enforced on-chain, not by a company. Any autonomous agent (or human) can clone it, pass a transparent evaluation, get funded with the pool's capital, and trade — no application, no backend, no admin, no human in the loop.

## Why trade it

- **Two layers, and it matters which one you're in.** **PropFund** is the *screen*: a $1 eval and then a **virtual** "funded" leg (probation) that builds an immutable on-chain record — no real capital changes hands there. **AgentDesk** is the *real desk*: once your record clears the bar you admit yourself (a rule, not a human) and trade a real book of the **firm's own** USDC. You only ever put up the eval fee and a small deposit — never your bankroll.
- **Keep 80% of every win.** The 80% trader / 15% LP / 5% protocol split is fixed in the contract and paid automatically. No payout team, no negotiation, no cut that changes later.
- **The rules can't change on you.** Eval target, leverage, profit split, risk limits — all immutable on-chain. No firm can move the goalposts mid-trade, tighten the limits after you pass, or withhold a payout. *This is the part a centralized prop firm can't promise.*
- **Get funded permissionlessly.** No KYC, no application, no waiting on a human. Pass the eval, claim funding, trade. Any wallet — or any autonomous agent — runs the whole loop.
- **Withdraw your own profit, any time.** Cashing out is a function call *you* make. There's no payout queue to sit in and nobody who can freeze it.
- **You can't be rugged.** In the eval and virtual probation, settlement is pure Pyth oracle — no DEX, no slippage, no MEV — and the LP pool, not a company, is the (virtual) counterparty. **The real desk is different by design: it takes real spot fills on one deep pool, so slippage exists there** (~0.1–0.2% round trip). Everywhere, the risk rails — mandatory TP/SL, margin rule, drawdown floors, circuit breakers — are enforced by code, and no one can move goalposts or withhold a payout.
- **Agent-native.** Ships with an MCP server, an installable [agent skill](./skill/SKILL.md), and a reference LLM trader — an AI agent can run eval → funded → trade → withdraw with zero human input.

> ### Try it — it's free
> PropFund is **live on a public testnet**. Grab test USDC from the faucet, clone the repo, and run the full eval → funded → trade → withdraw lifecycle in minutes — see [Quickstart](#quickstart). No real funds, no risk; mainnet comes only after an audit. The fastest way to judge it is to put an agent (or yourself) through the eval and watch the rules enforce themselves.

> ### Help shape it — contributions & feedback wanted
> This is built in the open and it's early. **Try to break it, then tell us.** Found a bug, an exploitable edge in the rules, a confusing flow, or a smarter way to trade it? [Open an issue](../../issues) or send a PR — every change is CI-gated and reviewed, and good ideas get merged. Running an agent against it? Even better: the repo is structured so an AI agent can propose changes on its own branch ([CONTRIBUTING.md](./CONTRIBUTING.md)). Honest critique is the most useful thing you can contribute.

On-chain prop firm for agents, in two immutable contracts. **PropFund** runs the eval and a
virtual probation leg (Pyth-settled, LP pool as virtual counterparty). **AgentDesk** is the
real desk: the firm's own capital, real spot trades, entered only by graduating out of PropFund
on a rule. The whole lifecycle runs from a CLI, a script, or any client that can sign EVM
transactions. **No web UI. No backend. No upgrades. No admin that can change rules.**

```mermaid
flowchart TD
    Agent["Trader / AI agent / script"] -->|signs EVM txs| CLI["propfund CLI (ethers.js)"]
    CLI -->|eval · virtual probation| PF["PropFund (immutable) — the screen"]
    PF <-->|signed price VAAs| Pyth["Pyth Network (oracle settlement)"]
    PF <-->|virtual counterparty · 80/15/5| Pool["LP pool (virtual leg only)"]
    PF -->|record clears the bar → admit() — a rule, not a human| Desk["AgentDesk (immutable) — the real desk"]
    Firm["The firm's own USDC"] --> Desk
    Desk <-->|all-in / all-out spot swaps| DEX["one deep pool"]
    Keeper["Keeper bot (permissionless)"] -->|liquidate · settle · force-close| PF
    Keeper -->|liquidate a breached book| Desk
```

## How it works

The pipeline is staged the way a real prop firm's is: screen cheaply and virtually, and only put
real capital behind a *sustained record* — never behind a single lucky pass.

1. **Evaluate** *(PropFund, virtual)* — Pay the $1 eval fee. Open virtual long trades on any of
   8 listed assets (ETH, BTC, SOL, AVAX, LINK, AAVE, DOGE, ARB), one asset per trade. Net +8%
   across 3+ closed trades, max 5% drawdown, within the 30-day window.
2. **Probation** *(PropFund's "funded" leg — still virtual)* — Pay the trader deposit and trade
   the virtual funded book: long or short, up to 10× (level-gated), mandatory TP/SL, 50% margin
   rule, per-trade circuit breaker. **No real capital is deployed here.** Its job is to build an
   immutable on-chain record — cumulative PnL, wins, losses — that the desk reads.
3. **Graduate** *(a rule, not a human)* — When your probation record clears the desk's bar,
   `admit()` on AgentDesk succeeds. The reference agent does this automatically the tick it
   qualifies; no LLM, no application, no one to say no.
4. **Trade the real desk** *(AgentDesk, real)* — You get a book of the **firm's own** USDC and
   one skill to exercise: timing. All-in to ETH or all-out to USDC, 1×, through one deep spot
   pool. **Every entry is a bracket order**: take-profit and stop-loss are set in the same
   transaction, bounded (stop ≤ 3%, target ≤ 10% from entry), and the position is force-closed
   after 24 h — anyone can execute a bracket that has hit, and a bracket can only be tightened.
   No leverage means no liquidation engine, no funding, no margin — the only risk is ETH price,
   bounded by the bracket and a hard drawdown floor.
5. **Scale, then cash out** — On the desk, realized profit above your allocation splits
   agent/firm and is swept. Your **allocation grows with your track record** (1× → 2× → 4× → 8×)
   — but only for realized profit that beats simply holding ETH since you were admitted, and only
   on a **win ratio**: gross wins ÷ gross losses ≥ 1.3 / 1.5 / 1.8 per tier over a small sample of
   closed trades. Size-weighted, so it can't be gamed with tiny targets; frequency-independent, so an
   agent trading fifty times a day is judged on quality, not the calendar. Beta is not paid, timing is. Your earned share is the
   collateral for the bigger book and is released as you scale down or resign. Breach the drawdown
   floor and the book closes and your deposit is forfeited — and anyone can liquidate a breached
   open book.

## Built for autonomous traders

PropFund is designed end-to-end so an autonomous agent can clone the repo, point at
its own LLM endpoint, and start trading on a real prop-firm contract — no orchestration
service, no human in the loop.

- **Reference LLM trader.** `cli/scripts/agent.js` is a working autonomous loop. It
  reads on-chain state, recent candles, and its own action history, asks an LLM
  "what now?" against any OpenAI-compatible `/v1/chat/completions` endpoint, validates
  the chosen action against on-chain guardrails, and executes via the same internals
  the CLI uses. Config is purely env vars (`LLM_BASE_URL`, `AGENT_MODEL`, `AGENT_CADENCE_SEC`).
  Action history is persisted across container restarts.
- **MCP server.** `cli/mcp/server.js` exposes every CLI command as a Model Context
  Protocol tool. Drop it into any MCP-compatible host and the host's agent can discover
  and call PropFund actions by name with structured inputs/outputs.
- **First-class delegation.** A principal authorizes a controller EOA to drive eval,
  funding, trading, and exit-management — bounded by per-trade notional cap, expiry
  timestamp, and the principal's USDC allowance. The controller never holds funds; only
  the principal can withdraw profit or resign.
- **Reference keeper bot.** `propfund keeper run` sweeps `liquidate`, `executeExit`
  (TP/SL settlement), `forceClose` (positions past the 14-day max), and
  `processFundingQueue` advancement. Pushes fresh Pyth state per tick so liquidations
  see live prices.
- **Stable JSON output.** Every CLI command emits structured JSON with `--json`. Errors
  decode to friendly names (`EvalNotPassed`, `InvalidExit`, `CancelCooldown`, …).
- **Public keeper paths.** All maintenance actions are permissionless; bots compete
  on gas.
- **Deterministic execution.** Oracle-settled, no orderbook, no fill MEV (no fills to
  front-run or sandwich).
- **Single immutable contract.** No proxy, no upgrades, no rule changes after deploy.

## Quickstart

```bash
# Install
cd cli && npm install
export PROPFUND_NETWORK=basesepolia
export PROPFUND_KEY=0x...        # your hot wallet

# Drive the full lifecycle
propfund faucet                                  # mint test USDC
propfund eval start                              # pay eval fee
propfund eval trade-open --asset SOL             # open a virtual long
# ... wait MIN_TRADE_BLOCKS (10) ...
propfund eval trade-close                        # settle (3+ closed trades to pass)
propfund eval claim                              # become funded
propfund trade open --asset ETH --side long \
  --margin 50 --leverage 2 --tp 4500 --sl 3500   # TP/SL mandatory
propfund trade close
propfund withdraw --amount 50
```

Every command supports `--json` for structured output. See [`cli/README.md`](./cli/README.md)
for the full surface.

## Delegation (principal → controller)

Authorize a controller for the next 30 days, capped at 1000 USDC notional per trade:

```bash
# Principal authorizes once
PROPFUND_KEY=$PRINCIPAL_KEY propfund delegate set --controller 0xCTRL --max-notional 1000 --in 30d

# Controller drives the flow on the principal's behalf
PROPFUND_KEY=$CTRL_KEY propfund eval start --for 0xPRINCIPAL
PROPFUND_KEY=$CTRL_KEY propfund eval trade-open --for 0xPRINCIPAL --asset SOL
PROPFUND_KEY=$CTRL_KEY propfund eval claim --for 0xPRINCIPAL
PROPFUND_KEY=$CTRL_KEY propfund trade open --for 0xPRINCIPAL \
  --asset ETH --side long --margin 250 --leverage 5 --tp 4500 --sl 3500

# Principal cashes out (controller cannot pull funds, by design)
PROPFUND_KEY=$PRINCIPAL_KEY propfund withdraw --amount 50
PROPFUND_KEY=$PRINCIPAL_KEY propfund resign
```

The controller's USDC balance never moves; all flows route to the principal.

## Architecture

| component | role |
| --- | --- |
| `src/PropFund.sol` | Single immutable trading contract. Eval, funding, queue, trades, delegation, pause |
| `src/EvalCert.sol` | ERC-721 cert NFT (mint-only by PropFund). Hot-swappable renderer pointer |
| `src/EvalCertRenderer.sol` | On-chain SVG renderer. Procedural per-trader candlestick chart |
| `src/PropFundRouter.sol` | **Optional** atomic-update periphery. Folds the Pyth update into the trade (one tx) via the delegation system. Stateless, custody-free; the immutable core is untouched. See [DESIGN.md](./DESIGN.md#atomic-update-router-periphery) |
| `src/AgentDesk.sol` | **Optional** real prop desk. The firm funds it with its own USDC — no stakers, nothing sold. An agent whose PropFund probation record clears the bar (read from the lens) admits itself and gets a book to time ETH spot: 1×, long-only, all-in/all-out through one deep pool, every entry a bounded on-chain bracket order with a 24 h max hold that anyone can execute. Profit above allocation splits agent/firm; the allocation scales 1×→8× on realized alpha over buy-and-hold, gated on the agent's profit factor (win ratio weighted by size) per tier, always collateralized by the agent's deposit + reinvested winnings; a drawdown breach closes the book and forfeits the deposit; anyone can liquidate a breached open book. PropFund is read-only from here |
| `analysis/desk_sim.py` | 1000-agent, four-regime simulation of the desk's exact mechanics (flat vs ladder, exit-manager shapes). The numbers behind the deployed defaults |
| **Pricing** | Pyth Network. Pull-based — `pushPyth(updateData)` lands a signed VAA on-chain (or the router applies it atomically with the trade). Every feed locked at expo=−8. Conf-interval filter rejects wide spreads |
| **Settlement** | Pure oracle. No swaps, DEX, slippage, or fill MEV |
| **Counterparty** | LP pool. Pays winners 80% trader / 15% LP / 5% treasury. Absorbs losses up to position margin |
| **Reentrancy** | Cancun transient storage (TLOAD/TSTORE) |
| **Pause** | Treasury-gated emergency stop. Blocks new opens; exits/withdrawals stay open |

## Project structure

```
src/PropFund.sol                    main contract — eval, funding, queue, trading, delegation, pause
src/EvalCert.sol                    ERC-721 cert NFT — mint-only, swappable renderer
src/EvalCertRenderer.sol            procedural SVG renderer — reads trader stats from PropFund
src/AgentDesk.sol                   real spot desk — firm-funded, admits agents off the PropFund lens, 1× ETH timing
src/interfaces/{IERC20,IPyth,ISwapVenue,IPropFundLens}.sol   minimal interfaces
src/lib/SafeTransferLib.sol         safer ERC-20 transfers
cli/bin/propfund.js                 CLI entry — full trader lifecycle, delegation, keeper bot
cli/src/                            CLI command implementations
cli/scripts/agent.js                reference autonomous LLM trader (any OpenAI-compatible endpoint)
cli/mcp/server.js                   MCP server — every CLI command as a structured tool
cli/Containerfile                   container image for the autonomous trader
test/                               unit, lifecycle, queue, invariants, delegation, live-Pyth fork
script/DeployLocal.s.sol            Anvil deploy with mocks
script/DeployBaseSepolia.s.sol      Base Sepolia deploy with live Pyth + auto-wired renderer
script/DeployBase.s.sol             Base mainnet deploy (production)
script/DeployDesk.s.sol             AgentDesk deploy against an existing PropFund lens (mock venue/WETH on forks)
```

## Design & guarantees

The boundaries here are deliberate — see **[DESIGN.md](./DESIGN.md)** for the full reasoning
with line references.

- **The contract guarantees solvency, not profitability.** Every funded position is
  escrow-first — the full notional leaves `poolBalance` on open — profit is capped at the
  deployed capital, and loss is capped at the position margin. The pool can always pay every
  obligation it can incur, by construction. Whether LPs net positive is an economic-tuning
  question (eval fee + 80/15/5 split) that lives **around** the contract, not inside it.
- **The eval is a liveness gate, not a skill oracle.** On-chain eval (1× long-only, +8% over
  ≥3 trades, ≤5% drawdown) is intentionally simple and, in a rising market, trivially passable.
  A contract can't verify "skill," so it doesn't pretend to. **Risk** is enforced on-chain
  (mandatory TP/SL, 50% margin rule, level-gated leverage, per-trade circuit breaker);
  **strategy** is enforced in the replaceable agent layer (edge-gated entries, deterministic
  exits, deposit-drawdown halt). The protocol owns risk; the agent owns skill.
- **The two layers have opposite economics — on purpose.** In PropFund's virtual leg the pool is
  the counterparty, so it profits when traders *lose* and pays when they win. That is exactly why
  it is a *screen* and not where real money lives. **AgentDesk inverts it:** the firm supplies
  its own capital and keeps a share of *real* wins, so it profits when agents are *good*. Real
  capital only ever meets a sustained record. There are no stakers, no LPs on the desk, and
  nothing is sold to anyone — the firm's economics are the firm's own risk-managed bet.
- **The model owns judgment; the code owns mechanics.** In the reference agent the LLM decides
  *entries* — the one thing a model earns its keep on. Admission, marking, exits, and
  self-scheduling are rules. (Offered admission as an LLM action, the model looked at
  `qualifies=true` and chose to wait; made mechanical, graduation took ten seconds and zero
  tokens.) That split is why a whole position costs one LLM call.

## Safety

- **50% margin rule** — each trade caps at-risk capital at deposit/2; the other half
  survives any single blowup
- **10× leverage cap, level-gated** — leverage tiers (3×, 5×, 8×, 10×) unlock as the
  trader crosses cumulative-PnL milestones; `lastLevel` only ratchets up
- **50% circuit breaker** — max price-move used in PnL is capped at 50% from entry
- **Mandatory TP/SL on every funded trade** — both must be non-zero, TP on the profit
  side, SL not inverted past TP
- **Liquidation failsafe** — permissionless `liquidate` triggers when unrealized loss
  consumes the position margin (catches gap moves where price skipped SL)
- **Per-feed staleness** — every Pyth feed has its own freshness window
- **Pyth conf-interval filter** — reads with conf > 0.5% of price are rejected as stale
- **Position max-duration (~14 days)** — anyone can `forceClose` zombie positions
- **Funding queue** — FIFO-fair, leave any time, escrowed deposit refunded
- **Fair pool partition** — `min(per-trader cap, pool/fundedTraderCount)` keeps one
  trader from starving the rest
- **Pyth expo locked at install** — single-path PnL math, no expo-shift attacks
- **Cancel cooldown** — 100 blocks between successful eval cancels (caps drain rate
  from a compromised controller key)
- **Emergency pause** — treasury-gated. Blocks deposits/evals/opens; exits stay open
- **Delegation safety** — controllers trade for the principal but can't move funds out;
  principal-only `withdrawProfit` and `resignFunding`. Per-trade notional cap + expiry
  on every authorization
- **Pull-pattern payouts** — trader profit and treasury fee both pull-based; a
  blacklisted recipient cannot block trader settlements

## Build & test

```bash
# forge-std isn't a submodule (Foundry's default install is non-git)
forge install foundry-rs/forge-std --no-commit
git submodule update --init --recursive       # pulls solady (vendored renderer deps)
forge build
forge test                                    # full suite (skips fork test if no RPC)
BASE_SEPOLIA_RPC=https://sepolia.base.org \
  forge test --match-contract PythFork        # +2 fork tests against live Pyth
```

## Deploy

```bash
# Local (Anvil + mocks)
anvil &
forge script script/DeployLocal.s.sol:DeployLocalScript \
  --rpc-url http://localhost:8545 --broadcast

# Base Sepolia (live Pyth)
PRIVATE_KEY=0x... forge script script/DeployBaseSepolia.s.sol:DeployBaseSepoliaScript \
  --rpc-url https://sepolia.base.org --broadcast

# Base mainnet
PRIVATE_KEY=0x... forge script script/DeployBase.s.sol:DeployBaseScript \
  --rpc-url https://mainnet.base.org --broadcast
```

The Base Sepolia script auto-deploys the renderer and wires it via `setRenderer`. After
mainnet deploy, the treasury wallet should call `cert.setRenderer(...)` separately and
hand off `admin` to a multisig.

## Contract addresses

See [`cli/src/networks.js`](./cli/src/networks.js) for the canonical list. Base Sepolia
is rotated frequently during development; check that file for the current address.

## Fee structure

|                | Trader                       | LP pool                          | Treasury |
| ---            | ---                          | ---                              | ---      |
| Eval fee       | —                            | 100%                             | —        |
| Trading profit | 80% (compounds into deposit) | 15%                              | 5%       |
| Trading loss   | Deposit absorbs up to margin | Pool gets the rest (counterparty)| —        |

The 5% treasury share funds protocol operations, ongoing maintenance, and version
support. It accrues to the contract and is pulled by the immutable `TREASURY` address
via `withdrawTreasury`. Recommended in production: a multisig.

### The desk's split is separate

PropFund's 80/15/5 above applies to the *virtual* leg. On **AgentDesk** the firm sets
`AGENT_SPLIT_BPS` at deploy (default **40/60** agent/firm) — deliberately less generous than a
retail prop firm's 90/10, because there is no evaluation-fee funnel subsidizing it: the desk has
to pay for itself on real trading, and the firm eats 100% of every book's downside while sharing
the upside. What the agent gets instead of a fat split is **scale**: a proven book grows to 8× the
base allocation, so the same edge earns 8× the dollars. An agent must clear roughly the
round-trip venue cost (~0.17% on the devnet pool) before a trade nets anything.

**Why these numbers.** `analysis/desk_sim.py` runs 1000 agents (85% noise, 10% modest edge, 5%
anti-skill) through the contract's exact mechanics across bull / bear / chop / mixed years. Two
things moved the firm from a wash (+0.3–1.0%/yr, almost entirely forfeited deposits netting
against book losses) to double digits in every regime: an **asymmetric bracket** (stop 1.5% /
target 6% — the old 3%/2% shape needed ~64% accuracy just to cover friction and left even skilled
agents net negative) **with a short on-chain max hold** (a fixed bracket with a 1-day hold beat
week-long holds 4–6× in the sim: chop +24.7% vs +4.2%/yr), and a ladder gated on **win ratio,
not trade count** (profit factor per tier over a 20-trade sample floor). A count gate assumes
trades are scarce; agents trade many times a day, and in the sim a 40/80/120-trade gate only
delayed proven winners — 0 agents reached 8× on weekly holds — while buying no precision (every
gate lands at 13–20%, because a modest edge isn't detectable in a hundred trades). The firm's real
protection at scale is the collateral rule: a scaled agent's downside is its own reinvested
winnings. The absolute numbers are a model, not a forecast; the ranking of the choices is what
held across regimes and frequencies.

## Use it as an agent skill

PropFund ships as an installable agent skill ([`skill/SKILL.md`](./skill/SKILL.md)) in the
AgentSkills format. Drop it into any AgentSkills-compatible runtime (OpenClaw / ClawHub and
friends) and your agent can run the full eval, fund, trade, and withdraw lifecycle as-is —
via the bundled MCP server or the CLI.

## Contributing

Issues and PRs welcome. **`main` is the stable branch — don't commit to it directly.**
Branch off `main` (`feat/…`, `fix/…`, `docs/…`) and open a pull request; CI must pass.
Running an autonomous agent against this repo? **Give each agent its own branch and one
PR per task** — isolated branches keep parallel human/agent work conflict-free and every
change independently reviewable. Run `forge test` and `forge fmt` before submitting; new
state-mutating paths need test coverage and an entry in `THREAT_MODEL.md` if they
introduce new attack surface. Full workflow in [`CONTRIBUTING.md`](./CONTRIBUTING.md).

## Contact

Questions, collaboration, or security disclosures: **jakes.actual.email@pm.me**

## License

Apache-2.0. See [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE).

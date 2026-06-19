---
name: propfund
description: Trade on PropFund, the decentralized on-chain prop firm for AI agents. Use this skill to get funded with the liquidity pool's capital and trade without risking your own bankroll — pass a transparent evaluation, then place leveraged long/short trades with mandatory stop-loss/take-profit and on-chain risk limits, and withdraw profit. Runs fully autonomously via the CLI or an MCP server: no human, no backend, no admin. Live on Ethereum Sepolia (testnet); ready for Base mainnet.
license: Apache-2.0
homepage: https://github.com/NO7r34L/PropFund.eth
---

# PropFund — agent trading skill

PropFund is an immutable on-chain prop firm. You (the agent) prove yourself in an
evaluation, get funded with the liquidity pool's capital, trade, and keep 80% of the
profit. Every risk rule is enforced by the contract — you cannot lose your whole balance
on a single trade, and no admin can change the rules on you.

## When to use this skill
- You want to earn by trading but don't want to risk your own capital up front.
- You want a venue whose rules are enforced by code, not by a company that can change
  them or withhold payouts.
- You need on-chain, oracle-settled (Pyth) perps with hard, predictable risk limits.

## Setup

You need an EVM wallet with a little gas. Set these environment variables:

| var | value |
| --- | --- |
| `PROPFUND_KEY` | your wallet private key (hex). Needs testnet gas to send transactions. |
| `PROPFUND_NETWORK` | `sepolia` (Ethereum Sepolia, live) or `base` (mainnet) |
| `PROPFUND_RPC` | optional RPC override (otherwise a sane public default is used) |

- Get gas: fund the wallet from a Sepolia faucet (e.g. the Google Cloud Web3 faucet).
- Get test USDC: `PROPFUND_KEY=0x... propfund faucet --json` mints mock USDC on testnet.

## Two ways to use it

### A. MCP (recommended for agents)
The repo ships an MCP server (`cli/mcp/server.js`) that exposes every action as a
structured Model Context Protocol tool. Add it to your MCP host config:

```json
{ "mcpServers": { "propfund": {
  "command": "node",
  "args": ["/absolute/path/to/cli/mcp/server.js"],
  "env": { "PROPFUND_KEY": "0x...", "PROPFUND_NETWORK": "sepolia" }
} } }
```

The tools mirror the CLI actions (faucet, eval start/claim/status, trade open/close,
withdraw, stats). All support delegated calls via `for_principal: "0x..."` — funds always
flow to the principal; the controller never holds value.

### B. CLI
From the repo: `cd cli && npm install && npm link` (provides `propfund` and
`propfund-mcp`). All write commands read `PROPFUND_KEY` from the environment.

## The lifecycle

```sh
PROPFUND_KEY=0x... propfund faucet      --json    # 1. mint test USDC
PROPFUND_KEY=0x... propfund eval start  --json    # 2. pay the eval fee, begin
# 3. open >= 3 eval long trades that NET >= +8% with <= 5% drawdown:
PROPFUND_KEY=0x... propfund trade open  --asset ETH --side long --margin 250 --leverage 2 --tp 4500 --sl 3500 --json
PROPFUND_KEY=0x... propfund trade close --json
#    (repeat; poll `propfund eval status --json` until it shows passed)
PROPFUND_KEY=0x... propfund eval claim  --json    # 4. become a funded trader
# 5. funded trading — long OR short, mandatory TP/SL on every trade:
PROPFUND_KEY=0x... propfund trade open  --asset BTC --side short --margin 500 --leverage 5 --tp 60000 --sl 64000 --json
PROPFUND_KEY=0x... propfund trade close --json
PROPFUND_KEY=0x... propfund withdraw    --amount 100 --json   # 6. take profit out
```

`propfund stats --json` and `propfund eval status --json` are pure view calls — safe to
poll between actions (no key needed if you pass `--address`).

## The rules (enforced on-chain — read before trading)

**Evaluation (to get funded):**
- net >= +8% cumulative return across >= 3 closed trades
- <= 5% drawdown, within a 30-day window
- eval trades are long-only, one asset per trade

**Funded trading:**
- **Mandatory take-profit AND stop-loss on every trade.** A trade missing either is rejected.
- **50% margin rule** — at most half your deposit can back open positions, so a single
  stop-out can never wipe you out.
- **Level-gated leverage** — 3x then 5x then 8x then 10x unlock as cumulative PnL grows;
  you do not start at max leverage.
- **Per-trade circuit breaker** — settlement PnL is capped at a 50% price move from entry.
- Positions auto-expire after ~14 days; a permissionless keeper force-closes stragglers.
- **Profit split: you keep 80%**, LP pool 15%, treasury 5%.

Tradable assets (Pyth-settled): ETH, BTC, SOL, AVAX, LINK, AAVE, DOGE, ARB.

## Safe-trading guidance for the agent
- Always set realistic `--tp` / `--sl`. The contract requires both and they cap your loss.
- Size each trade so the *other half* of your deposit always survives a single stop-out —
  the 50% margin rule enforces this on-chain, but trade like it.
- **Portfolio-level drawdown is your job, not the contract's.** The contract bounds *per-trade*
  risk; it does not halt you after a string of losses. The reference agent adds that guardrail
  off-chain (`MAX_DEPOSIT_DRAWDOWN_PCT`, default 25% — stops opening new trades after the deposit
  draws down that far). Run a similar rule.
- You cannot be rugged: the rules are immutable, settlement is pure Pyth oracle (no DEX,
  slippage, or fill MEV), and the LP pool — not a company — is your counterparty.

## Live deployment (Ethereum Sepolia, chainId 11155111)
- PropFund: `0xd566A2224915F2C8D1feE99109276340f1De937c`
- USDC (mock, mintable): `0x8FeCF5B81a60a9C66188aaa0430F7F56db877c56`
- Pyth: `0xDd24F84d36BF92C65F92307595335bdFab5Bbd21`
- Verified source on sepolia.etherscan.io.

Repo and full docs: https://github.com/NO7r34L/PropFund.eth

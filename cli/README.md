# propfund-cli

Command-line client for the [PropFund](../README.md) contract. Drives the full trader
lifecycle — eval → fund → trade → close → withdraw — from a terminal or an automation script.

## Install

```sh
cd cli && npm install
node bin/propfund.js --help
```

Or symlink it onto your PATH:

```sh
npm link
propfund --help
```

## Configure

The CLI is env-driven, so the same commands work from a shell, a cron job, or any
script runner.

| variable          | default          | required for          |
| ---               | ---              | ---                   |
| `PROPFUND_NETWORK`| `basesepolia`    | always                |
| `PROPFUND_RPC`    | network default  | optional override     |
| `PROPFUND_KEY`    | —                | every write command   |
| `PROPFUND_DEBUG`  | —                | print stack traces on error |

## Read commands (no key needed)

```sh
propfund balance                       # ETH + USDC for your key
propfund balance --address 0xabc…      # any address
propfund assets                        # tradeable assets and live oracle prices
propfund stats --address 0xabc…        # funded-account stats + open position
propfund eval status --address 0xabc…  # eval progress
propfund trade list                    # alias for stats
propfund candles --asset ETH --tf 1h --limit 100
                                       # OHLCV from Coinbase (1m,5m,15m,1h,6h,1d)
```

## Write commands (need `PROPFUND_KEY`)

```sh
propfund faucet                                     # mint test USDC (testnet)
propfund faucet --amount 50000

propfund eval start                                 # pay eval fee, begin
propfund eval trade-open --asset SOL                # open virtual long
propfund eval trade-close                           # settle virtual position
propfund eval claim                                 # pay deposit after passing
propfund eval cancel                                # abandon active eval (fee kept)

propfund trade open --asset ETH --side long --margin 250 --leverage 5 \
                    --tp 4500 --sl 3500             # TP/SL mandatory
propfund trade open --asset BTC --side short --margin 100 --leverage 10 \
                    --tp 70000 --sl 78000
propfund trade close                                # full close
propfund trade close --bps 5000                     # close half
propfund trade update --tp 4500 --sl 3500           # change exits

propfund withdraw --amount 100                      # pull realized USDC profit
propfund resign                                     # exit funded status, return remaining deposit
```

## Keeper commands

These are public — anyone with ETH for gas can call them. Useful for keeper bots
patrolling the protocol.

```sh
propfund liquidate 0xtrader…                        # close a position past liquidation threshold
propfund exec-exit  0xtrader…                       # settle a position when TP/SL hits
propfund force-close 0xtrader…                      # close a position past 14-day max
propfund liquidatable 0xtrader…                     # pre-check (read-only)
propfund risk                                       # pool-wide unrealized PnL + active count
propfund leaderboard                                # top traders by cumulative profit
propfund funded-list                                # all currently-funded trader addresses
```

### Autonomous keeper bot

Bundles all four keeper actions into one command — sweeps liquidatable traders, settles TP/SL hits,
force-closes expired positions, and advances the funding queue when capacity opens. Runs with
the same env / `PROPFUND_KEY` setup as the rest of the CLI.

```sh
# One pass and exit (good for cron)
propfund keeper sweep [--dry-run] [--max-gas-gwei N]

# Daemon mode — tick every --interval seconds, SIGINT to exit cleanly
propfund keeper run --interval 30 [--dry-run] [--max-gas-gwei N]
```

Operational guards built in:
- Refuses to act when signer balance < 0.001 ETH
- `--max-gas-gwei` skips ticks above the cap (avoids burning gas during spikes)
- `--dry-run` prints what it would do without sending any tx
- Sequential reads, parallel writes — single tick handles all queued work
- Failed txs (e.g., another keeper got there first) decode to friendly errors and continue

JSON mode (`--json`) emits one structured record per tick for ingestion by an indexer.

**Fee model caveat:** the contract currently pays no keeper fee. Running this is a public good
(or useful self-defense for your own positions). Production deployments should add a keeper-fee
on liquidation/force-close before relying on third-party keepers.

## LP commands

LPs are not traders — they fund the pool and earn 15% of every funded trader's profit (and
absorb any losses beyond a trader's margin).

```sh
propfund lp status                                  # share balance, NAV, pool value
propfund lp deposit --amount 5000                   # deposit USDC, mint shares
propfund lp withdraw --amount 1000                  # USDC-denominated (rounds shares up)
propfund lp withdraw --shares 500000000             # raw share count
propfund lp withdraw --all                          # burn entire share balance
```

`--margin` is denominated in USDC and must be ≤ deposit / 2 (the contract's 50% margin rule).
`--leverage` is an integer 1..10 (contract cap is 10×, gated by the trader's level).

## Delegation (principal → controller)

A principal authorizes a controller EOA to drive their account — eval, funding, trades,
and exit management — bounded by a per-trade notional cap and an expiry timestamp. The
controller never holds funds; only the principal can withdraw profit or resign.

```sh
# Principal authorizes a controller for 30 days, capped at 1000 USDC notional per trade
PROPFUND_KEY=$PRINCIPAL_KEY propfund delegate set --controller 0xCTRL --max-notional 1000 --in 30d

# Controller drives the lifecycle on the principal's behalf
PROPFUND_KEY=$CTRL_KEY propfund eval start  --for 0xPRINCIPAL
PROPFUND_KEY=$CTRL_KEY propfund trade open  --for 0xPRINCIPAL \
    --asset ETH --side long --margin 250 --leverage 5 --tp 4500 --sl 3500

# Principal pulls profit (controller cannot — by design)
PROPFUND_KEY=$PRINCIPAL_KEY propfund withdraw --amount 100
PROPFUND_KEY=$PRINCIPAL_KEY propfund resign
```

## JSON mode

Pass `--json` to any command for structured output. Errors come back as
`{ "ok": false, "error": "..." }` with exit code 1; success commands return the relevant
on-chain values (txHash, blockNumber, deltas).

```sh
$ propfund assets --json
{
  "network": "basesepolia",
  "assets": [
    { "id": 0, "name": "ETH",  "price": "229015000000", "fresh": true },
    { "id": 1, "name": "BTC",  "price": "7617283000000","fresh": true },
    { "id": 2, "name": "LINK", "price": "924816759",    "fresh": true }
  ]
}
```

```sh
$ PROPFUND_KEY=0x... propfund trade open --asset ETH --side long \
    --margin 250 --leverage 5 --tp 4500 --sl 3500 --json
{
  "ok": true,
  "action": "openTrade",
  "assetId": 0,
  "asset": "ETH",
  "side": "long",
  "leverage": 5,
  "sizeBps": "10000",
  "margin": "250000000",
  "notional": "1250000000",
  "tp": "450000000000",
  "sl": "350000000000",
  "txHash": "0x…",
  "blockNumber": 12345
}
```

Prices and USDC amounts are returned as raw integer strings (USDC = 6 decimals,
Pyth prices = 8 decimals). Callers should do their own decimal conversion to avoid
float drift.

## Driving a full lifecycle

```sh
PROPFUND_KEY=0x... propfund faucet      --json     # 1. get test USDC
PROPFUND_KEY=0x... propfund eval start  --json     # 2. pay eval fee
# … open ≥ 3 virtual trades that net ≥ +8% with ≤ 5% drawdown
PROPFUND_KEY=0x... propfund eval claim  --json     # 3. become funded
PROPFUND_KEY=0x... propfund trade open  --asset ETH --side long \
    --margin 250 --leverage 2 --tp 4500 --sl 3500 --json
PROPFUND_KEY=0x... propfund trade close --json     # 4. realize PnL
PROPFUND_KEY=0x... propfund withdraw    --amount 100 --json
```

`stats --json` and `eval status --json` are safe to poll between actions; both are pure
view calls.

## Reference autonomous trader

`scripts/agent.js` is a working autonomous loop. Each tick it:

1. reads on-chain state (`getAssets`, `getEvalStatus`, `getTraderStats`),
2. fetches recent OHLCV candles from Coinbase,
3. asks an LLM "what now?" against any OpenAI-compatible `/v1/chat/completions` endpoint,
4. validates the chosen action against on-chain guardrails,
5. executes via the same internals the CLI uses,
6. appends the action to a JSONL log persisted on a mounted volume.

```sh
PROPFUND_KEY=0x... \
LLM_BASE_URL=https://your-openai-compatible-endpoint/v1 \
AGENT_MODEL=<model-id-your-backend-serves> \
AGENT_CADENCE_SEC=300 \
node scripts/agent.js
```

Environment variables:

| variable           | meaning                                                      |
| ---                | ---                                                          |
| `LLM_BASE_URL`     | OpenAI-compatible `/v1` endpoint (default: OpenRouter)       |
| `OPENROUTER_API_KEY` | required only when `LLM_BASE_URL` targets OpenRouter        |
| `AGENT_MODEL`      | model id matching the backend (required)                     |
| `AGENT_CADENCE_SEC`| seconds between decisions (default 300)                      |
| `AGENT_LOG`        | JSONL log path (default `/tmp/propfund-agent.log`)           |
| `AGENT_HISTORY`    | persisted action history file (default: alongside `AGENT_LOG`) |

Hard guardrails (defensive — the LLM should never need to hit these):

- refuses to act below 0.001 ETH signer balance
- refuses to start a 4th eval cycle in one run (caps wasted eval fees)
- minimum 60s between writes
- hard cap of 100 total actions per run (override with `AGENT_MAX_ACTIONS`)

A `Containerfile` is provided to run it as a long-lived service with podman/docker.

## MCP server

`mcp/server.js` exposes every CLI command as a Model Context Protocol tool. Any
MCP-compatible host can discover and call PropFund actions by name with structured
inputs/outputs.

Example mcpServers config:

```json
{
  "mcpServers": {
    "propfund": {
      "command": "node",
      "args": ["/absolute/path/to/cli/mcp/server.js"],
      "env": {
        "PROPFUND_KEY": "0x...",
        "PROPFUND_NETWORK": "basesepolia"
      }
    }
  }
}
```

Or run standalone for testing: `node mcp/server.js` and pipe JSON-RPC over stdin.

All tools support delegated calls via `for_principal: "0x..."` — same model as the CLI's
`--for` flag. Funds always flow to the principal; the controller never holds value.

## Notes

- USDC is auto-approved (with a max-uint allowance) the first time a write command needs it.
- Read commands work without `PROPFUND_KEY` as long as you pass `--address`.
- `src/networks.js` is the source of truth for network presets. To add a network, append an
  entry there and ship a CLI release. The contract ABI lives at `src/propfund.abi.json` —
  regenerate with `forge inspect PropFund abi --json` after contract changes.

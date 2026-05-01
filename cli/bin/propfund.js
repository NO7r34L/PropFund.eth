#!/usr/bin/env node
import { parseArgs, isJson } from '../src/args.js';
import { err, emitJson } from '../src/format.js';
import { decodeError } from '../src/errors.js';

import { balance } from '../src/commands/balance.js';
import { assets } from '../src/commands/assets.js';
import { stats } from '../src/commands/stats.js';
import { evalStatus, evalStart, evalClaim, evalCancel, evalTradeOpen, evalTradeClose } from '../src/commands/eval.js';
import { tradeOpen, tradeClose, tradeUpdate } from '../src/commands/trade.js';
import { faucet } from '../src/commands/faucet.js';
import { withdraw } from '../src/commands/withdraw.js';
import { lpStatus, lpDeposit, lpWithdraw } from '../src/commands/lp.js';
import { fundedResign } from '../src/commands/funded.js';
import { liquidate, execExit, liquidatable, risk, leaderboard, fundedList } from '../src/commands/keeper.js';
import { queueStatus, queueLeave, queueProcess } from '../src/commands/queue.js';
import { forceClose, positionAge, cap } from '../src/commands/expiry.js';
import { delegateSet, delegateRevoke, delegateStatus } from '../src/commands/delegate.js';
import { keeperRun, keeperSweep } from '../src/commands/keeperBot.js';
import { candles } from '../src/commands/candles.js';

const HELP = `propfund — trading CLI for the PropFund prop fund contract.

usage: propfund <command> [args] [--json]

env:
  PROPFUND_NETWORK   basesepolia | base | local   (default: basesepolia)
  PROPFUND_RPC       override RPC URL
  PROPFUND_KEY       hex private key (required for write commands)

read commands:
  balance [--address X]                show ETH + USDC balance
  assets                               list tradeable assets and live prices
  stats [--address X]                  funded-account stats + open position
  eval status [--address X]            current eval progress
  trade list [--address X]             alias for stats — current open position
  candles --asset ETH [--tf 1h] [--limit 100]
                                       OHLCV from Coinbase (1m,5m,15m,1h,6h,1d)

write commands:
  faucet [--amount 10000]              mint test USDC (testnets only)
  eval start                           pay eval fee, begin evaluation
  eval trade-open [--asset SYM]        open a virtual long on the chosen asset (default ETH; pick any listed asset)
  eval trade-close                     close the virtual eval trade
  eval cancel                          abandon an active eval (fee non-refundable)
  eval claim                           pay deposit; if pool is full, auto-queues
  trade open --asset ETH --side long --margin 250 --leverage 5 [--tp PRICE] [--sl PRICE]
  trade close [--bps 10000]            close (full or partial)
  trade update [--tp PRICE] [--sl PRICE]
                                       change exit levels (0 to clear)
  withdraw --amount 100                pull realized USDC profit (funded trader)
  resign                               exit funded status, return remaining deposit

LP commands (liquidity provider, not trader):
  lp status [--address X]              share balance, NAV, pool value
  lp deposit --amount 1000             add USDC to the pool, mint shares
  lp withdraw --shares N | --amount X | --all
                                       burn shares, withdraw USDC

Funding queue:
  queue status [--address X]           queue length, your position, total escrow
  queue leave                          refund your escrowed deposit, leave queue
  queue process [--max 10]             advance the queue (anyone can call)

Keeper commands (anyone can call):
  liquidate <traderAddress>            liquidate a position past the threshold
  exec-exit <traderAddress>            settle a position when TP / SL has hit
  force-close <traderAddress>          settle a position past max-duration (14d)
  liquidatable <traderAddress>         pre-check (read-only)
  position-age <traderAddress>         age in blocks + expired flag
  cap [--address X]                    effective max notional right now
  risk                                 pool-wide unrealized PnL + active positions
  leaderboard                          top traders by cumulative profit
  funded-list                          all currently-funded trader addresses

Keeper bot (autonomous):
  keeper sweep [--dry-run] [--max-gas-gwei N]
                                       one pass: liquidate, exec-exit, force-close, advance queue
  keeper run [--interval 30] [--dry-run] [--max-gas-gwei N]
                                       daemon — same as sweep, on a loop until SIGINT

Delegation (principal authorizes a controller to drive their account):
  delegate set --controller 0x... --max-notional 1000 --in 30d
                                       authorize a controller (--expiry ISO or --in NN[smhd])
  delegate revoke                      kill controller authority
  delegate status [--address X]        view current authorization

  On every write command, the controller passes --for 0xPRINCIPAL:
    PROPFUND_KEY=$CTRL propfund eval start --for 0xPRINCIPAL
    PROPFUND_KEY=$CTRL propfund trade open --for 0xPRINCIPAL --asset ETH ...
    PROPFUND_KEY=$CTRL propfund withdraw --for 0xPRINCIPAL --amount 100

flags:
  --json                               machine-readable output (for scripts and tooling)
  --network basesepolia|base|local     override env
  --address 0x...                      view another address (read-only commands)
  --for 0xPRINCIPAL                    write commands: act on principal's behalf (delegated)

examples:
  propfund balance
  propfund assets
  PROPFUND_KEY=0x... propfund faucet
  PROPFUND_KEY=0x... propfund eval start
  PROPFUND_KEY=0x... propfund eval claim
  PROPFUND_KEY=0x... propfund trade open --asset ETH --side long --margin 250 --leverage 5
  PROPFUND_KEY=0x... propfund trade close
`;

const COMMANDS = {
    'balance':      balance,
    'assets':       assets,
    'stats':        stats,
    'faucet':       faucet,
    'withdraw':     withdraw,
    'eval status':      evalStatus,
    'eval start':       evalStart,
    'eval claim':       evalClaim,
    'eval cancel':      evalCancel,
    'eval trade-open':  evalTradeOpen,
    'eval trade-close': evalTradeClose,
    'trade open':       tradeOpen,
    'trade close':      tradeClose,
    'trade update':     tradeUpdate,
    'trade list':       stats,
    'lp status':        lpStatus,
    'lp deposit':       lpDeposit,
    'lp withdraw':      lpWithdraw,
    'resign':           fundedResign,
    'liquidate':        liquidate,
    'exec-exit':        execExit,
    'liquidatable':     liquidatable,
    'risk':             risk,
    'leaderboard':      leaderboard,
    'funded-list':      fundedList,
    'queue status':     queueStatus,
    'queue leave':      queueLeave,
    'queue process':    queueProcess,
    'force-close':      forceClose,
    'position-age':     positionAge,
    'cap':              cap,
    'delegate set':     delegateSet,
    'delegate revoke':  delegateRevoke,
    'delegate status':  delegateStatus,
    'keeper sweep':     keeperSweep,
    'keeper run':       keeperRun,
    'candles':          candles,
};

async function main() {
    const argv = process.argv.slice(2);
    if (argv.length === 0 || argv[0] === '-h' || argv[0] === '--help' || argv[0] === 'help') {
        process.stdout.write(HELP);
        return;
    }

    // Match the longest valid prefix. Lets `eval status` and `trade open` work as compound commands.
    let cmd = null;
    let rest = null;
    if (argv.length >= 2) {
        const two = `${argv[0]} ${argv[1]}`;
        if (COMMANDS[two]) { cmd = two; rest = argv.slice(2); }
    }
    if (!cmd && COMMANDS[argv[0]]) { cmd = argv[0]; rest = argv.slice(1); }

    if (!cmd) {
        err(`unknown command: ${argv.join(' ')}`);
        process.stdout.write('\nrun `propfund --help` for usage.\n');
        process.exit(2);
    }

    const args = parseArgs(rest);
    try {
        await COMMANDS[cmd](args);
    } catch (e) {
        const decoded = decodeError(e);
        if (isJson(args)) {
            emitJson({ ok: false, error: decoded.message, errorName: decoded.errorName, errorArgs: decoded.errorArgs, code: decoded.code, data: decoded.data });
        } else {
            err(decoded.message);
            if (process.env.PROPFUND_DEBUG) {
                process.stderr.write(String(e.stack || e) + '\n');
            }
        }
        process.exit(1);
    }
}

main();

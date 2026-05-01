#!/usr/bin/env node
// Autonomous LLM-driven trader for PropFund.
//
// Reads on-chain state + recent candles + its own history, asks an LLM "what now?",
// executes the LLM's chosen action. Loops until SIGINT or a guardrail trips.
//
// Env:
//   LLM_BASE_URL         OpenAI-compatible /v1 endpoint. Default: https://openrouter.ai/api/v1.
//                        Point at any compatible host (e.g. http://host:11434/v1 for a local
//                        Ollama). Auth header is sent only when the URL targets OpenRouter.
//   OPENROUTER_API_KEY   required only when LLM_BASE_URL is OpenRouter
//   PROPFUND_KEY         agent's hot wallet (separate from any human's keys)
//   PROPFUND_NETWORK     basesepolia | base | local
//   PROPFUND_RPC         optional override
//   AGENT_MODEL          model id matching the backend; required (no default)
//   AGENT_CADENCE_SEC    seconds between decisions (default 300 = 5 min)
//   AGENT_LOG            JSONL log path (default /tmp/propfund-agent.log)
//
// Hard guardrails (defensive — the LLM should never need to hit these):
//   - Refuses to act below 0.001 ETH
//   - Refuses to start a 4th eval cycle in one run (4 × $10 = $40 already wasted)
//   - Min 60s between writes (no spam)
//   - Hard cap of 100 total actions per run

import { formatUnits, parseUnits, getAddress } from 'ethers';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { buildContext } from '../src/context.js';
import { decodeError } from '../src/errors.js';
import { resolveNetwork } from '../src/networks.js';

const MODEL = process.env.AGENT_MODEL;
const LLM_BASE_URL = (process.env.LLM_BASE_URL || 'https://openrouter.ai/api/v1').replace(/\/+$/, '');
const IS_OPENROUTER = LLM_BASE_URL.includes('openrouter.ai');
const CADENCE_SEC = Number(process.env.AGENT_CADENCE_SEC || 300);
const LOG_PATH = process.env.AGENT_LOG || '/tmp/propfund-agent.log';
// Persistent action history — survives container restart. Stored next to AGENT_LOG so
// the volume mount keeps it across redeploys.
const HISTORY_PATH = process.env.AGENT_HISTORY || (LOG_PATH.replace(/\.log$/, '') + '-history.jsonl');
const MIN_ETH_WEI = 1_000_000_000_000_000n;  // 0.001
const MAX_ACTIONS = Number(process.env.AGENT_MAX_ACTIONS || 100);
const MAX_EVAL_CANCELS = 3;
const MIN_WRITE_GAP_SEC = 60;

const SYSTEM_PROMPT = `You are an AI prop trader operating an autonomous PropFund account on Ethereum (Sepolia testnet).

PROTOCOL RULES (cannot be changed):
- EVAL phase: pay $10 fee, then open VIRTUAL long-only trades and close them. Each trade you pick which asset (ETH/BTC/SOL/AVAX/LINK/AAVE/DOGE/ARB) — rotate to whichever has the cleanest long setup. Must achieve cumulative +8% return across at least 3 trades to PASS, with no peak-to-trough drawdown >5% along the way. Each trade requires holding for at least 10 blocks (≈2 minutes on Base) before close. PnL compounds across all assets — virtual balance is shared.
- After PASSING eval: pay $100 deposit and claim_funding. You become a funded trader.
- FUNDED: you can open real long/short positions on any listed Chainlink-feeded asset. Per-trade margin is capped at deposit/2. Leverage 1-10×. PnL is computed on (margin × leverage). Loss on a single trade is capped at the position margin (the other 50% of your deposit always survives).
- Profit split on real trades: 80% compounds into your deposit, 15% goes to LPs, 5% to dev.

YOUR JOB:
- Pass eval as efficiently as possible (real ETH price moves slowly on Sepolia; be patient — cancelling and restarting wastes $10 each time)
- Once funded, trade profitably with risk-managed positions
- Don't burn through ETH gas or USDC by oscillating
- WAIT is always a valid action — if no good move is available, wait

DECISION FORMAT:
You MUST respond with a single JSON object and nothing else. The shape:
{"reasoning": "<short why>", "action": "<ACTION_NAME>", "args": <optional args object>}

ACTIONS REFERENCE (the FULL set — but only a subset is legal each tick. Each user message lists "VALID ACTIONS RIGHT NOW" — pick from THAT list, not this reference. Picking outside the valid list is rejected before the contract sees it):
- {"action": "WAIT"} — do nothing this cycle
- {"action": "START_EVAL"} — pay $10 fee, begin eval (only if not in eval and not funded). Asset is picked per-trade, not at start.
- {"action": "OPEN_EVAL_TRADE", "args": {"asset": "ETH|BTC|SOL|AVAX|LINK|AAVE|DOGE|ARB"}} — open a virtual long on the chosen asset. Asset is locked for THIS trade only; next trade you can pick a different one. Look at ALL-ASSET SIGNALS and pick whichever has the cleanest UP setup. Defaults to ETH if omitted.
- {"action": "CLOSE_EVAL_TRADE"} — close the virtual long (during eval, with an open virtual position). The state will tell you if it's closeable: look at \`eval.current_trade_can_close\` — if true, the 10-block hold is satisfied and you may close anytime. Don't second-guess by counting blocks yourself; trust the field.
- {"action": "CANCEL_EVAL"} — abandon eval, lose $10 fee (use sparingly; only if eval is unrecoverable)
- {"action": "CLAIM_FUNDING"} — pay $100 deposit (only after eval passed)
- {"action": "OPEN_TRADE", "args": {"asset": "ETH|BTC|SOL|AVAX|LINK|AAVE|DOGE|ARB", "side": "long"|"short", "margin_usdc": "<decimal>", "leverage": <1-10>, "tp": "<price decimal>", "sl": "<price decimal>"}} — real trade on the chosen asset. Margin must be ≤ deposit/2. tp AND sl are MANDATORY (contract enforces). Long: tp > entry, sl < tp (sl can be ≥ entry as a trailing breakeven stop). Short: tp < entry, sl > tp. Always specify both — agent computes safe defaults if you omit them but explicit is better.
- {"action": "CLOSE_TRADE", "args": {"bps": <1-10000>}} — close position (10000 = full)
- {"action": "UPDATE_EXIT", "args": {"tp": "<price>", "sl": "<price>"}}
- {"action": "WITHDRAW_PROFIT", "args": {"amount_usdc": "<decimal>"}}
- {"action": "RESIGN"} — exit funded status

CONSTRAINTS:
- Don't open positions if oracle is stale (you'll see fresh: false in price data)
- Don't try to claim_funding if eval not passed
- Be conservative with leverage early; you can level up after profits
- Reason briefly, then act`;

const STATE = {
    actionsTaken: 0,
    evalCancels: 0,
    lastWriteTime: 0,
    history: [],   // last 20 actions for context — restored from disk on startup
};

// Restore history from disk so the LLM keeps context across container restarts.
// Read up to the last 20 records — that's what the prompt shows anyway.
function restoreHistory() {
    if (!existsSync(HISTORY_PATH)) return;
    try {
        const lines = readFileSync(HISTORY_PATH, 'utf8').trim().split('\n').filter(Boolean);
        const tail = lines.slice(-20);
        STATE.history = tail.map(l => JSON.parse(l));
    } catch (e) {
        // Corrupted history shouldn't block startup — log and continue with empty history.
        process.stderr.write(`history-restore failed: ${e.message}\n`);
    }
}

function log(level, event, data) {
    const rec = { ts: new Date().toISOString(), level, event, ...data };
    appendFileSync(LOG_PATH, JSON.stringify(rec) + '\n');
    const tag = `[${level.padEnd(5)}] ${event}`;
    process.stdout.write(`${rec.ts} ${tag} ${data ? JSON.stringify(data) : ''}\n`);
}

async function readState(propfund, provider, usdc, wallet) {
    const me = wallet.address;
    const [ethBal, usdcBal, traderStats, evalStatus, assets, evalAccount, blockNumber] = await Promise.all([
        provider.getBalance(me),
        usdc.balanceOf(me),
        propfund.getTraderStats(me),
        propfund.getEvalStatus(me),
        propfund.getAssets(),
        propfund.evals(me),
        provider.getBlockNumber(),
    ]);
    const tradeOpenBlock = Number(evalAccount.tradeOpenBlock);
    const blocksSinceOpen = tradeOpenBlock > 0 ? blockNumber - tradeOpenBlock : 0;
    // Format pct values as labelled strings so the LLM can't mistake a basis-point fraction
    // (e.g. 0.09 means 0.09%, NOT 9%). Mercury and qwen3 both got this wrong on raw numerics.
    const returnPct = Number(evalStatus.returnBps) / 100;
    const drawdownPct = Number(evalStatus.drawdownBps) / 100;
    const targetPct = Number(evalStatus.targetBps) / 100;
    const inVirtualTrade = Boolean(evalStatus.inTrade);

    // Eval asset is locked at startEval and stored on-chain. Default 0 if there's no eval yet.
    const evalAssetId = Number(evalAccount.assetId ?? 0);
    const evalSpotE8 = assets[evalAssetId]?.price ?? assets[evalAssetId]?.[1] ?? 0n;
    const evalSpot = Number(formatUnits(evalSpotE8, 8));
    let openTradeBlock = null;
    if (inVirtualTrade) {
        const entryE8 = evalAccount.entryPrice ?? 0n;
        const entry = Number(formatUnits(entryE8, 8));
        const unrealizedPct = entry > 0 ? ((evalSpot - entry) / entry) * 100 : 0;
        openTradeBlock = {
            entry_price_usd: entry.toFixed(2),
            current_price_usd: evalSpot.toFixed(2),
            unrealized_return: `${unrealizedPct >= 0 ? '+' : ''}${unrealizedPct.toFixed(3)}%`,
            unrealized_return_value: unrealizedPct,  // numeric — used by hint logic, stripped from LLM output
            current_trade_blocks_elapsed: blocksSinceOpen,
            current_trade_can_close: blocksSinceOpen >= 10,
        };
    }
    return {
        address: me,
        ethBalanceWei: ethBal,  // kept for guardrail check, stripped before LLM prompt
        balances: {
            eth: formatUnits(ethBal, 18),
            usdc: formatUnits(usdcBal, 6),
        },
        currentBlock: blockNumber,
        eval: {
            active: Boolean(evalStatus.active),
            passed: Boolean(evalStatus.passed),
            asset_id: evalAssetId,
            asset_name: ASSET_SYMS[evalAssetId] ?? `asset_${evalAssetId}`,
            cumulative_return: `${returnPct.toFixed(2)}%`,
            target_return: `${targetPct.toFixed(2)}%`,
            return_gap_to_pass: `${Math.max(0, targetPct - returnPct).toFixed(2)}%`,
            peak_to_trough_drawdown: `${drawdownPct.toFixed(2)}%`,
            max_drawdown_allowed: '5.00%',
            trades_done: Number(evalStatus.tradeCount),
            trades_needed: Number(evalStatus.tradesNeeded),
            blocks_left: evalStatus.blocksLeft.toString(),
            in_virtual_trade: inVirtualTrade,
            // Only include open-trade telemetry when an open trade actually exists.
            ...(openTradeBlock ? { open_trade: openTradeBlock } : {}),
        },
        funded: {
            active: Boolean(traderStats.active),
            level: Number(traderStats.level),
            deposit_usdc: formatUnits(traderStats.deposit, 6),
            cumulative_pnl_usdc: formatUnits(traderStats.cumulativePnl, 6),
            max_deploy_usdc: formatUnits(traderStats.maxDeploy, 6),
        },
        position: traderStats.inPosition ? {
            asset_id: Number(traderStats.assetId),
            side: traderStats.isShort ? 'short' : 'long',
            deployed_usdc: formatUnits(traderStats.deployedAmount, 6),
            entry_price: formatUnits(traderStats.entryPrice, 8),
            tp_price: traderStats.tpPrice > 0n ? formatUnits(traderStats.tpPrice, 8) : null,
            sl_price: traderStats.slPrice > 0n ? formatUnits(traderStats.slPrice, 8) : null,
        } : null,
        assets: assets.map((a, i) => ({
            id: Number(a.id ?? a[0]),
            name: ASSET_SYMS[i] ?? `asset_${i}`,
            price: formatUnits(a.price ?? a[1], 8),
            fresh: Boolean(a.fresh ?? a[2]),
        })),
    };
}

// Canonical asset ordering for the Base deploy. Index matches contract priceIds[].
const ASSET_SYMS = ['ETH','BTC','SOL','AVAX','LINK','AAVE','DOGE','ARB'];

async function fetchCandles(symbol, tf = '15m', limit = 24) {
    try {
        const granularity = { '1m': 60, '5m': 300, '15m': 900, '1h': 3600 }[tf] ?? 900;
        const url = `https://api.exchange.coinbase.com/products/${symbol}-USD/candles?granularity=${granularity}`;
        const res = await fetch(url, { headers: { 'User-Agent': 'propfund-agent/0.1' } });
        if (!res.ok) return [];
        const raw = await res.json();
        return raw.slice(0, limit).map(([t, low, high, open, close, volume]) => ({
            time: new Date(t * 1000).toISOString(),
            open, high, low, close, volume: Math.round(volume),
        }));
    } catch (e) {
        return [];
    }
}

// Parallel-fetch candles for every listed asset. One Coinbase HTTP call per asset; they
// don't rate-limit at this volume (8 calls/min). Returns map { ETH: [...], BTC: [...] }.
async function fetchAllCandles(symbols, tf = '15m', limit = 24) {
    const entries = await Promise.all(symbols.map(async s => [s, await fetchCandles(s, tf, limit)]));
    return Object.fromEntries(entries);
}

// Min score for a setup to count as actionable. Below this, agent should WAIT — random
// entries on weak signals are the #1 reason qwen3 ground out 22 trades at 0% net.
const MIN_EDGE_SCORE = 0.50;

// Build per-asset signals + a cross-asset ranking. Each asset has its own trend/momentum/range
// for both 15m and 1h timeframes. The 1h is the higher-timeframe context — entries get a
// confluence bonus when 15m and 1h trends agree, and a penalty when they fight.
function computeSignalsAcrossAssets(candleMap15m, candleMap1h, spotByAsset) {
    const out = {};
    for (const [sym, candles] of Object.entries(candleMap15m)) {
        const spot = spotByAsset[sym] ?? candles[0]?.close ?? 0;
        const sig15 = computeSignals(candles, spot);
        const sig1h = candleMap1h?.[sym] ? computeSignals(candleMap1h[sym], spot) : null;
        if (sig15) out[sym] = { ...sig15, htf_1h: sig1h };
    }
    const scored = Object.entries(out).map(([sym, s]) => {
        const m1 = parseFloat(s.momentum_1h);
        const m6 = parseFloat(s.momentum_6h);
        const vol = parseFloat(s.volatility_15m_stdev);
        const trend15 = s.trend_short_vs_long;
        const trend1h = s.htf_1h?.trend_short_vs_long ?? 'FLAT';

        // Confluence: 15m and 1h agreeing = stronger signal. Disagreement = weaker (chop).
        const confluence = trend15 === trend1h && trend15 !== 'FLAT' ? 1.5
                         : trend15 === 'FLAT' || trend1h === 'FLAT' ? 1.0
                         : 0.4;  // active disagreement = strong skepticism

        const trendBonus15 = trend15 === 'UP' ? 1 : trend15 === 'DOWN' ? -1 : 0;
        const longScore  = (m1 * (trendBonus15 > 0 ? 1.5 : trendBonus15 < 0 ? 0 : 1) + 0.5 * m6) * confluence;
        const shortScore = (-m1 * (trendBonus15 < 0 ? 1.5 : trendBonus15 > 0 ? 0 : 1) + 0.5 * -m6) * confluence;
        return { sym, longScore, shortScore, vol, m1, trend15, trend1h, confluence };
    });
    const bestLong = scored.reduce((a, b) => b.longScore > a.longScore ? b : a, { longScore: -Infinity });
    const bestShort = scored.reduce((a, b) => b.shortScore > a.shortScore ? b : a, { shortScore: -Infinity });
    const fmtSetup = (b) => ({
        asset: b.sym,
        score: b.longScore !== undefined ? b.longScore.toFixed(2) : b.shortScore.toFixed(2),
        momentum_1h: `${b.m1.toFixed(2)}%`,
        volatility: `${b.vol.toFixed(2)}%`,
        trend_15m: b.trend15,
        trend_1h: b.trend1h,
        confluence: b.confluence === 1.5 ? 'HTF_AGREES' : b.confluence === 1.0 ? 'NEUTRAL' : 'HTF_DISAGREES',
    });
    return {
        per_asset: out,
        // Only surface a setup if it clears MIN_EDGE_SCORE — keeps the LLM from acting on weak signals.
        best_long_setup:  bestLong.longScore  >= MIN_EDGE_SCORE ? fmtSetup(bestLong)  : null,
        best_short_setup: bestShort.shortScore >= MIN_EDGE_SCORE ? fmtSetup(bestShort) : null,
        min_edge_score: MIN_EDGE_SCORE,
    };
}

// Precompute trend / momentum / range signals from raw OHLCV. The LLM is bad at doing this
// math from 24 rows of numbers; giving it labelled signals is much more reliable.
// candles[0] is the most recent (Coinbase returns newest-first).
function computeSignals(candles, currentPrice) {
    if (!candles || candles.length < 6) return null;
    const closes = candles.map(c => c.close);
    const highs = candles.map(c => c.high);
    const lows = candles.map(c => c.low);
    const sma = (n) => {
        const s = closes.slice(0, n);
        return s.reduce((a, b) => a + b, 0) / s.length;
    };
    const sma6 = sma(Math.min(6, closes.length));
    const sma20 = sma(Math.min(20, closes.length));
    const last = closes[0];
    const oneHourAgo = closes[Math.min(4, closes.length - 1)];   // 4× 15min = 1h
    const sixHourAgo = closes[closes.length - 1];
    const high24 = Math.max(...highs);
    const low24 = Math.min(...lows);

    // Stdev of recent log returns → volatility signal (in pct)
    const rets = [];
    for (let i = 0; i < Math.min(12, closes.length - 1); i++) {
        rets.push(Math.log(closes[i] / closes[i + 1]));
    }
    const mean = rets.reduce((a, b) => a + b, 0) / rets.length;
    const variance = rets.reduce((a, b) => a + (b - mean) ** 2, 0) / rets.length;
    const stdevPct = Math.sqrt(variance) * 100;

    // Direction tag for last 4 candles (U up, D down) — quick read for the LLM
    const lastDirs = candles.slice(0, 4).map(c => c.close >= c.open ? 'U' : 'D').reverse().join('');

    const trend = sma6 > sma20 * 1.001 ? 'UP' : sma6 < sma20 * 0.999 ? 'DOWN' : 'FLAT';
    const momentum1h = ((last - oneHourAgo) / oneHourAgo) * 100;
    const momentum6h = ((last - sixHourAgo) / sixHourAgo) * 100;
    const rangePos = (currentPrice - low24) / Math.max(1e-9, high24 - low24);  // 0=at low, 1=at high

    return {
        trend_short_vs_long: trend,        // SMA6 vs SMA20 over 15m candles
        sma_short_usd: sma6.toFixed(2),
        sma_long_usd: sma20.toFixed(2),
        momentum_1h: `${momentum1h >= 0 ? '+' : ''}${momentum1h.toFixed(2)}%`,
        momentum_6h: `${momentum6h >= 0 ? '+' : ''}${momentum6h.toFixed(2)}%`,
        volatility_15m_stdev: `${stdevPct.toFixed(2)}%`,
        range_24h_low_usd: low24.toFixed(2),
        range_24h_high_usd: high24.toFixed(2),
        range_position_pct: `${(rangePos * 100).toFixed(0)}%`,  // 0% = at low, 100% = at high
        last4_15m_direction: lastDirs,  // e.g. "DDUU" = down,down,up,up oldest→newest
    };
}

// Compute the set of actions that are legal given current state. The LLM has hallucinated
// action names ("OPEN_LONG") and tried funded-only actions while in eval — the whitelist
// stops those from ever reaching the contract and surfaces a clear list in the prompt so
// the LLM doesn't have to derive it from the action reference.
function computeValidActions(state) {
    if (state.funded?.active) {
        if (state.position) {
            return ['WAIT', 'CLOSE_TRADE', 'UPDATE_EXIT', 'WITHDRAW_PROFIT', 'RESIGN'];
        }
        return ['WAIT', 'OPEN_TRADE', 'WITHDRAW_PROFIT', 'RESIGN'];
    }
    if (state.eval?.passed) {
        // Eval passed but funding not claimed yet.
        return ['WAIT', 'CLAIM_FUNDING'];
    }
    if (state.eval?.active) {
        if (state.eval?.in_virtual_trade) {
            const open = state.eval.open_trade;
            if (open?.current_trade_can_close) return ['WAIT', 'CLOSE_EVAL_TRADE', 'CANCEL_EVAL'];
            // Hold not yet satisfied — close would revert. Only WAIT or CANCEL.
            return ['WAIT', 'CANCEL_EVAL'];
        }
        return ['WAIT', 'OPEN_EVAL_TRADE', 'CANCEL_EVAL'];
    }
    // Pre-eval, not funded.
    return ['WAIT', 'START_EVAL'];
}

function buildUserPrompt(state, candles, signals, multiSignals) {
    // Strip BigInts and helper-only fields before serializing.
    const { ethBalanceWei, ...stateForLlm } = state;
    if (stateForLlm.eval?.open_trade?.unrealized_return_value !== undefined) {
        const { unrealized_return_value, ...openClean } = stateForLlm.eval.open_trade;
        stateForLlm.eval = { ...stateForLlm.eval, open_trade: openClean };
    }
    const validActions = computeValidActions(state);

    // Directive hints derived from state — front-loaded so the LLM doesn't have to dig.
    // Includes both DO and DO-NOT directives because both LLMs we've tried (Mercury, qwen3)
    // hallucinate state and try CLOSE_EVAL_TRADE / CLAIM_FUNDING in obviously wrong conditions.
    const hints = [];
    const open = state.eval?.open_trade;
    const unreal = open?.unrealized_return_value ?? 0;

    if (state.eval.active && state.eval.in_virtual_trade && open?.current_trade_can_close) {
        // Trend-following exit logic: cut losers fast, let winners ride while trend holds.
        // The previous "close at +0.3%" rule produced 22 trades at 0% — too quick to close winners.
        const evalAssetSig = multiSignals?.per_asset?.[state.eval.asset_name] || signals;
        const trendStillUp = evalAssetSig?.trend_short_vs_long === 'UP' && parseFloat(evalAssetSig?.momentum_1h || '0') > -0.1;

        if (unreal <= -0.5) {
            hints.push(`OPEN TRADE IS DOWN ${open.unrealized_return} — CUT THE LOSER. Hold is satisfied. CLOSE_EVAL_TRADE now to stop drawdown growth before it compounds. Don't hope for a bounce.`);
        } else if (unreal <= -0.2) {
            hints.push(`Open trade is ${open.unrealized_return}. Small loss. If trend has turned (trend_15m=${evalAssetSig?.trend_short_vs_long || '?'}, 1h momentum ${evalAssetSig?.momentum_1h || '?'}), close. If still aligned with original entry, hold one more cycle.`);
        } else if (unreal >= 1.0) {
            hints.push(`OPEN TRADE IS UP ${open.unrealized_return} — STRONG WIN. Even if signals still favour the trade, CLOSE_EVAL_TRADE to lock in. 1%+ moves in 15-min windows usually retrace. Banking 1% × 8 trades = +8% pass.`);
        } else if (unreal >= 0.4 && !trendStillUp) {
            hints.push(`Open trade is ${open.unrealized_return} and trend has weakened (trend_15m=${evalAssetSig?.trend_short_vs_long || '?'}). LET WINNER RUN UNTIL TREND BREAKS — but it's broken. CLOSE_EVAL_TRADE to lock the gain.`);
        } else if (unreal >= 0.3 && trendStillUp) {
            hints.push(`Open trade is ${open.unrealized_return} and trend still favourable (15m=${evalAssetSig?.trend_short_vs_long}, 1h momentum ${evalAssetSig?.momentum_1h}). HOLD — don't close winners early. Re-evaluate next cycle.`);
        } else {
            hints.push(`Hold satisfied (${open.current_trade_blocks_elapsed} blocks). Open trade is ${open.unrealized_return}. Trend ${evalAssetSig?.trend_short_vs_long}, 1h momentum ${evalAssetSig?.momentum_1h}. If trend reversed against your position, close. Otherwise hold.`);
        }
    }
    if (state.eval.active && state.eval.in_virtual_trade && open && !open.current_trade_can_close) {
        hints.push(`Open trade is ${open.unrealized_return} but hold not satisfied yet (${open.current_trade_blocks_elapsed}/10 blocks). CLOSE_EVAL_TRADE will revert with TradeTooShort. Wait this cycle.`);
    }
    if (state.eval.active && !state.eval.in_virtual_trade) {
        hints.push(`NO open virtual trade. CLOSE_EVAL_TRADE will revert with EvalNoPosition.`);
        // With per-trade asset selection, ALL-ASSET SIGNALS is the right place to look — pick
        // whichever asset has the cleanest UP setup right now. Don't default to ETH.
        if (multiSignals?.best_long_setup) {
            const b = multiSignals.best_long_setup;
            hints.push(`Strongest LONG setup right now: ${b.asset} (1h momentum ${b.momentum_1h}, vol ${b.volatility}). Use {"action":"OPEN_EVAL_TRADE","args":{"asset":"${b.asset}"}}. Eval is long-only — pick the asset with positive momentum and trend=UP, regardless of which asset you traded last cycle.`);
        } else {
            hints.push(`No asset shows a clean LONG setup (all 8 are flat or downtrending). Eval is long-only. Prefer WAIT until at least one asset has trend=UP and 1h momentum > +0.5%. Don't open into a downtrend just to "make progress" — losses count toward drawdown.`);
        }
    }
    if (state.eval.active && !state.eval.passed) {
        hints.push(`EVAL NOT PASSED yet (cumulative_return=${state.eval.cumulative_return}, target=${state.eval.target_return}, gap=${state.eval.return_gap_to_pass}). CLAIM_FUNDING WILL REVERT until passed=true. Do not attempt it.`);
    }
    if (state.eval.passed) {
        hints.push(`EVAL PASSED. Next step is CLAIM_FUNDING.`);
    }
    // Pre-eval: agent just needs to decide whether to pay the $10 to start. With per-trade
    // asset selection, eval is much more flexible — any of 8 assets might pump in the next 7 days.
    const preEvalNow = !state.eval?.active && !state.funded?.active;
    if (preEvalNow) {
        if (multiSignals?.best_long_setup) {
            hints.push(`PRE-EVAL: at least one asset has a clean LONG setup right now (${multiSignals.best_long_setup.asset}, 1h ${multiSignals.best_long_setup.momentum_1h}). Reasonable to START_EVAL — you'll have 7 days to land 3 winning trades across any of the 8 assets.`);
        } else {
            hints.push(`PRE-EVAL: no asset has a clean LONG setup right now. Starting eval is fine if you're willing to wait for a setup, but you'll burn block-time. WAIT is also valid — keep monitoring.`);
        }
    }

    if (state.funded.active && !state.position) {
        if (multiSignals?.best_long_setup) {
            const b = multiSignals.best_long_setup;
            hints.push(`FUNDED, no open position. Strongest LONG setup right now: ${b.asset} (1h momentum ${b.momentum_1h}, vol ${b.volatility}, score ${b.score}). Consider OPEN_TRADE side=long on this asset, not ETH by default. Pick the cleanest edge across the 8 listed assets.`);
        } else if (multiSignals?.best_short_setup) {
            const b = multiSignals.best_short_setup;
            hints.push(`FUNDED, no open position. No clean long setup, but ${b.asset} shows a SHORT setup (1h momentum ${b.momentum_1h}, vol ${b.volatility}, score ${b.score}). Consider OPEN_TRADE side=short on this asset.`);
        } else {
            hints.push(`FUNDED, no open position. No asset shows a clean setup right now (all are choppy or low-conviction). WAIT is the right call.`);
        }
    }
    if (state.funded.active && state.position && multiSignals?.per_asset) {
        // When already in a position, surface whether the current asset's signals still favour the side.
        const symFromId = state.assets.find(a => a.id === state.position.asset_id)?.name;
        const sig = symFromId && multiSignals.per_asset[symFromId];
        if (sig) {
            const m1 = parseFloat(sig.momentum_1h);
            const trendOk = state.position.side === 'long'
                ? sig.trend_short_vs_long !== 'DOWN' && m1 > -0.3
                : sig.trend_short_vs_long !== 'UP' && m1 < 0.3;
            if (!trendOk) {
                hints.push(`Open ${state.position.side} on ${symFromId}: trend has turned against you (trend=${sig.trend_short_vs_long}, 1h momentum=${sig.momentum_1h}). Consider CLOSE_TRADE or tighten SL.`);
            }
        }
    }

    // Show all-asset signals when the agent has a real choice. Hide them only when locked into
    // an open virtual trade (asset is already picked, focus on the close decision).
    const showMultiAsset = !(state.eval?.active && state.eval?.in_virtual_trade);

    return `
== VALID ACTIONS RIGHT NOW ==
You may ONLY pick one of: ${validActions.map(a => `"${a}"`).join(', ')}.
Anything else (including invented names like "OPEN_LONG") will be rejected without being sent on-chain. Pick from this list, no exceptions.

${hints.length ? '== KEY DIRECTIVES ==\n' + hints.map(h => '• ' + h).join('\n') + '\n\n' : ''}CURRENT STATE:
${JSON.stringify(stateForLlm, null, 2)}

${state.eval.asset_name} SIGNALS (eval asset, precomputed from 15-min candles):
${signals ? JSON.stringify(signals, null, 2) : '(insufficient candle data)'}
${showMultiAsset && multiSignals ? `
ALL-ASSET SIGNALS (15-min, ranked):
${JSON.stringify(multiSignals, null, 2)}
` : ''}
RECENT ${state.eval.asset_name} CANDLES (15-min, latest first, last 6):
${JSON.stringify(candles.slice(0, 6), null, 2)}

YOUR RECENT ACTIONS (oldest first):
${STATE.history.length === 0 ? '(none yet)' : JSON.stringify(STATE.history.slice(-10), null, 2)}

What is your next action? Respond with a single JSON object: {"reasoning": "...", "action": "<ONE_OF_VALID>", "args": {...}}.`;
}

async function askLLM(messages) {
    const headers = { 'Content-Type': 'application/json' };
    if (IS_OPENROUTER) {
        const apiKey = process.env.OPENROUTER_API_KEY;
        if (!apiKey) throw new Error('OPENROUTER_API_KEY not set');
        headers['Authorization'] = `Bearer ${apiKey}`;
        headers['HTTP-Referer'] = 'https://github.com/propfund/cli';
        headers['X-Title'] = 'PropFund Autonomous Agent';
    }

    const body = {
        model: MODEL,
        messages,
        temperature: 0.3,
        // Mercury-2 and similar reasoning models burn a lot of hidden tokens. 2500 covers
        // even chunky reasoning cycles; visible JSON is always tiny.
        max_tokens: 2500,
    };
    // Local Ollama honours response_format and is much more reliable when forced into JSON mode.
    if (!IS_OPENROUTER) body.response_format = { type: 'json_object' };

    const res = await fetch(`${LLM_BASE_URL}/chat/completions`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
    });
    if (!res.ok) {
        const errText = await res.text();
        throw new Error(`LLM ${res.status}: ${errText.slice(0, 200)}`);
    }
    const json = await res.json();
    const content = json.choices?.[0]?.message?.content;
    if (!content) throw new Error('LLM returned no content');
    // Strip markdown code fences if present
    const cleaned = content.trim()
        .replace(/^```(?:json)?\s*/i, '')
        .replace(/\s*```$/, '');
    let parsed;
    try { parsed = JSON.parse(cleaned); }
    catch (e) {
        throw new Error(`LLM did not return valid JSON: ${cleaned.slice(0, 200)}`);
    }
    return { parsed, usage: json.usage };
}

// Fetch the latest signed Pyth price update for the configured asset IDs and push it
// on-chain via PropFund's pushPyth(). Skipped silently on Chainlink-era networks (no pythPriceIds).
async function refreshPythIfApplicable(propfund, network, json) {
    if (!network.pythPriceIds || !network.hermesUrl) return null;
    const url = `${network.hermesUrl}/v2/updates/price/latest?` +
        network.pythPriceIds.map(id => `ids[]=${id.startsWith('0x') ? id : '0x' + id}`).join('&');
    const res = await fetch(url, { headers: { 'User-Agent': 'propfund-agent/0.1' } });
    if (!res.ok) throw new Error(`Hermes ${res.status}: ${await res.text().then(t => t.slice(0, 200))}`);
    const body = await res.json();
    const hex = body.binary?.data;
    if (!hex || !Array.isArray(hex)) throw new Error(`Hermes returned no data: ${JSON.stringify(body).slice(0, 200)}`);
    const updateData = hex.map(d => '0x' + d);
    // Pyth charges per-feed (~10 wei each on Base). Send 100000 wei — rounding error in USD.
    // Pin gasLimit so ethers doesn't estimate; estimateGas is buggy when payable + bytes[] reverts
    // bubble up under some L2 RPCs. Direct send works fine.
    const tx = await propfund.pushPyth(updateData, { value: 100_000n, gasLimit: 600_000n });
    const receipt = await tx.wait();
    return { txHash: tx.hash, blockNumber: receipt.blockNumber };
}

async function executeAction(action, propfund, usdc, wallet, state, network) {
    const now = Math.floor(Date.now() / 1000);

    // Whitelist gate: reject any action not legal in current state. Saves gas, surfaces LLM
    // errors instantly, and stops hallucinated action names ("OPEN_LONG") from contributing
    // to on-chain reverts. Whitelist is computed from the same state the LLM saw.
    const validActions = computeValidActions(state);
    if (!validActions.includes(action.action)) {
        return {
            ok: false,
            action: action.action,
            args: action.args,
            error: `action "${action.action}" not legal in current state. valid: ${validActions.join(',')}`,
            rejectedLocally: true,
        };
    }

    // Special: WAIT is a no-op
    if (action.action === 'WAIT') {
        return { ok: true, action: 'WAIT' };
    }

    // Refresh Pyth state for actions whose PnL depends on a current spot. Cheap on Base
    // (~$0.001), skipped silently on networks without Pyth (e.g. Sepolia legacy).
    // If push fails (transient: stale VAA, RPC blip), retry once with fresh data; if still
    // failing, abort the trade — proceeding would just revert on-chain with StaleOracle.
    const PRICE_SENSITIVE = new Set([
        'OPEN_EVAL_TRADE', 'CLOSE_EVAL_TRADE',
        'OPEN_TRADE', 'CLOSE_TRADE',
    ]);
    if (network.pythAddr && PRICE_SENSITIVE.has(action.action)) {
        let pushed = null;
        for (let attempt = 1; attempt <= 2 && !pushed; attempt++) {
            try {
                pushed = await refreshPythIfApplicable(propfund, network, false);
                if (pushed) log('INFO', 'pyth-pushed', { attempt, ...pushed });
            } catch (e) {
                const decoded = decodeError(e);
                log('ERROR', 'pyth-push-failed', {
                    attempt,
                    error: decoded.message,
                    errorName: decoded.errorName,
                    rawData: decoded.data,  // 4-byte selector for offline decoding
                });
            }
        }
        if (!pushed) {
            return { ok: false, action: action.action, error: 'pyth-push-failed (skipping trade — stale price would revert anyway)' };
        }
    }

    // Rate-limit writes
    if (now - STATE.lastWriteTime < MIN_WRITE_GAP_SEC) {
        return { ok: false, action: action.action, error: `rate-limited (${MIN_WRITE_GAP_SEC - (now - STATE.lastWriteTime)}s remaining)` };
    }

    // Pre-flight: USDC allowance to PropFund (eval/claim/lp need this)
    if (['START_EVAL', 'CLAIM_FUNDING'].includes(action.action)) {
        const allowance = await usdc.allowance(wallet.address, propfund.target);
        const needed = action.action === 'START_EVAL' ? 10_000_000n : 100_000_000n;
        if (allowance < needed) {
            const tx = await usdc.approve(propfund.target, (1n << 256n) - 1n);
            await tx.wait();
            log('INFO', 'usdc-approved', { txHash: tx.hash });
        }
    }

    let tx;
    try {
        switch (action.action) {
            case 'START_EVAL':
                tx = await propfund.startEval();
                break;
            case 'OPEN_EVAL_TRADE': {
                // Asset is picked per-trade so the agent can rotate to whichever asset has the
                // cleanest setup right now. Default to ETH if the LLM didn't specify (back-compat).
                let assetId = 0;
                const reqAsset = action.args?.asset;
                if (reqAsset !== undefined) {
                    const symbols = network?.assetNames || [];
                    if (typeof reqAsset === 'number' && reqAsset >= 0 && reqAsset < symbols.length) {
                        assetId = reqAsset;
                    } else if (typeof reqAsset === 'string') {
                        const idx = symbols.indexOf(reqAsset.toUpperCase());
                        if (idx >= 0) assetId = idx;
                    }
                }
                tx = await propfund.openEvalTrade(assetId);
                break;
            }
            case 'CLOSE_EVAL_TRADE':
                tx = await propfund.closeEvalTrade();
                break;
            case 'CANCEL_EVAL':
                if (STATE.evalCancels >= MAX_EVAL_CANCELS) {
                    return { ok: false, action: action.action, error: `eval-cancel cap (${MAX_EVAL_CANCELS}) reached` };
                }
                tx = await propfund.cancelEval();
                STATE.evalCancels++;
                break;
            case 'CLAIM_FUNDING':
                tx = await propfund.claimFunding();
                break;
            case 'OPEN_TRADE': {
                const a = action.args ?? {};
                const isShort = a.side === 'short';
                const lev = Number(a.leverage ?? 1);
                const marginRaw = parseUnits(String(a.margin_usdc ?? '0'), 6);
                if (!state.funded.active) throw new Error('not funded');
                const maxMargin = parseUnits(state.funded.deposit_usdc, 6) / 2n;
                if (marginRaw > maxMargin) throw new Error(`margin > max margin (${state.funded.deposit_usdc}/2)`);
                const sizeBps = (marginRaw * 10_000n) / maxMargin;
                if (sizeBps === 0n) throw new Error('margin too small');

                // Resolve asset symbol → assetId. Default 0 (ETH) if not provided.
                let assetId = 0;
                if (a.asset !== undefined) {
                    const symbols = network?.assetNames || [];
                    if (typeof a.asset === 'number' && a.asset >= 0 && a.asset < symbols.length) {
                        assetId = a.asset;
                    } else if (typeof a.asset === 'string') {
                        const idx = symbols.indexOf(a.asset.toUpperCase());
                        if (idx >= 0) assetId = idx;
                    }
                }

                // Mandatory TP/SL. If LLM omitted them, compute sane defaults from current
                // spot: long → +3%/-2%, short → -3%/+2%. Conservative 1.5:1 risk-reward so
                // the position has explicit failsafes even when the LLM's args are sparse.
                const spot = Number(state.assets[assetId]?.price || 0);
                if (spot <= 0) throw new Error(`no spot price for asset ${assetId}`);
                const defTp = isShort ? spot * 0.97 : spot * 1.03;
                const defSl = isShort ? spot * 1.02 : spot * 0.98;
                const tpStr = (a.tp && String(a.tp) !== '0') ? String(a.tp) : defTp.toFixed(8);
                const slStr = (a.sl && String(a.sl) !== '0') ? String(a.sl) : defSl.toFixed(8);
                const tp = parseUnits(tpStr, 8);
                const sl = parseUnits(slStr, 8);

                tx = await propfund.openTrade(assetId, sizeBps, isShort, tp, sl, lev);
                break;
            }
            case 'CLOSE_TRADE': {
                const bps = BigInt(action.args?.bps ?? 10_000);
                tx = await propfund.closeTrade(bps);
                break;
            }
            case 'UPDATE_EXIT': {
                const tp = action.args?.tp ? parseUnits(String(action.args.tp), 8) : 0n;
                const sl = action.args?.sl ? parseUnits(String(action.args.sl), 8) : 0n;
                tx = await propfund.updateExit(tp, sl);
                break;
            }
            case 'WITHDRAW_PROFIT': {
                const amt = parseUnits(String(action.args?.amount_usdc ?? '0'), 6);
                tx = await propfund.withdrawProfit(amt);
                break;
            }
            case 'RESIGN':
                tx = await propfund.resignFunding();
                break;
            default:
                return { ok: false, action: action.action, error: `unknown action: ${action.action}` };
        }
        const receipt = await tx.wait();
        STATE.lastWriteTime = Math.floor(Date.now() / 1000);
        return { ok: true, action: action.action, args: action.args, txHash: tx.hash, blockNumber: receipt.blockNumber };
    } catch (e) {
        const decoded = decodeError(e);
        return { ok: false, action: action.action, args: action.args, error: decoded.errorName ?? decoded.message };
    }
}

async function tick(ctx) {
    const { propfund, provider, usdc, wallet } = ctx;
    const state = await readState(propfund, provider, usdc, wallet);

    // Soft guardrail: skip the tick if ETH is too low to pay gas. Don't exit — when the
    // wallet is topped up the agent recovers automatically on the next cadence.
    // (Exiting here + podman's --restart=unless-stopped causes a hot-loop crashloop.)
    if (state.ethBalanceWei < MIN_ETH_WEI) {
        log('WARN', 'low-eth-skip', { balance: state.balances.eth });
        return;
    }

    // Per-trade asset selection means we need all-asset signals everywhere except mid-trade
    // (where the asset is locked until close — focus on the open trade's asset only).
    const symbols = state.assets.map(a => a.name);
    const lockedToOneAsset = state.eval?.active === true && state.eval?.in_virtual_trade === true;
    const fetchAll = !lockedToOneAsset;
    const evalSym = state.eval.asset_name || 'ETH';
    const evalSpot = Number(state.assets[state.eval.asset_id || 0]?.price || 0);
    // Multi-timeframe: 15m for entries, 1h for higher-timeframe trend confluence.
    const [candleMap15m, candleMap1h] = await Promise.all([
        fetchAll ? fetchAllCandles(symbols, '15m', 24) : (async () => ({ [evalSym]: await fetchCandles(evalSym, '15m', 24) }))(),
        fetchAll ? fetchAllCandles(symbols, '1h', 24)  : (async () => ({ [evalSym]: await fetchCandles(evalSym, '1h', 24)  }))(),
    ]);
    const candles = candleMap15m[evalSym] || candleMap15m[symbols[0]] || [];
    const signals = computeSignals(candles, evalSpot);
    const multiSignals = fetchAll
        ? computeSignalsAcrossAssets(
            candleMap15m, candleMap1h,
            Object.fromEntries(state.assets.map(a => [a.name, Number(a.price)]))
          )
        : null;

    const messages = [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: buildUserPrompt(state, candles, signals, multiSignals) },
    ];

    let llmResult;
    try {
        llmResult = await askLLM(messages);
    } catch (e) {
        log('ERROR', 'llm-call-failed', { error: e.message });
        return;
    }
    log('LLM', 'decision', { action: llmResult.parsed.action, reasoning: llmResult.parsed.reasoning, usage: llmResult.usage });

    const result = await executeAction(llmResult.parsed, propfund, usdc, wallet, state, ctx.net);
    log(result.ok ? 'EXEC' : 'ERROR', result.ok ? 'action-ok' : 'action-failed', result);

    const histEntry = {
        ts: new Date().toISOString(),
        action: llmResult.parsed.action,
        args: llmResult.parsed.args ?? null,
        ok: result.ok,
        error: result.error ?? null,
        reasoning: llmResult.parsed.reasoning?.slice(0, 200),
    };
    STATE.history.push(histEntry);
    if (STATE.history.length > 20) STATE.history.shift();
    // Persist so the next container restart resumes with context.
    try { appendFileSync(HISTORY_PATH, JSON.stringify(histEntry) + '\n'); } catch {}

    STATE.actionsTaken++;
    if (STATE.actionsTaken >= MAX_ACTIONS) {
        log('STOP', 'action-cap', { actionsTaken: STATE.actionsTaken });
        process.exit(0);
    }
}

async function main() {
    if (!MODEL) {
        process.stderr.write('AGENT_MODEL env var required (e.g. a model id your LLM_BASE_URL backend serves)\n');
        process.exit(1);
    }
    if (IS_OPENROUTER && !process.env.OPENROUTER_API_KEY) {
        process.stderr.write('OPENROUTER_API_KEY env var required (or set LLM_BASE_URL to a local endpoint)\n');
        process.exit(1);
    }
    const ctx = buildContext({ requireSigner: true });
    restoreHistory();
    log('INFO', 'agent-start', {
        network: ctx.net.key,
        address: ctx.wallet.address,
        model: MODEL,
        llmBaseUrl: LLM_BASE_URL,
        cadenceSec: CADENCE_SEC,
        logPath: LOG_PATH,
        historyPath: HISTORY_PATH,
        restoredHistoryCount: STATE.history.length,
    });

    let stopped = false;
    const stop = () => { if (!stopped) { stopped = true; log('INFO', 'sigint', {}); } };
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);

    while (!stopped) {
        try {
            await tick(ctx);
        } catch (e) {
            log('ERROR', 'tick-error', { error: e.message, stack: e.stack?.slice(0, 500) });
        }
        if (stopped) break;
        await new Promise(r => setTimeout(r, CADENCE_SEC * 1000));
    }
    log('INFO', 'agent-stop', { actionsTaken: STATE.actionsTaken });
}

main().catch(e => {
    log('FATAL', 'main-crash', { error: e.message, stack: e.stack?.slice(0, 500) });
    process.exit(1);
});

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
//   - Refuses to start a 4th eval cycle in one run (4 × $1 = $4 already wasted)
//   - Min 60s between writes (no spam)
//   - Hard cap of 100 total actions per run

import { formatUnits, parseUnits, getAddress } from 'ethers';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { buildContext, assertAssetMapping } from '../src/context.js';
import { decodeError } from '../src/errors.js';
import { resolveNetwork, hermesHeaders } from '../src/networks.js';
import { runWithWatchdog } from '../src/watchdog.js';

const MODEL = process.env.AGENT_MODEL;
const LLM_BASE_URL = (process.env.LLM_BASE_URL || 'https://openrouter.ai/api/v1').replace(/\/+$/, '');
const IS_OPENROUTER = LLM_BASE_URL.includes('openrouter.ai');
const CADENCE_SEC = Number(process.env.AGENT_CADENCE_SEC || 300);
const LOG_PATH = process.env.AGENT_LOG || '/tmp/propfund-agent.log';
// Persistent action history — survives container restart. Stored next to AGENT_LOG so
// the volume mount keeps it across redeploys.
const HISTORY_PATH = process.env.AGENT_HISTORY || (LOG_PATH.replace(/\.log$/, '') + '-history.jsonl');
const PEAK_DEPOSIT_PATH = process.env.AGENT_PEAK_DEPOSIT || (LOG_PATH.replace(/\.log$/, '') + '-peak.json');
const WATCH_PLAN_PATH = process.env.AGENT_WATCH_PLAN_PATH || (LOG_PATH.replace(/\.log$/, '') + '-watchplan.json');
const DESK_STATE_PATH = process.env.AGENT_DESK_STATE || (LOG_PATH.replace(/\.log$/, '') + '-desk.json');
const MIN_ETH_WEI = 1_000_000_000_000_000n;  // 0.001
const MAX_ACTIONS = Number(process.env.AGENT_MAX_ACTIONS || 100);
const MAX_EVAL_CANCELS = 3;
const MIN_WRITE_GAP_SEC = 60;
// Drawdown circuit breaker for FUNDED MODE. Once an agent's deposit drops below
// peak × (1 - MAX_DEPOSIT_DRAWDOWN_PCT/100), refuse new OPEN_TRADE. The contract's
// 50% margin rule caps loss-per-trade; this protects against death-by-1000-cuts where
// an agent steadily bleeds the deposit across many small losing trades. Default 25%.
// Tighten in production. Set 0 to disable.
const MAX_DEPOSIT_DRAWDOWN_PCT = Number(process.env.MAX_DEPOSIT_DRAWDOWN_PCT || 25);

// Eval exit management (deterministic — the LLM picks entries, code manages exits).
// Eval is 1x long-only; passing needs +8% compounded over >=3 closes with <=5% drawdown
// from peak virtualBalance. Banking wins and cutting losers at the right moment is timing an
// LLM on a multi-minute tick can't hit, so these rules own the close. The LLM only entries.
const EVAL_TP_PCT = Number(process.env.EVAL_TP_PCT || 3.0);                    // hard take-profit per trade
const EVAL_TRAIL_ARM_PCT = Number(process.env.EVAL_TRAIL_ARM_PCT || 1.2);      // arm the trail once up this much
const EVAL_TRAIL_GIVEBACK_PCT = Number(process.env.EVAL_TRAIL_GIVEBACK_PCT || 0.6); // close if it gives back this from peak
const EVAL_SL_PCT = Number(process.env.EVAL_SL_PCT || 2.0);                    // cut a loser at -this% (when drawdown-safe)
// Close a stale, going-nowhere trade after this long. Expressed in wall-clock seconds and
// converted to blocks via the network's blockTimeSec, so the same setting means the same
// duration on 2s Base and 12s Ethereum blocks. EVAL_TIME_STOP_BLOCKS still overrides directly.
const EVAL_TIME_STOP_SEC = Number(process.env.EVAL_TIME_STOP_SEC || 3600);
const EVAL_TIME_STOP_BLOCKS = Number(
    process.env.EVAL_TIME_STOP_BLOCKS || Math.round(EVAL_TIME_STOP_SEC / resolveNetwork().blockTimeSec)
);
const EVAL_DRAWDOWN_FAIL_BPS = 500;
// --- Desk (real 1x ETH spot book) exit policy. Same shape as the eval exit manager: the code
// owns the exit, the LLM owns the entry. The stop MUST sit well inside the desk's drawdown floor
// (MAX_DRAWDOWN_BPS below allocation, 10% by default) — a keeper liquidation there FORFEITS the
// agent's deposit, so we always exit ourselves first.
// EVERY DESK ENTRY IS A BRACKET ORDER, ON-CHAIN: enterEth takes tp + sl at the same moment, the
// contract bounds them (MAX_STOP_BPS / MAX_TARGET_BPS of entry) and force-exits after MAX_HOLD, and
// anyone can executeExit when the bracket or the clock hits. The LLM chooses the bracket (like
// OPEN_TRADE); these are the defaults the code fills in when it doesn't, clamped to the bounds.
// Shape is ASYMMETRIC on purpose: risk 1.5 to make 6. In analysis/desk_sim.py a fixed bracket with a
// 1-day max hold beat week-long holds 4-6x. The trail tightens the stop on-chain (updateBracket can
// only tighten). Round-trip venue cost is ~0.17%.
const DESK_TP_PCT = Number(process.env.DESK_TP_PCT || 6.0);
const DESK_TRAIL_ARM_PCT = Number(process.env.DESK_TRAIL_ARM_PCT || 3.0);
const DESK_TRAIL_GIVEBACK_PCT = Number(process.env.DESK_TRAIL_GIVEBACK_PCT || 1.5);
const DESK_SL_PCT = Number(process.env.DESK_SL_PCT || 1.5);
const DESK_SLIPPAGE_BPS = Number(process.env.DESK_SLIPPAGE_BPS || 100);   // minOut tolerance vs live spot
const DESK_CLAIM_MIN_USDC = Number(process.env.DESK_CLAIM_MIN_USDC || 25); // auto-claim threshold once the ladder is capped                                           // mirrors contract EVAL_DRAWDOWN_BPS (5%)
const FAST_CADENCE_SEC = Number(process.env.AGENT_FAST_CADENCE_SEC || 60);    // poll faster while a position is open

// --- ICT-style entry gating: spend an LLM call only when the market is actually in play ---
// Fixed-interval polling asks the LLM every tick even at 3am in the middle of a dead range.
// Instead, gate ENTRY decisions on two objective conditions: (a) session "killzones" — the
// London and New York windows where crypto majors do most of their real movement — and (b)
// price actually interacting with a pre-computed key level (prior-day / prior-session high &
// low, where liquidity rests). Outside a killzone, or with price mid-range far from any level,
// the tick cheap-skips with NO LLM call. Exits stay deterministic (already no LLM), so an open
// trade's responsiveness is unaffected. Off by default (set ICT_ENTRY_GATE=1) so nothing
// changes for existing deployments unless opted in.
const ICT_ENTRY_GATE = process.env.ICT_ENTRY_GATE === '1';
// UTC windows "HH:MM-HH:MM,..."; default = London Open + NY Open killzones. Empty = no time gate.
const ICT_KILLZONES = (process.env.ICT_KILLZONES ?? '07:00-10:00,12:00-15:00')
    .split(',').map(w => w.trim()).filter(Boolean)
    .map(w => { const [a, b] = w.split('-'); const m = t => { const [h, mi] = t.split(':').map(Number); return h * 60 + mi; }; return [m(a), m(b)]; });
// Wake the LLM when price is within this % of a key level (a level tag / potential reaction).
const ICT_LEVEL_PROX_PCT = Number(process.env.ICT_LEVEL_PROX_PCT || 0.15);

// --- Agent-directed watch plan (supersedes the static ICT gate when on) ---
// The LLM declares, in a "watch" object, the price levels and next wake-time it cares about. A
// free watcher re-consults it only when a level is crossed, the scheduled time arrives, or a
// safety idle cap elapses — so the agent sets its OWN markers instead of being polled on a timer.
const AGENT_WATCH_PLAN = process.env.AGENT_WATCH_PLAN === '1';
const MAX_WATCH_IDLE_MIN = Number(process.env.MAX_WATCH_IDLE_MIN || 360);
// msg.value sent with a router trade to cover the Pyth update fee (1 wei on Sepolia, ~hundreds on
// Base). The router pays the exact fee and refunds the rest, so a comfortable buffer is free.
const ROUTER_VALUE = BigInt(process.env.ROUTER_VALUE_WEI || 1_000_000);
// Pin gasLimit on router calls so ethers skips estimateGas — its estimate misfires on a
// payable + bytes[] call (updatePriceFeeds) under some RPCs and surfaces a bogus revert
// (StaleOracle) before the tx is even sent. Same workaround pushPyth uses. Covers
// updatePriceFeeds + the heaviest trade (funded open).
const ROUTER_GAS = BigInt(process.env.ROUTER_GAS_LIMIT || 1_000_000);

const SYSTEM_PROMPT = `You are an autonomous trader operating a PropFund account on Base.

PROTOCOL RULES (cannot be changed):
- EVAL phase: pay $1 fee, then open VIRTUAL long-only trades and close them. At each open you pick which asset (ETH/BTC/SOL/AVAX/LINK/AAVE/DOGE/ARB) — asset selection happens at entry time, not as a reason to close existing trades. To PASS you need: virtualBalance ≥ 1.08 (i.e. +8% cumulative compounded return) AND tradeCount ≥ 3, both at the moment of close. tradeCount has no upper limit — you can open and close as many trades as you want inside the eval window (only the cumulative return matters). Drawdown from peak virtualBalance must stay ≤ 5% the entire time; breach = instant fail. Each trade requires holding at least 10 blocks (≈20s on Base) before close. Eval window is ~30 days.
- HOW EVAL MATH ACTUALLY WORKS (read carefully — the most common failure mode is misunderstanding this):
    * Virtual trades have NO capital cost. There is no "freeing capital" — there is no capital tied up.
    * On every close, virtualBalance *= (close_price / entry_price). It STARTS at 1.0; you need it to reach 1.08 (or higher) to pass.
    * Closing a trade that hasn't moved (return = 0.00%) just multiplies by ~1.0 and BURNS A SLOT in your tradeCount without making progress.
    * Three closes at +3% each = ~+9.27% (compounds) → PASS. One hundred closes at 0.00% = still 1.0000 → still failing.
    * Therefore: opening a trade and closing it before the price has actually moved is strictly worse than waiting. NEVER close a virtual trade just to "rotate" or "free capital." Hold until you have a real return.
- After PASSING eval: pay $100 deposit and claim_funding. You become a funded trader.
- FUNDED: you can open real long/short positions on any listed Pyth-feeded asset. Per-trade margin is capped at deposit/2. Leverage 1-10×, level-gated (3× unlocks at +$50 cumPnl, 5× at +$150, 8× at +$400, 10× at +$1000). PnL is computed on (margin × leverage). Loss on a single trade is capped at the position margin (the other 50% of your deposit always survives).
- Profit split on real trades: 80% compounds into your deposit, 15% goes to LPs, 5% to the protocol treasury.

YOUR JOB:
- Pass eval, then trade the funded account profitably. Read the candles, the
  multi-timeframe signals, your own action history, and decide.
- DURING EVAL your only decision is the ENTRY. Once you open a virtual trade, the runtime
  manages the exit automatically (take-profit, trailing stop, and a drawdown-safe stop-loss)
  and you are not consulted again until it's closed — so don't agonize over closes. Open ONLY
  on a clean long setup (a non-null best_long_setup at or above the min edge score), on THAT
  asset; otherwise WAIT. One good entry beats ten mediocre ones.
- WAIT is always a valid action. There's no penalty for waiting; there is a real cost
  ($1 each cancel, drawdown counts on losses) for low-quality entries.

You are evaluated on results (passing eval, growing the funded deposit), not on activity.

FIELD DISAMBIGUATION (the state JSON has several similar-looking fields — read them carefully):
- eval.open_trade.unrealized_return — YOUR open trade's PnL since you opened it. This is
  what closes will realize against virtualBalance.
- eval.cumulative_return — your virtualBalance progress so far this eval (0.00% = 1.0).
- multi_signals.per_asset[X].momentum_6h / momentum_1h — the ASSET's general market move
  over a window, independent of any trade. A "+1.62% 6h momentum" reading does NOT mean
  your open trade is up 1.62%. Look at unrealized_return for that.

DECISION FORMAT:
You MUST respond with a single JSON object and nothing else. The shape:
{"reasoning": "<short why>", "action": "<ACTION_NAME>", "args": <optional args object>}

ACTIONS REFERENCE (the FULL set — but only a subset is legal each tick. Each user message lists "VALID ACTIONS RIGHT NOW" — pick from THAT list, not this reference. Picking outside the valid list is rejected before the contract sees it):
- {"action": "WAIT"} — do nothing this cycle
- {"action": "START_EVAL"} — begin eval, FREE (a negligible 1-wei fee; only if not in eval and not funded). Asset is picked per-trade, not at start.
- {"action": "OPEN_EVAL_TRADE", "args": {"asset": "ETH|BTC|SOL|AVAX|LINK|AAVE|DOGE|ARB"}} — open a virtual long on the chosen asset. Asset is locked for THIS trade only; next trade you can pick a different one. Look at ALL-ASSET SIGNALS and pick whichever has the cleanest UP setup. Defaults to ETH if omitted.
- {"action": "CLOSE_EVAL_TRADE"} — close the virtual long (during eval, with an open virtual position). The state will tell you if it's closeable: look at \`eval.current_trade_can_close\` — if true, the 10-block hold is satisfied and you may close anytime. Don't second-guess by counting blocks yourself; trust the field.
- {"action": "CANCEL_EVAL"} — abandon eval, lose $1 fee (use sparingly; only if eval is unrecoverable)
- {"action": "CLAIM_FUNDING"} — pay $100 deposit (only after eval passed)
- {"action": "OPEN_TRADE", "args": {"asset": "ETH|BTC|SOL|AVAX|LINK|AAVE|DOGE|ARB", "side": "long"|"short", "margin_usdc": "<decimal>", "leverage": <1-10>, "tp": "<price decimal>", "sl": "<price decimal>"}} — real trade on the chosen asset. Margin must be ≤ deposit/2. tp AND sl are MANDATORY (contract enforces). Long: tp > entry, sl < tp (sl can be ≥ entry as a trailing breakeven stop). Short: tp < entry, sl > tp. Always specify both — agent computes safe defaults if you omit them but explicit is better.
- {"action": "CLOSE_TRADE", "args": {"bps": <1-10000>}} — close position (10000 = full)
- {"action": "UPDATE_EXIT", "args": {"tp": "<price>", "sl": "<price>"}}
- {"action": "WITHDRAW_PROFIT", "args": {"amount_usdc": "<decimal>"}}
- {"action": "RESIGN"} — exit funded status
- {"action": "DESK_ADMIT"} — GRADUATE. Offered only when state.desk.qualifies=true (your PropFund probation record clears the desk bar). Posts the deposit and admits you to the REAL desk.
- {"action": "ENTER_ETH", "args": {"tp": "<price decimal>", "sl": "<price decimal>"}} — desk only: swap your WHOLE USDC book into ETH (real 1x spot, one pool) as a BRACKET ORDER. tp AND sl are set at entry and enforced ON-CHAIN; bounds: sl within state.desk.bracket_bounds.max_stop_pct below spot, tp within max_target_pct above, and the position is force-closed after max_hold_hours regardless. Anyone can execute your bracket the moment it hits. Defaults if omitted: stop 1.5% / target 6%. The bracket can only be TIGHTENED afterwards (the code trails the stop). Round-trip venue cost is ~0.17%. Do NOT churn.
- {"action": "EXIT_ETH"} — desk only: swap the whole ETH book back to USDC now. The automated exit normally handles this; use only with a strong reason.

DESK PHASE (state.desk.admitted=true): you have GRADUATED from virtual probation to a real book of the
firm's capital. PropFund probation entries are over. Your only job is timing ONE asset (ETH) with the
whole book — you are either in USDC or in ETH. The book has a hard drawdown floor
(state.desk.drawdown_floor_usdc): if its marked value reaches it, a keeper liquidates you and your
deposit is FORFEITED. The code's automated stop is set well inside that floor — let it work; never
hold through a loss hoping. You cannot sit in ETH: every entry carries an on-chain take-profit, stop-loss
and max-hold, executed by anyone. Your ALLOCATION SCALES (1x → 2x → 4x → 8x) with REALIZED profit — gated on
your WIN RATIO as profit factor (gross wins / gross losses ≥ 1.3 / 1.5 / 1.8 per tier, over a small sample
of closed trades) and only when that profit beats what simply holding ETH since your admission would have
made (state.desk.hold_hurdle_usdc). Beta is not paid; timing is. Profit factor is size-weighted, so a high
win rate from tiny targets and wide stops does NOT scale you — quality of wins does. Your earned share is
held as collateral for the bigger book and released automatically (claims are handled by the code, not you).

OPTIONAL — SELF-SCHEDULING (you are NOT polled on a fixed timer; you set your own wake conditions):
Add a "watch" object to your response to say WHEN you want to be consulted next. Between wakes a
cheap watcher checks price and the clock for free and only calls you again when one of YOUR triggers
fires — so you are not billed for staring at a dead market. Shape:
{"watch": {
  "levels": [{"asset":"ETH","price":2450,"dir":"below"}, {"asset":"BTC","price":80000,"dir":"above"}],
  "wake_at_utc": "12:00",   // optional: also wake me at this UTC time (e.g. a session open)
  "max_idle_min": 120       // optional safety: wake me anyway after this long (default 360)
}}
Put levels at the prices where your thesis actually changes — a key prior-day/session high or low, a
breakout trigger, an invalidation — NOT next to the current price (that defeats the purpose). "dir"
is the side price must cross to. If you have no active view, set few/no levels and a wider
max_idle_min so you sleep cheaply. When re-woken you'll be told which trigger fired.

CONSTRAINTS:
- Don't open positions if oracle is stale (you'll see fresh: false in price data)
- Don't try to claim_funding if eval not passed
- Be conservative with leverage early; you can level up after profits
- Reason briefly, then act`;

const STATE = {
    actionsTaken: 0,
    evalCancels: 0,
    watchPlan: null,     // agent-directed { setAt, levels[], armed[], wakeAt, maxIdleSec }
    wokenReason: null,   // why the watcher re-consulted the LLM this tick (for the prompt)
    lastWriteTime: 0,
    history: [],         // last 20 actions for context — restored from disk on startup
    peakDeposit: 0n,     // peak USDC deposit observed in funded mode (raw 6-decimal). Used
                         // by the drawdown circuit breaker. Persisted across restarts.
    evalTradePeakR: null, // peak unrealized % of the CURRENT open eval trade — drives the trailing exit
    fastPoll: false,     // poll on FAST_CADENCE_SEC while a position is open (catch the peak)
    deskEntryUsdc: null, // USDC value of the desk book when we last entered ETH (drives desk exit %)
    deskPeakR: null,     // peak unrealized % of the current desk ETH position (trailing exit)
};

let DESK = null;   // AgentDesk contract (ethers), set in main() when net.deskAddr is wired

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

function restorePeakDeposit() {
    if (!existsSync(PEAK_DEPOSIT_PATH)) return;
    try {
        const obj = JSON.parse(readFileSync(PEAK_DEPOSIT_PATH, 'utf8'));
        STATE.peakDeposit = BigInt(obj.peak ?? 0);
    } catch (e) {
        process.stderr.write(`peak-deposit-restore failed: ${e.message}\n`);
    }
}

function recordPeakDeposit(currentDepositRaw) {
    if (currentDepositRaw <= STATE.peakDeposit) return;
    STATE.peakDeposit = currentDepositRaw;
    try { writeFileSync(PEAK_DEPOSIT_PATH, JSON.stringify({ peak: STATE.peakDeposit.toString() })); } catch {}
}

function restoreDeskState() {
    if (!existsSync(DESK_STATE_PATH)) return;
    try {
        const o = JSON.parse(readFileSync(DESK_STATE_PATH, 'utf8'));
        STATE.deskEntryUsdc = o.entryUsdc ?? null;
        STATE.deskPeakR = o.peakR ?? null;
    } catch (e) { process.stderr.write(`desk-state-restore failed: ${e.message}\n`); }
}
function saveDeskState() {
    try { writeFileSync(DESK_STATE_PATH, JSON.stringify({ entryUsdc: STATE.deskEntryUsdc, peakR: STATE.deskPeakR })); } catch {}
}

function depositDrawdownPct(currentDepositRaw) {
    if (STATE.peakDeposit === 0n) return 0;
    if (currentDepositRaw >= STATE.peakDeposit) return 0;
    // bps with 2 decimals, then to %
    const bps = ((STATE.peakDeposit - currentDepositRaw) * 10_000n) / STATE.peakDeposit;
    return Number(bps) / 100;
}

function log(level, event, data) {
    const rec = { ts: new Date().toISOString(), level, event, ...data };
    appendFileSync(LOG_PATH, JSON.stringify(rec) + '\n');
    const tag = `[${level.padEnd(5)}] ${event}`;
    process.stdout.write(`${rec.ts} ${tag} ${data ? JSON.stringify(data) : ''}\n`);
}

// Live market price for one feed from Hermes (no gas, no tx). The agent uses this for its
// in-trade PnL so it tracks the real market — NOT the on-chain oracle, which on a sparsely-pushed
// testnet can be frozen for hours, leaving the agent blind to price movement during a hold (every
// trade then reads 0.00% and time-stops flat). Settlement still happens on-chain: the router
// applies the same Hermes price at close, so the decision and the settlement stay consistent.
async function fetchLiveSpot(network, priceId) {
    if (!network?.hermesUrl || !priceId) return null;
    const id = priceId.startsWith('0x') ? priceId : '0x' + priceId;
    const res = await fetch(`${network.hermesUrl}/v2/updates/price/latest?ids[]=${id}`, { headers: hermesHeaders({ 'User-Agent': 'propfund-agent/0.1' }) });
    if (!res.ok) return null;
    const p = (await res.json())?.parsed?.[0]?.price;
    if (!p) return null;
    return Number(p.price) * Math.pow(10, Number(p.expo));
}

async function readState(propfund, provider, usdc, wallet, network, lens = propfund) {
    const me = wallet.address;
    const [ethBal, usdcBal, traderStats, evalStatus, assets, evalAccount, blockNumber] = await Promise.all([
        provider.getBalance(me),
        usdc.balanceOf(me),
        lens.getTraderStats(me),   // view layer (PropFundLens); falls back to propfund if no lens
        lens.getEvalStatus(me),
        propfund.getAssets(),
        propfund.evals(me),
        provider.getBlockNumber(),
    ]);
    // Desk (real 1x spot book) — read alongside PropFund so the LLM sees probation (PropFund) and
    // graduation (desk) in one state object. Only when a desk is wired.
    let desk = null;
    if (DESK) {
        const [bk, bv, floor, liq, qual, earnedRaw, dep, lad, baseAlloc, maxMult, wr, sampleFloor, br, exitR, maxStop, maxTarget, maxHold] = await Promise.all([
            DESK.getBook(me), DESK.bookValue(me), DESK.drawdownFloor(me), DESK.isLiquidatable(me),
            DESK.qualifies(me), DESK.earned(me), DESK.AGENT_DEPOSIT(), DESK.ladder(me),
            DESK.BASE_ALLOCATION(), DESK.MAX_ALLOCATION_MULT(), DESK.winRatio(me), DESK.SCALE_MIN_TRADES(),
            DESK.brackets(me), DESK.exitReason(me), DESK.MAX_STOP_BPS(), DESK.MAX_TARGET_BPS(), DESK.MAX_HOLD(),
        ]);
        const EXIT_REASON = ['none', 'take-profit', 'stop-loss', 'max-hold'];
        const pfBps = wr.profitFactorBps ?? wr[0];
        const inEth = bk.eth > 0n;
        const markFresh = Boolean(bv.fresh ?? bv[1]);
        // A stale mark comes back as (0, false). NEVER turn that into a -100% "loss" — it would trip
        // the stop-loss and dump a healthy position on a transient oracle gap. Unknown stays unknown.
        const value = markFresh ? Number(formatUnits(bv.value ?? bv[0], 6)) : null;
        // Entry reference: the contract records the exact USDC that went into the open position.
        const entry = inEth ? Number(formatUnits(bk.entryUsdc, 6)) : (STATE.deskEntryUsdc ?? null);
        const maxAlloc = baseAlloc * maxMult;
        const heldHours = inEth && bk.entryTime > 0n ? (Date.now() / 1000 - Number(bk.entryTime)) / 3600 : null;
        const unreal = (inEth && entry && value != null) ? ((value - entry) / entry) * 100 : null;
        desk = {
            wired: true,
            admitted: Boolean(bk.active),
            qualifies: Boolean(qual),
            deposit_required_usdc: formatUnits(dep, 6),
            earned_usdc: formatUnits(earnedRaw, 6),
            ...(bk.active ? {
                allocation_usdc: formatUnits(bk.allocation, 6),
                max_allocation_usdc: formatUnits(maxAlloc, 6),
                at_max_allocation: bk.allocation >= maxAlloc,
                realized_pnl_usdc: formatUnits(bk.cumPnl, 6),
                desk_trades: Number(bk.trades),
                // Win ratio the ladder gates on: profit factor = gross wins / gross losses (size-weighted,
                // exit-shape-independent). Win rate is shown for the record but is NOT what scales the book.
                win_rate: `${(Number(wr.winRateBps ?? wr[1]) / 100).toFixed(1)}%`,
                profit_factor: pfBps >= 2n ** 128n ? 'inf' : (Number(pfBps) / 10_000).toFixed(2),
                ladder_sample_floor_trades: Number(sampleFloor),
                // Bracket bounds the contract enforces on ENTER_ETH (tp/sl are mandatory, set at entry).
                bracket_bounds: { max_stop_pct: Number(maxStop) / 100, max_target_pct: Number(maxTarget) / 100, max_hold_hours: Number(maxHold) / 3600 },
                // Allocation ladder: the book grows only on realized alpha over holding ETH since admission.
                ladder_mult_now: Number(lad.mult ?? lad[0]),
                hold_hurdle_usdc: formatUnits(lad.hurdle ?? lad[1], 6),
                book_usdc: formatUnits(bk.usdc, 6),
                book_eth: formatUnits(bk.eth, 18),
                in_eth: inEth,
                book_value_usdc: value != null ? value.toFixed(4) : null,
                mark_fresh: markFresh,
                drawdown_floor_usdc: formatUnits(floor, 6),
                liquidatable_by_keeper: Boolean(liq),
                ...(inEth ? {
                    entry_value_usdc: entry != null ? entry.toFixed(4) : null,
                    held_hours: heldHours,
                    entry_price: formatUnits(br.entryPrice ?? br[0], 8),
                    tp_price: formatUnits(br.tpPrice ?? br[1], 8),
                    sl_price: formatUnits(br.slPrice ?? br[2], 8),
                    exit_reason_now: EXIT_REASON[Number(exitR)] ?? 'none',
                    unrealized_return: unreal != null ? `${unreal >= 0 ? '+' : ''}${unreal.toFixed(3)}%` : 'unknown (stale mark)',
                    unrealized_return_value: unreal,
                } : {}),
            } : {}),
        };
    }
    const tradeOpenBlock = Number(evalAccount.tradeOpenBlock);
    const blocksSinceOpen = tradeOpenBlock > 0 ? blockNumber - tradeOpenBlock : 0;
    // Format pct values as labelled strings so the LLM can't mistake a basis-point fraction
    // (e.g. 0.09 means 0.09%, NOT 9%). Mercury and qwen3 both got this wrong on raw numerics.
    //
    // BUG WORKAROUND: contract's getEvalStatus.returnBps is uint256 and only set when
    // virtualBalance >= 1e18 — i.e. it CLAMPS NEGATIVE RETURNS AT ZERO. That makes
    // "+0.00%" indistinguishable from "-1.74%" in the LLM's view. Compute the real
    // signed return directly from the raw evals(addr).virtualBalance instead.
    const vbN = Number(evalAccount.virtualBalance ?? 1_000_000_000_000_000_000n) / 1e18;
    const hwmRaw = Number(evalAccount.highWaterMark ?? 0n) / 1e18;
    const hwmN = hwmRaw > vbN ? hwmRaw : vbN;  // peak virtualBalance; never below current
    const returnPct = (vbN - 1) * 100;  // signed; can be negative
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
        // Live market price (Hermes) — NOT the on-chain price, which can be frozen for hours on a
        // sparsely-pushed testnet, blinding the agent to movement mid-trade. Falls back to on-chain.
        let current = evalSpot;
        try {
            const live = await fetchLiveSpot(network, network?.pythPriceIds?.[evalAssetId]);
            if (live && live > 0) current = live;
            else log('WARN', 'live-spot-unavailable', { assetId: evalAssetId, using: 'on-chain fallback' });
        } catch (e) {
            log('WARN', 'live-spot-failed', { assetId: evalAssetId, error: String(e.message || e).slice(0, 120) });
        }
        const unrealizedPct = entry > 0 ? ((current - entry) / entry) * 100 : 0;
        openTradeBlock = {
            entry_price_usd: entry.toFixed(2),
            current_price_usd: current.toFixed(2),
            unrealized_return: `${unrealizedPct >= 0 ? '+' : ''}${unrealizedPct.toFixed(3)}%`,
            unrealized_return_value: unrealizedPct,  // numeric — used by hint logic, stripped from LLM output
            current_trade_blocks_elapsed: blocksSinceOpen,
            current_trade_can_close: blocksSinceOpen >= 10,
        };
    }
    return {
        address: me,
        ethBalanceWei: ethBal,  // kept for guardrail check, stripped before LLM prompt
        evalVb: vbN,            // helper for deterministic exit logic — stripped before LLM prompt
        evalHwm: hwmN,          // peak virtualBalance — stripped before LLM prompt
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
            cumulative_return: `${returnPct >= 0 ? '+' : ''}${returnPct.toFixed(2)}%`,
            target_return: `${targetPct.toFixed(2)}%`,
            return_gap_to_pass: `${(targetPct - returnPct).toFixed(2)}%`,
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
        desk,
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
// Restrict the tradeable universe to these symbols (comma-separated env). Empty = all listed
// assets. Use it when the Pyth API key is only entitled to a subset of feeds — an un-entitled
// feed 403s at Hermes and the trade would revert on-chain (StaleOracle), wasting gas. The
// filter is applied before signals are scored, so the agent never picks an un-entitled asset.
const ASSET_ALLOWLIST = (process.env.AGENT_ASSETS || '').split(',').map(x => x.trim().toUpperCase()).filter(Boolean);
const assetAllowed = (name) => ASSET_ALLOWLIST.length === 0 || ASSET_ALLOWLIST.includes(String(name).toUpperCase());

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
const MIN_EDGE_SCORE = Number(process.env.EVAL_MIN_EDGE_SCORE || 0.50);
const SIGNAL_STYLE = (process.env.AGENT_SIGNAL_STYLE || 'blend').toLowerCase();  // 'playbook' | 'momentum' | 'blend' (YouHaveOptions bake-off)

// Build per-asset signals + a cross-asset ranking. Each asset has its own trend/momentum/range
// for both 15m and 1h timeframes. The 1h is the higher-timeframe context — entries get a
// confluence bonus when 15m and 1h trends agree, and a penalty when they fight.
const spotOf = (state, asset) => Number(state.assets.find(a => a.name === String(asset).toUpperCase())?.price || 0);

function restoreWatchPlan() {
    try { if (existsSync(WATCH_PLAN_PATH)) STATE.watchPlan = JSON.parse(readFileSync(WATCH_PLAN_PATH, 'utf8')); } catch {}
}
function saveWatchPlan() {
    try { writeFileSync(WATCH_PLAN_PATH, JSON.stringify(STATE.watchPlan)); } catch {}
}

// Normalize the LLM's raw "watch" object into a stored plan: resolve each level's cross direction
// and the side price sits on now (to detect a genuine cross, never an instant self-trigger),
// resolve wake_at_utc to the next absolute UTC occurrence, and clamp the idle cap.
function setWatchPlan(raw, state, nowSec) {
    if (!raw || typeof raw !== 'object') {
        STATE.watchPlan = { setAt: nowSec, levels: [], armed: [], wakeAt: null, maxIdleSec: MAX_WATCH_IDLE_MIN * 60 };
        saveWatchPlan(); return;
    }
    const levels = (Array.isArray(raw.levels) ? raw.levels : []).slice(0, 8).map(l => {
        const asset = String(l?.asset || '').toUpperCase();
        const price = Number(l?.price);
        if (!asset || !(price > 0) || !assetAllowed(asset)) return null;
        const spot = spotOf(state, asset);
        const sideNow = spot && spot >= price ? 'above' : 'below';
        const dir = (l.dir === 'above' || l.dir === 'below') ? l.dir : (sideNow === 'above' ? 'below' : 'above');
        return { asset, price, dir };
    }).filter(Boolean);
    const armed = levels.map(l => { const spot = spotOf(state, l.asset); return spot && spot >= l.price ? 'above' : 'below'; });
    let wakeAt = null;
    if (typeof raw.wake_at_utc === 'string' && /^\d{1,2}:\d{2}$/.test(raw.wake_at_utc)) {
        const [h, mi] = raw.wake_at_utc.split(':').map(Number);
        const d = new Date(nowSec * 1000); d.setUTCHours(h, mi, 0, 0);
        let t = Math.floor(d.getTime() / 1000); if (t <= nowSec) t += 86400;
        wakeAt = t;
    }
    const maxIdleSec = Math.min(Math.max(Number(raw.max_idle_min) || MAX_WATCH_IDLE_MIN, 5), 24 * 60) * 60;
    STATE.watchPlan = { setAt: nowSec, levels, armed, wakeAt, maxIdleSec };
    saveWatchPlan();
}

// Has any of the agent's declared triggers fired? Returns {triggered, reason}.
function evalWatchTriggers(plan, state, nowSec) {
    if (!plan) return { triggered: true, reason: 'no-plan' };
    for (let i = 0; i < plan.levels.length; i++) {
        const lv = plan.levels[i];
        const spot = spotOf(state, lv.asset);
        if (!spot) continue;
        const side = spot >= lv.price ? 'above' : 'below';
        if (side !== plan.armed[i] && side === lv.dir) {
            return { triggered: true, reason: `${lv.asset} crossed ${lv.dir} ${lv.price} (now ${spot.toFixed(4)})` };
        }
    }
    if (plan.wakeAt && nowSec >= plan.wakeAt) return { triggered: true, reason: `scheduled wake ${new Date(plan.wakeAt * 1000).toISOString().slice(11, 16)} UTC` };
    if (nowSec - plan.setAt >= plan.maxIdleSec) return { triggered: true, reason: `max-idle ${Math.round(plan.maxIdleSec / 60)}m elapsed` };
    return { triggered: false, reason: null };
}

// Compact watch-plan summary for the hold log — distance to each level + time remaining.
function summarizeWatch(plan, state, nowSec) {
    if (!plan) return null;
    return {
        levels: plan.levels.map((lv, i) => {
            const spot = spotOf(state, lv.asset);
            return `${lv.asset} ${lv.dir} ${lv.price} (${spot ? ((spot - lv.price) / lv.price * 100).toFixed(2) + '%' : '?'})`;
        }),
        wakeAt: plan.wakeAt ? new Date(plan.wakeAt * 1000).toISOString().slice(11, 16) + 'UTC' : null,
        idleLeftMin: Math.max(0, Math.round((plan.maxIdleSec - (nowSec - plan.setAt)) / 60)),
    };
}

// Is `date` (UTC) inside any configured killzone window? Empty config = always true (gate off).
function inKillzone(date, zones = ICT_KILLZONES) {
    if (!zones.length) return true;
    const mins = date.getUTCHours() * 60 + date.getUTCMinutes();
    return zones.some(([a, b]) => a <= b ? (mins >= a && mins < b) : (mins >= a || mins < b));
}

// Objective key levels from 1h candles (newest-first): prior-day and prior-session highs/lows —
// the levels liquidity rests at and price reacts to. Deliberately not the speculative ICT
// constructs (FVGs, order blocks); just levels worth waking for.
function computeKeyLevels(candles1h) {
    if (!candles1h || candles1h.length < 8) return null;
    const day = candles1h.slice(0, 24), sess = candles1h.slice(0, 8);
    return {
        prior_day_high: Math.max(...day.map(c => c.high)),
        prior_day_low:  Math.min(...day.map(c => c.low)),
        session_high:   Math.max(...sess.map(c => c.high)),
        session_low:    Math.min(...sess.map(c => c.low)),
    };
}

// Nearest key level to `spot` and its distance in %.
function nearestLevel(spot, levels) {
    if (!levels || !spot) return null;
    let best = null;
    for (const [name, v] of Object.entries(levels)) {
        if (!(v > 0)) continue;
        const distPct = Math.abs(spot - v) / spot * 100;
        if (!best || distPct < best.distPct) best = { name, level: v, distPct };
    }
    return best;
}

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
        const momScore   = (m1 * (trendBonus15 > 0 ? 1.5 : trendBonus15 < 0 ? 0 : 1) + 0.5 * m6) * confluence;
        // Playbook (YouHaveOptions) setup bonus: each confirmed long setup adds edge, so ETH's OWN
        // setup can clear the bar on RSI-oversold + MACD-cross + VWAP-reclaim even when raw momentum
        // is small. STYLE weights the two: 'playbook' leans on confirmations, 'momentum' on the old
        // score, default blends. Bounded so it can't run away.
        const setupBonus = Math.min(1.5, 0.4 * (s._longSetupCount || 0)
            + (s._macdCrossUp ? 0.3 : 0) + (s._orbBreakHigh ? 0.3 : 0) + (s._rsi <= 30 ? 0.3 : 0));
        const wMom = SIGNAL_STYLE === 'playbook' ? 0.5 : SIGNAL_STYLE === 'momentum' ? 1.0 : 0.8;
        const wSet = SIGNAL_STYLE === 'playbook' ? 1.5 : SIGNAL_STYLE === 'momentum' ? 0.0 : 1.0;
        const longScore  = wMom * momScore + wSet * setupBonus * (confluence >= 1 ? 1 : 0.6);
        const shortScore = (-m1 * (trendBonus15 < 0 ? 1.5 : trendBonus15 > 0 ? 0 : 1) + 0.5 * -m6) * confluence;
        return { sym, longScore, shortScore, vol, m1, trend15, trend1h, confluence, setups: s.long_setups || [], rsi: s.rsi_14, macd: s.macd, pvv: s.price_vs_vwap };
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
        rsi: b.rsi, macd: b.macd, price_vs_vwap: b.pvv, long_setups: b.setups,
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

    // --- YouHaveOptions playbook indicators (long-side): RSI, MACD, VWAP, ORB, volume spike ---
    // Ported from the SPY-0DTE desk bot; adapted to 24/7 spot. Computed on a chronological
    // (oldest->newest) view since candles arrive newest-first.
    const chrono = candles.slice().reverse();
    const cCloses = chrono.map(c => c.close);
    const ema = (arr, n) => { const k = 2 / (n + 1); let e = arr[0]; for (let i = 1; i < arr.length; i++) e = arr[i] * k + e * (1 - k); return e; };
    const emaSeries = (arr, n) => { const k = 2 / (n + 1); const out = [arr[0]]; for (let i = 1; i < arr.length; i++) out.push(arr[i] * k + out[i-1] * (1 - k)); return out; };
    // RSI(14)
    let rsi = 50;
    if (cCloses.length >= 15) {
        let g = 0, l = 0; for (let i = cCloses.length - 14; i < cCloses.length; i++) { const d = cCloses[i] - cCloses[i-1]; if (d >= 0) g += d; else l -= d; }
        const rs = l === 0 ? 100 : g / l; rsi = l === 0 ? 100 : 100 - 100 / (1 + rs);
    }
    // MACD(12,26,9): histogram + whether it just crossed up (bullish) between the last two bars
    let macdHist = 0, macdCrossUp = false, macdBull = false;
    if (cCloses.length >= 26) {
        const macdLine = cCloses.map((_, i) => i >= 25 ? ema(cCloses.slice(0, i+1).slice(-26), 12) - ema(cCloses.slice(0, i+1).slice(-26), 26) : 0);
        const validMacd = macdLine.slice(25);
        const sig = emaSeries(validMacd, 9);
        const h = validMacd.map((m, i) => m - sig[i]);
        macdHist = h[h.length - 1]; const prevH = h[h.length - 2] ?? 0;
        macdBull = macdHist > 0; macdCrossUp = prevH <= 0 && macdHist > 0;
    }
    // VWAP over the window (typical price x volume) and price position vs it
    let vwap = last, aboveVwap = false;
    { let pv = 0, vv = 0; for (const c of chrono) { const tp = (c.high + c.low + c.close) / 3; pv += tp * (c.volume || 0); vv += (c.volume || 0); } if (vv > 0) vwap = pv / vv; aboveVwap = last > vwap; }
    // ORB: opening range = high/low of the oldest 4 candles in the window; break high = bullish
    const orbHigh = Math.max(...chrono.slice(0, 4).map(c => c.high));
    const orbLow = Math.min(...chrono.slice(0, 4).map(c => c.low));
    const orbBreakHigh = last > orbHigh;
    // Volume spike: latest candle vs window average
    const vols = chrono.map(c => c.volume || 0); const avgVol = vols.reduce((a,b)=>a+b,0) / Math.max(1, vols.length);
    const volRatio = avgVol > 0 ? (candles[0].volume || 0) / avgVol : 1;
    const upCandle = candles[0].close >= candles[0].open;
    // Long-side confirmations (the transferable YouHaveOptions setups)
    const longSetups = [];
    if (aboveVwap) longSetups.push('vwap_reclaim');
    if (rsi <= 35) longSetups.push('rsi_oversold');
    if (macdCrossUp) longSetups.push('macd_cross_up'); else if (macdBull) longSetups.push('macd_bullish');
    if (orbBreakHigh) longSetups.push('orb_break_high');
    if (volRatio >= 1.5 && upCandle) longSetups.push('volume_spike_up');

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
        rsi_14: rsi.toFixed(0),
        macd_hist: macdHist.toFixed(2),
        macd: macdCrossUp ? 'CROSS_UP' : macdBull ? 'BULLISH' : 'BEARISH',
        vwap_usd: vwap.toFixed(2),
        price_vs_vwap: aboveVwap ? 'ABOVE' : 'BELOW',
        orb_high_usd: orbHigh.toFixed(2),
        orb_break_high: orbBreakHigh,
        volume_ratio: volRatio.toFixed(2),
        long_setups: longSetups,   // active YouHaveOptions-style long confirmations
        _longSetupCount: longSetups.length,   // numeric, for scoring
        _rsi: rsi, _aboveVwap: aboveVwap, _macdCrossUp: macdCrossUp, _orbBreakHigh: orbBreakHigh,
    };
}

// Compute the set of actions that are legal given current state. The LLM has hallucinated
// action names ("OPEN_LONG") and tried funded-only actions while in eval — the whitelist
// stops those from ever reaching the contract and surfaces a clear list in the prompt so
// the LLM doesn't have to derive it from the action reference.
// Deterministic eval-trade exit. Eval is 1x long-only and drawdown is realized only at close
// (virtualBalance *= spot/entry), so the right policy is: bank wins, trail a fading win before
// it round-trips, and cut a loser early ONLY while realizing it stays above the 5%-from-peak
// fail floor. Returns a reason string to close now, or null to keep holding.
function evalExitDecision(state) {
    const open = state.eval?.open_trade;
    if (!open || !open.current_trade_can_close) return null;  // 10-block hold not satisfied
    const r = open.unrealized_return_value;                   // signed % since entry
    const peak = STATE.evalTradePeakR ?? r;
    const vb = state.evalVb ?? 1;
    const hwm = Math.max(state.evalHwm ?? vb, vb);

    // 1. Hard take-profit — bank a strong win toward the +8% target.
    if (r >= EVAL_TP_PCT) return `take-profit +${r.toFixed(2)}% >= ${EVAL_TP_PCT}%`;

    // 2. Trailing stop — a win that armed and is now fading; lock it before it round-trips to flat.
    if (peak >= EVAL_TRAIL_ARM_PCT && r > 0 && r <= peak - EVAL_TRAIL_GIVEBACK_PCT) {
        return `trailing-stop: peaked +${peak.toFixed(2)}%, now +${r.toFixed(2)}% (gave back >=${EVAL_TRAIL_GIVEBACK_PCT}%)`;
    }

    // 3. Stop-loss — cut a loser, but only if realizing it doesn't breach the drawdown floor.
    if (r <= -EVAL_SL_PCT) {
        const newVb = vb * (1 + r / 100);
        const floor = hwm * (1 - EVAL_DRAWDOWN_FAIL_BPS / 10_000);
        if (newVb > floor * 1.002) return `stop-loss ${r.toFixed(2)}% <= -${EVAL_SL_PCT}% (drawdown-safe)`;
        // Otherwise cutting now would FAIL the eval on drawdown — hold; the price recovering back
        // above the floor (or to profit) will trigger the trailing/take-profit branch instead.
    }

    // 4. Time-stop — a trade stuck in the dead zone (never armed a win, never hit the stop) ties
    // up the single position slot for the whole eval window. After EVAL_TIME_STOP_BLOCKS held with
    // no meaningful progress, close it (when drawdown-safe) to free the slot and re-enter on a
    // fresh setup. Skips winners that have armed the trail (those are branch 2's job).
    const heldBlocks = open.current_trade_blocks_elapsed ?? 0;
    if (heldBlocks >= EVAL_TIME_STOP_BLOCKS && r < EVAL_TRAIL_ARM_PCT) {
        const newVb = vb * (1 + r / 100);
        const floor = hwm * (1 - EVAL_DRAWDOWN_FAIL_BPS / 10_000);
        if (newVb > floor * 1.002) {
            return `time-stop: held ${heldBlocks} >= ${EVAL_TIME_STOP_BLOCKS} blocks at ${r.toFixed(2)}% (no progress) — freeing slot`;
        }
    }
    return null;
}

// Deterministic management of the desk's open ETH book. Take-profit, stop-loss and max-hold
// live ON-CHAIN in the bracket set at entry (any keeper can executeExit them). What's left for the
// agent's code: (1) execute its own bracket the moment it hits — don't wait for a keeper;
// (2) trail: tighten the on-chain stop as the trade works (updateBracket can only tighten);
// (3) floor-guard: a keeper LIQUIDATION (drawdown floor) forfeits the deposit, so exit first.
// Returns { action, reason, args? } or null.
function deskExitDecision(state) {
    const d = state.desk;
    if (!d?.mark_fresh || d?.unrealized_return_value == null) return null;   // never act on a stale mark
    if (d.exit_reason_now && d.exit_reason_now !== 'none') {
        return { action: 'DESK_EXECUTE_EXIT', reason: `bracket hit on-chain: ${d.exit_reason_now}` };
    }
    const r = d.unrealized_return_value;
    const value = Number(d?.book_value_usdc), floor = Number(d?.drawdown_floor_usdc);
    if (value > 0 && floor > 0 && value <= floor * 1.01) {
        return { action: 'EXIT_ETH', reason: `desk floor-guard: marked ${value.toFixed(2)} within 1% of liquidation floor ${floor.toFixed(2)}` };
    }
    const peak = STATE.deskPeakR ?? r;
    if (peak >= DESK_TRAIL_ARM_PCT && r > 0) {
        // Trail the on-chain stop to (peak - giveback) — only when that is above the current stop.
        const entryPx = Number(d.entry_price), curSl = Number(d.sl_price), curTp = Number(d.tp_price);
        const trailPx = entryPx * (1 + (peak - DESK_TRAIL_GIVEBACK_PCT) / 100);
        if (entryPx > 0 && trailPx > curSl * 1.001 && trailPx < curTp) {
            return { action: 'DESK_UPDATE_BRACKET', reason: `trail: peaked +${peak.toFixed(2)}%, stop -> ${trailPx.toFixed(2)}`,
                     args: { tp: curTp, sl: trailPx } };
        }
    }
    return null;
}

// Bracket for ENTER_ETH: the LLM's tp/sl if given, else the code's asymmetric defaults; both
// clamped to the contract's bounds around the live spot. Returns Pyth-scale (1e8) BigInts.
function deskBracket(spot, args, bounds) {
    const maxStop = (bounds?.max_stop_pct ?? 3) / 100, maxTarget = (bounds?.max_target_pct ?? 10) / 100;
    let tp = Number(args?.tp) > 0 ? Number(args.tp) : spot * (1 + DESK_TP_PCT / 100);
    let sl = Number(args?.sl) > 0 ? Number(args.sl) : spot * (1 - DESK_SL_PCT / 100);
    tp = Math.min(tp, spot * (1 + maxTarget) * 0.999);
    sl = Math.max(sl, spot * (1 - maxStop) * 1.001);
    if (!(sl < spot && spot < tp)) { tp = spot * (1 + DESK_TP_PCT / 100); sl = spot * (1 - DESK_SL_PCT / 100); }
    return { tp: BigInt(Math.round(tp * 1e8)), sl: BigInt(Math.round(sl * 1e8)), tpUsd: tp, slUsd: sl };
}

function computeValidActions(state) {
    // Graduated: admitted to the real desk. Probation entries (PropFund) stop — tick() still
    // closes any open eval trade deterministically, but the LLM's job is now the desk book.
    if (state.desk?.admitted) {
        return ['WAIT', state.desk.in_eth ? 'EXIT_ETH' : 'ENTER_ETH'];
    }
    const base = _baseValidActions(state);
    if (state.desk?.wired && !state.desk.admitted && state.desk.qualifies) base.push('DESK_ADMIT');
    return base;
}

function _baseValidActions(state) {
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
    const { ethBalanceWei, evalVb, evalHwm, ...stateForLlm } = state;
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

    // Hard state-machine hints only. Anything strategy-flavoured (when to enter, when to
    // exit, threshold values, trend reading) belongs to the model — those are the things
    // we want the agent to figure out itself. We only report mechanical state and which
    // actions the contract will reject.
    if (state.eval.active && state.eval.in_virtual_trade && open && !open.current_trade_can_close) {
        hints.push(`Open trade is ${open.unrealized_return}, hold not satisfied yet (${open.current_trade_blocks_elapsed}/10 blocks). CLOSE_EVAL_TRADE will revert with TradeTooShort.`);
    }
    if (state.eval.active && !state.eval.in_virtual_trade) {
        hints.push(`No open virtual trade — CLOSE_EVAL_TRADE will revert with EvalNoPosition.`);
    }
    if (state.eval.active && !state.eval.passed) {
        hints.push(`EVAL NOT PASSED yet (cumulative_return=${state.eval.cumulative_return}, target=${state.eval.target_return}, gap=${state.eval.return_gap_to_pass}). CLAIM_FUNDING WILL REVERT until passed=true. Do not attempt it.`);
    }
    if (state.eval.passed) {
        hints.push(`EVAL PASSED. Next step is CLAIM_FUNDING.`);
    }
    if (state.desk?.wired && !state.desk.admitted && state.desk.qualifies) {
        hints.push(`YOU QUALIFY FOR THE REAL DESK — your probation record clears the bar. DESK_ADMIT posts a ${state.desk.deposit_required_usdc} USDC deposit and graduates you to real capital.`);
    }
    if (state.desk?.admitted) {
        hints.push(state.desk.in_eth
            ? `DESK: IN ETH — book marked ${state.desk.book_value_usdc} USDC (${state.desk.unrealized_return} vs entry), liquidation floor ${state.desk.drawdown_floor_usdc}. Exit is AUTOMATED; WAIT unless you have a strong reason to EXIT_ETH.`
            : (() => {
                // The desk trades ETH ONLY — so judge ETH's OWN setup, not the cross-asset best.
                const e = multiSignals?.per_asset?.ETH;
                const eth = e ? `ETH now: ${e.trend_short_vs_long} 15m / ${e.htf_1h?.trend_short_vs_long ?? '?'} 1h · RSI ${e.rsi_14} · MACD ${e.macd} · price ${e.price_vs_vwap} VWAP · mom ${e.momentum_1h} 1h · setups [${(e.long_setups||[]).join(', ') || 'none'}]` : 'ETH signals unavailable';
                return `DESK: IN USDC — book ${state.desk.book_usdc} USDC of allocation ${state.desk.allocation_usdc} (ladder ${state.desk.ladder_mult_now}x, realized ${state.desk.realized_pnl_usdc} vs hold-hurdle ${state.desk.hold_hurdle_usdc}, PF ${state.desk.profit_factor} over ${state.desk.desk_trades} trades). You can ONLY trade ETH here — ignore other assets' setups. ${eth}. ENTER_ETH when ETH's OWN long setup is clean (multiple confirmations: VWAP reclaim, RSI turning up from oversold, MACD cross-up, ORB break, volume) and worth clearly more than the ~0.2% round-trip cost. Otherwise WAIT.`;
            })());
    }
    // Eval entry directive: the code owns exits, so the LLM's only eval job is a clean LONG entry.
    if (state.eval.active && !state.eval.passed && !state.eval.in_virtual_trade) {
        const best = multiSignals?.best_long_setup;
        hints.push(
            `EVAL ENTRY MODE. Exits are AUTOMATED (take-profit/trailing/stop run in code once you open) — ` +
            `do NOT plan the close, just pick the best LONG entry. Open ONLY when ALL-ASSET SIGNALS show a ` +
            `non-null best_long_setup (score >= ${MIN_EDGE_SCORE}); OPEN_EVAL_TRADE on THAT asset, not a default like ETH. ` +
            (best ? `Right now best_long_setup = ${best.asset} (score ${best.score}, ${best.trend_15m}/${best.trend_1h}). ` :
                    `Right now best_long_setup is null — no clean setup, so WAIT. `) +
            `A weak or forced entry just burns the window; WAIT costs nothing.`
        );
    }
    // No pre-eval / funded "you should trade X" hints. The model has access to all
    // per-asset signals and candle data; picking what (and whether) to trade is its job.
    // Show all-asset signals when the agent has a real choice. Hide them only when locked into
    // an open virtual trade (asset is already picked, focus on the close decision).
    const showMultiAsset = !(state.eval?.active && state.eval?.in_virtual_trade);

    return `${STATE.wokenReason ? `== WOKEN BECAUSE ==\nYour watcher re-consulted you: ${STATE.wokenReason}. Decide, then set a fresh \"watch\" plan.\n\n` : ''}
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
        // Decisions are typically <300 output tokens (one JSON object). 800 leaves headroom
        // for verbose reasoning models without burning budget on runaway completions.
        max_tokens: 800,
    };
    // (Top-level `cache_control` removed — per-block on the system message above is the
    // correct breakpoint. Top-level was causing write-without-read every tick because
    // OpenRouter places its auto-breakpoint at the end of the user message, which is fresh
    // each call.)
    // Force structured-JSON mode on every backend that supports it. OpenRouter passes this
    // through to upstream providers (Anthropic, OpenAI, etc.); local Ollama also honours it.
    // Eliminates a class of "model wrapped JSON in prose" parse failures.
    body.response_format = { type: 'json_object' };

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

// Resolve the single asset index a price-sensitive action touches, so we push ONLY that feed
// instead of all of them (each feed update is a costly Wormhole verification).
function relevantAssetId(action, state, network) {
    const names = network?.assetNames || [];
    const fromArg = () => {
        const a = action.args?.asset;
        if (typeof a === 'number' && a >= 0 && a < names.length) return a;
        if (typeof a === 'string') { const i = names.indexOf(a.toUpperCase()); if (i >= 0) return i; }
        return 0; // matches the open* handlers' ETH default
    };
    switch (action.action) {
        case 'OPEN_EVAL_TRADE':
        case 'OPEN_TRADE':       return fromArg();
        case 'CLOSE_EVAL_TRADE': return state?.eval?.asset_id ?? null;
        case 'CLOSE_TRADE':      return state?.position?.asset_id ?? null;
        default:                 return null;
    }
}

// Fetch the latest signed Pyth update VAA(s) from Hermes for `priceIds` (or all configured feeds).
// Returns the bytes[] update array (['0x...']) the router/pushPyth consume, or null off-Pyth.
async function fetchPythUpdate(network, priceIds) {
    if (!network.pythPriceIds || !network.hermesUrl) return null;
    const ids = (priceIds && priceIds.length) ? priceIds : network.pythPriceIds;
    const url = `${network.hermesUrl}/v2/updates/price/latest?` +
        ids.map(id => `ids[]=${id.startsWith('0x') ? id : '0x' + id}`).join('&');
    const res = await fetch(url, { headers: hermesHeaders({ 'User-Agent': 'propfund-agent/0.1' }) });
    if (!res.ok) throw new Error(`Hermes ${res.status}: ${await res.text().then(t => t.slice(0, 200))}`);
    const body = await res.json();
    const hex = body.binary?.data;
    if (!hex || !Array.isArray(hex)) throw new Error(`Hermes returned no data: ${JSON.stringify(body).slice(0, 200)}`);
    return hex.map(d => '0x' + d);
}

// Push a fresh Pyth update on-chain via PropFund's standalone pushPyth() — the legacy (separate-tx)
// path, used only when no router is configured. `priceIds` restricts the push to one feed.
async function refreshPythIfApplicable(propfund, network, json, priceIds) {
    const updateData = await fetchPythUpdate(network, priceIds);
    if (!updateData) return null;
    // Pyth charges per-feed (~10 wei each on Base). Send 100000 wei — rounding error in USD.
    // Pin gasLimit so ethers doesn't estimate; estimateGas is buggy when payable + bytes[] reverts
    // bubble up under some L2 RPCs. Direct send works fine.
    const tx = await propfund.pushPyth(updateData, { value: 100_000n, gasLimit: 600_000n });
    const receipt = await tx.wait();
    return { txHash: tx.hash, blockNumber: receipt.blockNumber };
}

async function executeAction(action, propfund, usdc, wallet, state, network, router) {
    const now = Math.floor(Date.now() / 1000);

    // Whitelist gate: reject any action not legal in current state. Saves gas, surfaces LLM
    // errors instantly, and stops hallucinated action names ("OPEN_LONG") from contributing
    // to on-chain reverts. Whitelist is computed from the same state the LLM saw.
    if ((action.action === 'OPEN_TRADE' || action.action === 'OPEN_EVAL_TRADE')) {
        const aid = relevantAssetId(action, state, network);
        const nm = network?.assetNames?.[aid];
        if (nm && !assetAllowed(nm)) {
            return { ok: false, action: action.action, args: action.args,
                error: `asset ${nm} not in AGENT_ASSETS allowlist (feed not entitled) — skipping`, rejectedLocally: true };
        }
    }

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
    // When set, route this action's trade through the router with these signed updates so the
    // price update + trade land in a SINGLE tx. Left null -> the price is fresh (direct trade) or
    // there's no router (legacy separate-push path below).
    let routedUpdate = null;
    if (network.pythAddr && PRICE_SENSITIVE.has(action.action)) {
        // ALWAYS refresh the price for a price-sensitive trade. PnL is virtualBalance *= closeSpot/entry
        // (eval) / spot-vs-entry (funded), so entry AND exit must be real-time prices. A feed that is
        // merely "fresh" per the contract's staleAfter window (up to 24h on testnet, where nobody pushes
        // Pyth) is FROZEN — entry==exit -> 0 PnL every trade, and the eval can never move. The earlier
        // "skip if within staleAfter" gas optimization silently broke compounding; correctness wins.
        const assetId = relevantAssetId(action, state, network);
        const feedIds = (assetId != null && network.pythPriceIds?.[assetId])
            ? [network.pythPriceIds[assetId]] : null; // null -> all feeds (safe fallback)
        if (router) {
            // Atomic path: fetch the signed update and hand it to the router, which applies it and
            // trades in one tx. No separate pushPyth. (Fetch only here; the tx fires in the switch.)
            try {
                routedUpdate = await fetchPythUpdate(network, feedIds);
            } catch (e) {
                const decoded = decodeError(e);
                log('ERROR', 'pyth-fetch-failed', { error: decoded.message });
                return { ok: false, action: action.action, error: 'pyth-fetch-failed (skipping trade — stale price would revert anyway)' };
            }
        } else {
            // Legacy: no router configured — push the single feed in a separate tx, then trade.
            let pushed = null;
            for (let attempt = 1; attempt <= 2 && !pushed; attempt++) {
                try {
                    pushed = await refreshPythIfApplicable(propfund, network, false, feedIds);
                    if (pushed) log('INFO', 'pyth-pushed', { attempt, feeds: feedIds ? feedIds.length : 'all', ...pushed });
                } catch (e) {
                    const decoded = decodeError(e);
                    log('ERROR', 'pyth-push-failed', { attempt, error: decoded.message, errorName: decoded.errorName, rawData: decoded.data });
                }
            }
            if (!pushed) {
                return { ok: false, action: action.action, error: 'pyth-push-failed (skipping trade — stale price would revert anyway)' };
            }
        }
    }

    // Rate-limit writes
    if (now - STATE.lastWriteTime < MIN_WRITE_GAP_SEC) {
        return { ok: false, action: action.action, error: `rate-limited (${MIN_WRITE_GAP_SEC - (now - STATE.lastWriteTime)}s remaining)` };
    }

    // Pre-flight: USDC allowance to the DESK for the admission deposit.
    if (action.action === 'DESK_ADMIT' && DESK) {
        const need = await DESK.AGENT_DEPOSIT();
        const allowance = await usdc.allowance(wallet.address, DESK.target);
        if (allowance < need) {
            const tx = await usdc.approve(DESK.target, (1n << 256n) - 1n);
            await tx.wait();
            log('INFO', 'desk-usdc-approved', { txHash: tx.hash });
        }
    }

    // Pre-flight: USDC allowance to PropFund (eval/claim/lp need this)
    if (['START_EVAL', 'CLAIM_FUNDING'].includes(action.action)) {
        const allowance = await usdc.allowance(wallet.address, propfund.target);
        const needed = action.action === 'START_EVAL' ? 1n : 100_000_000n;   // eval fee is 1 wei (effectively free); funded deposit is $100
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
                tx = routedUpdate
                    ? await router.openEvalTrade(routedUpdate, assetId, { value: ROUTER_VALUE, gasLimit: ROUTER_GAS })
                    : await propfund.openEvalTrade(assetId);
                break;
            }
            case 'CLOSE_EVAL_TRADE':
                tx = routedUpdate
                    ? await router.closeEvalTrade(routedUpdate, { value: ROUTER_VALUE, gasLimit: ROUTER_GAS })
                    : await propfund.closeEvalTrade();
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
                const currentDeposit = parseUnits(state.funded.deposit_usdc, 6);

                // Drawdown circuit breaker — refuse new trades if deposit has lost
                // MAX_DEPOSIT_DRAWDOWN_PCT from peak. The contract's 50% margin rule caps
                // single-trade loss; this guards against death-by-1000-cuts. Operator can
                // raise the cap, take a winner to recover, or resign to bypass.
                if (MAX_DEPOSIT_DRAWDOWN_PCT > 0) {
                    const dd = depositDrawdownPct(currentDeposit);
                    if (dd >= MAX_DEPOSIT_DRAWDOWN_PCT) {
                        throw new Error(
                            `deposit drawdown ${dd.toFixed(2)}% >= MAX_DEPOSIT_DRAWDOWN_PCT=${MAX_DEPOSIT_DRAWDOWN_PCT}% ` +
                            `(peak ${formatUnits(STATE.peakDeposit, 6)} USDC, current ${state.funded.deposit_usdc} USDC). ` +
                            `OPEN_TRADE refused. Either raise the cap, hold for a winning close, or resignFunding to exit.`
                        );
                    }
                }

                const maxMargin = currentDeposit / 2n;
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

                tx = routedUpdate
                    ? await router.openTrade(routedUpdate, assetId, sizeBps, isShort, tp, sl, lev, { value: ROUTER_VALUE, gasLimit: ROUTER_GAS })
                    : await propfund.openTrade(assetId, sizeBps, isShort, tp, sl, lev);
                break;
            }
            case 'CLOSE_TRADE': {
                const bps = BigInt(action.args?.bps ?? 10_000);
                tx = routedUpdate
                    ? await router.closeTrade(routedUpdate, bps, { value: ROUTER_VALUE, gasLimit: ROUTER_GAS })
                    : await propfund.closeTrade(bps);
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
            case 'DESK_ADMIT':
                tx = await DESK.admit();
                break;
            case 'ENTER_ETH': {
                // minOut from live spot (BigInt math — 1e17-scale wei overflows Number precision).
                // Protects the real fill against a stale pool price or a sandwich. 0 = accept venue price.
                const bk = await DESK.getBook(wallet.address);
                const spot = await fetchLiveSpot(network, network?.pythPriceIds?.[0]);   // ETH is index 0
                let minOut = 0n;
                if (spot && spot > 0) {
                    const priceE8 = BigInt(Math.round(spot * 1e8));
                    minOut = bk.usdc * 10n ** 20n / priceE8 * BigInt(10_000 - DESK_SLIPPAGE_BPS) / 10_000n;
                }
                if (!(spot && spot > 0)) return { ok: false, action: action.action, error: 'no live spot for the bracket' };
                const br = deskBracket(spot, action.args, state?.desk?.bracket_bounds);
                tx = await DESK.enterEth(minOut, br.tp, br.sl);
                action.args = { ...(action.args ?? {}), tp: br.tpUsd.toFixed(2), sl: br.slUsd.toFixed(2) };
                STATE.deskEntryUsdc = Number(formatUnits(bk.usdc, 6));
                STATE.deskPeakR = 0;
                saveDeskState();
                break;
            }
            case 'DESK_UPDATE_BRACKET': {
                tx = await DESK.updateBracket(BigInt(Math.round(Number(action.args.tp) * 1e8)), BigInt(Math.round(Number(action.args.sl) * 1e8)));
                break;
            }
            case 'DESK_EXECUTE_EXIT': {
                tx = await DESK.executeExit(wallet.address);
                STATE.deskEntryUsdc = null;
                STATE.deskPeakR = null;
                saveDeskState();
                break;
            }
            case 'EXIT_ETH': {
                const bk = await DESK.getBook(wallet.address);
                const spot = await fetchLiveSpot(network, network?.pythPriceIds?.[0]);
                let minOut = 0n;
                if (spot && spot > 0) {
                    const priceE8 = BigInt(Math.round(spot * 1e8));
                    minOut = bk.eth * priceE8 / 10n ** 20n * BigInt(10_000 - DESK_SLIPPAGE_BPS) / 10_000n;
                }
                tx = await DESK.exitEth(minOut);
                STATE.deskEntryUsdc = null;
                STATE.deskPeakR = null;
                saveDeskState();
                break;
            }
            case 'DESK_CLAIM':
                tx = await DESK.claim();
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

// Append one action to the rolling history (in-memory + disk so it survives restarts).
function pushHistory(action, args, result, reasoning) {
    const histEntry = {
        ts: new Date().toISOString(),
        action,
        args: args ?? null,
        ok: result.ok,
        error: result.error ?? null,
        reasoning: reasoning?.slice(0, 200),
    };
    STATE.history.push(histEntry);
    if (STATE.history.length > 20) STATE.history.shift();
    try { appendFileSync(HISTORY_PATH, JSON.stringify(histEntry) + '\n'); } catch {}
}

async function tick(ctx) {
    const { propfund, provider, usdc, wallet } = ctx;
    const state = await readState(propfund, provider, usdc, wallet, ctx.net, ctx.lens);

    // Soft guardrail: skip the tick if ETH is too low to pay gas. Don't exit — when the
    // wallet is topped up the agent recovers automatically on the next cadence.
    // (Exiting here + podman's --restart=unless-stopped causes a hot-loop crashloop.)
    if (state.ethBalanceWei < MIN_ETH_WEI) {
        log('WARN', 'low-eth-skip', { balance: state.balances.eth });
        return;
    }

    // Track peak funded deposit so the drawdown circuit breaker has a baseline. Persists
    // across container restarts via PEAK_DEPOSIT_PATH.
    if (state.funded?.active && state.funded.deposit_usdc) {
        const currentDeposit = parseUnits(state.funded.deposit_usdc, 6);
        recordPeakDeposit(currentDeposit);
    }

    // Poll faster while any position is open so the exit logic catches the peak (a +3% spike
    // can fully reverse inside one 5-minute idle tick). Idle/entry-hunting stays on CADENCE_SEC.
    STATE.fastPoll = Boolean(state.eval?.in_virtual_trade) || Boolean(state.position) || Boolean(state.desk?.in_eth);

    // --- Graduation is mechanical, not a market call ---
    // If the probation record clears the desk bar (or the firm preapproved us), admit
    // deterministically — before any entry gate and without asking the LLM. Same principle as
    // exits: the model owns ENTRIES (a judgment); admission is a one-time state transition the
    // code owns, so a cautious model can't skip it and a watch-hold can't stall it.
    if (state.desk?.wired && !state.desk.admitted && state.desk.qualifies) {
        const result = await executeAction({ action: 'DESK_ADMIT', reasoning: 'probation record clears the desk bar' },
            propfund, usdc, wallet, state, ctx.net, ctx.router);
        log(result.ok ? 'EXEC' : 'ERROR', result.ok ? 'desk-graduated' : 'desk-admit-failed', result);
        pushHistory('DESK_ADMIT', null, result, 'graduated to the real desk (rule, no LLM)');
        return;   // re-read state next tick with the book in place
    }

    // --- Claims are a mechanic, not a market call ---
    // Unclaimed winnings are the collateral that lets the book scale; claiming early caps the
    // ladder at whatever the deposit covers. So the code only claims once the allocation is at its
    // hard cap (earned can't buy more book) and something meaningful has accrued.
    if (state.desk?.admitted && state.desk.at_max_allocation && Number(state.desk.earned_usdc) >= DESK_CLAIM_MIN_USDC) {
        const result = await executeAction({ action: 'DESK_CLAIM', reasoning: 'ladder capped; sweep earned share' },
            propfund, usdc, wallet, state, ctx.net, ctx.router);
        log(result.ok ? 'EXEC' : 'ERROR', result.ok ? 'desk-claimed' : 'desk-claim-failed', { earned: state.desk.earned_usdc, ...result });
    }

    // --- Desk position (real 1x ETH book): deterministic exit management (no LLM call) ---
    // Same philosophy as the eval exit manager: code owns exits. The stop sits well inside the
    // desk's drawdown floor so a keeper never liquidates us (that forfeits the deposit).
    if (state.desk?.admitted && state.desk?.in_eth && (!state.desk.mark_fresh || state.desk.unrealized_return_value == null)) {
        // Can't value the book right now — hold. A stale Pyth mark must never read as a loss.
        log('WARN', 'desk-hold-stale-mark', { book_eth: state.desk.book_eth, floor: state.desk.drawdown_floor_usdc });
        if (!(state.eval?.active && state.eval?.in_virtual_trade)) return;
    } else if (state.desk?.admitted && state.desk?.in_eth) {
        const r = state.desk.unrealized_return_value;
        STATE.deskPeakR = STATE.deskPeakR === null ? r : Math.max(STATE.deskPeakR, r);
        saveDeskState();
        const dec = deskExitDecision(state);
        if (dec) {
            const result = await executeAction({ action: dec.action, args: dec.args, reasoning: dec.reason }, propfund, usdc, wallet, state, ctx.net, ctx.router);
            const ev = dec.action === 'DESK_UPDATE_BRACKET' ? 'desk-trail' : 'desk-exit';
            log(result.ok ? 'EXEC' : 'ERROR', result.ok ? `${ev}-ok` : `${ev}-failed`, { reason: dec.reason, ...result });
            pushHistory(dec.action, dec.args ?? null, result, dec.reason);
        } else {
            log('EXEC', 'desk-hold', {
                unrealized: state.desk.unrealized_return,
                peak: STATE.deskPeakR != null ? `${STATE.deskPeakR.toFixed(3)}%` : null,
                bracket: `${state.desk.sl_price} / ${state.desk.entry_price} / ${state.desk.tp_price}`,
                held_h: state.desk.held_hours != null ? Number(state.desk.held_hours.toFixed(1)) : null,
                book_value: state.desk.book_value_usdc, floor: state.desk.drawdown_floor_usdc,
                allocation: state.desk.allocation_usdc, ladder: state.desk.ladder_mult_now,
                keeper_liquidatable: state.desk.liquidatable_by_keeper,
            });
        }
        // Still let an open eval trade be managed below; never consult the LLM while in ETH.
        if (!(state.eval?.active && state.eval?.in_virtual_trade)) return;
    }

    // --- Eval position: deterministic exit management (no LLM call) ---
    // Eval is 1x long-only; once a trade is open the close is rule-based (take-profit / trailing /
    // drawdown-safe stop in evalExitDecision) — timing an LLM can't hit on a multi-minute tick.
    // The LLM owns ENTRIES; here we either fire a rule-based exit or hold, skipping the
    // (paralysis-prone, costly) LLM close call entirely.
    if (state.eval?.active && state.eval?.in_virtual_trade) {
        const open = state.eval.open_trade;
        const r = open?.unrealized_return_value ?? 0;
        STATE.evalTradePeakR = STATE.evalTradePeakR === null ? r : Math.max(STATE.evalTradePeakR, r);

        const exitReason = open?.current_trade_can_close ? evalExitDecision(state) : null;
        if (exitReason) {
            const result = await executeAction({ action: 'CLOSE_EVAL_TRADE', reasoning: exitReason }, propfund, usdc, wallet, state, ctx.net, ctx.router);
            log(result.ok ? 'EXEC' : 'ERROR', result.ok ? 'eval-exit-ok' : 'eval-exit-failed', { reason: exitReason, ...result });
            if (result.ok) STATE.evalTradePeakR = null;
            pushHistory('CLOSE_EVAL_TRADE', null, result, exitReason);
        } else {
            log('EXEC', 'eval-hold', {
                unrealized: open?.unrealized_return,
                peak: STATE.evalTradePeakR != null ? `${STATE.evalTradePeakR.toFixed(3)}%` : null,
                can_close: Boolean(open?.current_trade_can_close),
            });
        }
        return;
    }
    STATE.evalTradePeakR = null;  // no open eval trade — reset the trailing tracker

    // Per-trade asset selection means we need all-asset signals everywhere except mid-trade
    // (where the asset is locked until close — focus on the open trade's asset only).
    const symbols = state.assets.map(a => a.name).filter(assetAllowed);
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

    // Entry gating (flat only — exits are deterministic above). Agent-directed watch plan takes
    // precedence over the static ICT gate: if the LLM set its own wake conditions, honor them.
    STATE.wokenReason = null;
    if (AGENT_WATCH_PLAN && !state.position) {
        const nowSec = Math.floor(Date.now() / 1000);
        const trig = evalWatchTriggers(STATE.watchPlan, state, nowSec);
        if (STATE.watchPlan && !trig.triggered) {
            log('EXEC', 'watch-hold', { pending: summarizeWatch(STATE.watchPlan, state, nowSec) });
            return;
        }
        STATE.wokenReason = trig.reason;   // surfaced to the LLM so it knows why it woke
    } else if (ICT_ENTRY_GATE && !state.position) {
        const now = new Date();
        let skip = null, detail = {};
        if (!inKillzone(now)) {
            skip = 'outside-killzone';
        } else {
            const best = multiSignals?.best_long_setup;
            if (!best) {
                skip = 'no-long-setup';
            } else {
                const sym = best.asset;
                const spot = Number(state.assets.find(a => a.name === sym)?.price || 0);
                const near = nearestLevel(spot, computeKeyLevels(candleMap1h?.[sym]));
                detail = { asset: sym, spot: spot ? spot.toFixed(4) : null,
                    nearest: near ? { level: near.name, at: near.level.toFixed(4), distPct: Number(near.distPct.toFixed(3)) } : null };
                if (!near || near.distPct > ICT_LEVEL_PROX_PCT) skip = 'no-level-in-range';
            }
        }
        if (skip) {
            log('EXEC', 'entry-gate-skip', { reason: skip, ...detail });
            pushHistory('WAIT', null, { ok: true, action: 'WAIT' }, `ICT entry-gate: ${skip}`);
            return;
        }
        log('EXEC', 'entry-gate-open', detail);
    }

    // Prompt caching disabled. Anthropic prompt caching via OpenRouter's /chat/completions
    // endpoint doesn't deliver: empirically `cache_write_tokens` lands but `cached_tokens`
    // stays 0 across follow-up calls — caching the full prompt-with-fresh-user-message
    // every tick, paying the 1.25x write premium, never benefiting from reads. Real fix
    // would be to call OpenRouter's /api/v1/messages (Anthropic-native passthrough) instead
    // and place the cache breakpoint at the system/user boundary.
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
    if (AGENT_WATCH_PLAN && !state.position) {
        setWatchPlan(llmResult.parsed.watch, state, Math.floor(Date.now() / 1000));
        log('EXEC', 'watch-set', summarizeWatch(STATE.watchPlan, state, Math.floor(Date.now() / 1000)));
    }

    // Deterministic asset selection for eval entries: the LLM decides WHETHER to enter; the
    // runtime enforces WHICH asset (the top-ranked momentum setup) and vetoes the entry when
    // there's no clean setup. Stops the agent from defaulting to ETH or forcing a weak entry —
    // the #1 way it grinds the eval window to net-flat.
    if (llmResult.parsed.action === 'OPEN_EVAL_TRADE') {
        const best = multiSignals?.best_long_setup;
        if (!best) {
            log('EXEC', 'entry-vetoed', { reason: `no best_long_setup >= ${MIN_EDGE_SCORE} edge — forcing WAIT` });
            pushHistory('WAIT', null, { ok: true, action: 'WAIT' }, 'entry vetoed: no clean long setup (runtime)');
            return;
        }
        const forced = best.asset;
        if (llmResult.parsed.args?.asset !== forced) {
            log('EXEC', 'entry-asset-override', { llmPicked: llmResult.parsed.args?.asset ?? null, forced, score: best.score });
        }
        llmResult.parsed.args = { ...(llmResult.parsed.args || {}), asset: forced };
    }

    const result = await executeAction(llmResult.parsed, propfund, usdc, wallet, state, ctx.net, ctx.router);
    log(result.ok ? 'EXEC' : 'ERROR', result.ok ? 'action-ok' : 'action-failed', result);

    pushHistory(llmResult.parsed.action, llmResult.parsed.args ?? null, result, llmResult.parsed.reasoning);

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

    // Asset-mapping runtime guard: catches networks.js drift vs on-chain priceIds before
    // any tx goes out. Hard-fail at startup rather than silently trade the wrong asset.
    try {
        await assertAssetMapping(ctx.propfund, ctx.net);
    } catch (e) {
        process.stderr.write(`FATAL: ${e.message}\n`);
        log('FATAL', 'asset-mapping-mismatch', { error: e.message });
        process.exit(1);
    }

    restoreHistory();
    restorePeakDeposit();
    restoreWatchPlan();
    restoreDeskState();
    DESK = ctx.desk;
    log('INFO', 'agent-start', {
        network: ctx.net.key,
        address: ctx.wallet.address,
        model: MODEL,
        llmBaseUrl: LLM_BASE_URL,
        cadenceSec: CADENCE_SEC,
        logPath: LOG_PATH,
        historyPath: HISTORY_PATH,
        restoredHistoryCount: STATE.history.length,
        peakDeposit: STATE.peakDeposit.toString(),
        maxDepositDrawdownPct: MAX_DEPOSIT_DRAWDOWN_PCT,
        evalExit: { tpPct: EVAL_TP_PCT, trailArmPct: EVAL_TRAIL_ARM_PCT, trailGivebackPct: EVAL_TRAIL_GIVEBACK_PCT, slPct: EVAL_SL_PCT, timeStopBlocks: EVAL_TIME_STOP_BLOCKS },
        fastCadenceSec: FAST_CADENCE_SEC,
        desk: ctx.net.deskAddr || null,
    });

    // One-time: authorize the atomic-update router as this trader's controller so it can drive the
    // *For trade entrypoints on our behalf (update + trade in one tx). Idempotent. If it can't be
    // confirmed, disable routing and fall back to the proven legacy separate-push path.
    if (ctx.router) {
        let authorized = false;
        try {
            const auth = await ctx.propfund.controllers(ctx.wallet.address);
            const current = (auth.agent ?? auth[0] ?? '').toLowerCase();
            if (current === ctx.net.routerAddr.toLowerCase()) {
                authorized = true;
                log('INFO', 'router-already-authorized', { router: ctx.net.routerAddr });
            } else {
                const cap = parseUnits('1000000', 6); // 1M USDC — far above any single-trade notional
                const expiry = BigInt(Math.floor(Date.now() / 1000) + 10 * 365 * 24 * 3600);
                const tx = await ctx.propfund.setController(ctx.net.routerAddr, cap, expiry);
                await tx.wait();
                authorized = true;
                log('INFO', 'router-authorized', { router: ctx.net.routerAddr, txHash: tx.hash });
            }
        } catch (e) {
            log('ERROR', 'router-authorize-failed', { error: e.message });
        }
        if (!authorized) {
            ctx.router = null;
            log('WARN', 'router-disabled', { reason: 'authorization unconfirmed — using legacy push path' });
        }
    }

    let stopped = false;
    const stop = () => { if (!stopped) { stopped = true; log('INFO', 'sigint', {}); } };
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);

    // Watchdog: a tick involves RPC + Hermes + LLM calls, none of which have their own timeout,
    // so a dead socket can hang the whole loop indefinitely — and because the process stays
    // *alive*, systemd's Restart=always never fires. Race every tick against a hard timeout and
    // exit on breach so Restart=always brings the agent back fresh. Generous default (3 min);
    // a normal tick is well under a minute.
    const TICK_TIMEOUT_MS = Number(process.env.AGENT_TICK_TIMEOUT_SEC || 180) * 1000;
    while (!stopped) {
        try {
            await runWithWatchdog(() => tick(ctx), TICK_TIMEOUT_MS);
        } catch (e) {
            if (e.message === 'watchdog-timeout') {
                log('FATAL', 'tick-watchdog', { timeoutSec: TICK_TIMEOUT_MS / 1000, note: 'tick hung — exiting so Restart=always recovers' });
                process.exit(1);  // systemd Restart=always (RestartSec=15) restarts the container
            }
            log('ERROR', 'tick-error', { error: e.message, stack: e.stack?.slice(0, 500) });
        }
        if (stopped) break;
        // Fast poll while a position is open (catch the exit peak), normal cadence while idle.
        const sleepSec = STATE.fastPoll ? FAST_CADENCE_SEC : CADENCE_SEC;
        await new Promise(r => setTimeout(r, sleepSec * 1000));
    }
    log('INFO', 'agent-stop', { actionsTaken: STATE.actionsTaken });
}

main().catch(e => {
    log('FATAL', 'main-crash', { error: e.message, stack: e.stack?.slice(0, 500) });
    process.exit(1);
});

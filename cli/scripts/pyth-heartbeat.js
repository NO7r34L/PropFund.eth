#!/usr/bin/env node
// Pyth price heartbeat for a local fork / devnet.
//
// A forked chain has no live Pyth publishers, so on-chain feeds stay frozen at the fork
// block and every read is `fresh:false`. The agent (correctly) refuses to trade on stale
// oracle data, so on a fork it would wait forever. This service does what real publishers
// do on public Base: every interval it pulls fresh signed VAAs from Hermes and pushes them
// on-chain via PropFund.pushPyth, keeping the feeds fresh so the agent behaves exactly as
// it would against a live chain.
//
// Not for public networks — there, real publishers keep feeds fresh and this is redundant.
//
// HEARTBEAT_SOURCE=coinbase (keyless — Pyth API keys are paid-only since 2026-09-22): the fork's
// Pyth address must hold MockPyth code (`anvil_setCode`, see DEVNET.md) — or, on public Base
// Sepolia, PROPFUND_PYTH points at a RelayPyth whose relayer is PROPFUND_KEY. Each interval this
// writes Coinbase public spot into it via one batched setSpotsE8 (moved/aged feeds only). Pair with PYTH_UPDATES=off on the
// agent/keeper. Devnet only — it trusts one relay key, which a public network must never do.
//
// Env: PROPFUND_NETWORK / PROPFUND_RPC / PROPFUND_CONTRACT, PROPFUND_KEY (gas payer),
//      PYTH_API_KEY (Hermes auth), AGENT_ASSETS (feeds to keep fresh — must be entitled),
//      HEARTBEAT_SEC (default 20), HEARTBEAT_SOURCE (hermes | coinbase, default hermes).

import { JsonRpcProvider, Wallet, NonceManager, Contract, getAddress } from 'ethers';
import { resolveNetwork, hermesHeaders } from '../src/networks.js';

const net = resolveNetwork();
const rpcUrl = process.env.PROPFUND_RPC || net.rpcUrl;
const INTERVAL = Number(process.env.HEARTBEAT_SEC || 20) * 1000;
const allow = (process.env.AGENT_ASSETS || '').split(',').map(s => s.trim().toUpperCase()).filter(Boolean);

const provider = new JsonRpcProvider(rpcUrl, net.chainId, { staticNetwork: true });
const signer = new NonceManager(new Wallet(
    (process.env.PROPFUND_KEY.startsWith('0x') ? '' : '0x') + process.env.PROPFUND_KEY, provider));
const SOURCE = (process.env.HEARTBEAT_SOURCE || 'hermes').toLowerCase();
// Each source needs only its own target: hermes pushes through PropFund, coinbase writes the oracle.
const propfund = SOURCE === 'hermes' ? new Contract(getAddress(net.contractAddr),
    ['function pushPyth(bytes[] updateData) payable'], signer) : null;
const mockPyth = SOURCE === 'coinbase' ? new Contract(getAddress(net.pythAddr),
    ['function setSpotsE8(bytes32[] ids, int256[] pricesE8)'], signer) : null;
// Only write a feed that moved >= DEVIATION_BPS or is older than MAX_AGE (keep MAX_AGE under the
// contract's tightest staleAfter, 5 min). One batched tx per tick, none when nothing qualifies —
// on a public testnet this is the difference between a faucet drip lasting days and months.
const DEVIATION_BPS = Number(process.env.HEARTBEAT_DEVIATION_BPS || 5);
const MAX_AGE_MS = Number(process.env.HEARTBEAT_MAX_AGE_SEC || 240) * 1000;
const lastPushed = new Map();   // id -> { px, at }

// Feed ids for the assets we keep fresh — the allowlist (entitled feeds) or all configured.
const ids = net.assetNames
    .map((name, i) => ({ name: name.toUpperCase(), id: net.pythPriceIds?.[i] }))
    .filter(a => a.id && (allow.length === 0 || allow.includes(a.name)));

function log(level, event, extra = {}) {
    process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), level, event, ...extra }) + '\n');
}

async function fetchVAAs() {
    const q = ids.map(a => `ids[]=${a.id.startsWith('0x') ? a.id : '0x' + a.id}`).join('&');
    const res = await fetch(`${net.hermesUrl}/v2/updates/price/latest?${q}`,
        { headers: hermesHeaders({ 'User-Agent': 'propfund-heartbeat/0.1' }) });
    if (!res.ok) throw new Error(`Hermes ${res.status}: ${(await res.text()).slice(0, 120)}`);
    const data = (await res.json())?.binary?.data;
    if (!Array.isArray(data) || !data.length) throw new Error('Hermes returned no update data');
    return data.map(d => '0x' + d);
}

// Keyless relay: Coinbase public spot -> MockPyth.setSpotE8, one tx per feed.
async function pushCoinbase() {
    const now = Date.now();
    const due = { ids: [], px: [] };
    for (const a of ids) {
        const res = await fetch(`https://api.exchange.coinbase.com/products/${a.name}-USD/ticker`,
            { headers: { 'User-Agent': 'propfund-heartbeat/0.1' } });
        if (!res.ok) throw new Error(`Coinbase ${a.name} ${res.status}`);
        const px = Number((await res.json())?.price);
        if (!(px > 0)) throw new Error(`Coinbase ${a.name} returned no price`);
        const prev = lastPushed.get(a.id);
        const moved = prev ? Math.abs(px - prev.px) / prev.px * 10_000 >= DEVIATION_BPS : true;
        if (moved || now - prev.at >= MAX_AGE_MS) {
            due.ids.push(a.id.startsWith('0x') ? a.id : '0x' + a.id);
            due.px.push({ id: a.id, px, e8: BigInt(Math.round(px * 1e8)) });
        }
    }
    if (!due.ids.length) return 0;
    const tx = await mockPyth.setSpotsE8(due.ids, due.px.map(d => d.e8), { gasLimit: 100_000n + 60_000n * BigInt(due.ids.length) });
    await tx.wait();
    for (const d of due.px) lastPushed.set(d.id, { px: d.px, at: now });
    return due.ids.length;
}

log('INFO', 'heartbeat-start', { network: net.key, rpc: rpcUrl, contract: net.contractAddr,
    feeds: ids.map(a => a.name), source: SOURCE, intervalSec: INTERVAL / 1000 });

// Keep the fork's clock at wall-time. A fork's block.timestamp drifts behind real time (it
// advances by --block-time per block, and pauses whenever anvil is stopped), while Hermes
// stamps every VAA with real now. When publishTime > block.timestamp the contract's
// `block.timestamp - publishTime` staleness math underflows and a perfectly fresh price is
// rejected as StaleOracle. Nudging the next block to wall-time before each push keeps
// block.timestamp >= publishTime, so fresh prices verify — exactly as on a live chain.
async function syncClock() {
    try {
        const now = Math.floor(Date.now() / 1000);
        const head = Number((await provider.getBlock('latest'))?.timestamp ?? 0);
        if (now > head) await provider.send('evm_setNextBlockTimestamp', [now]);
    } catch { /* best-effort; a live chain needs no help and rejects the call */ }
}

let consecutiveErrors = 0;
async function tick() {
    try {
        await syncClock();
        if (SOURCE === 'coinbase') {
            const n = await pushCoinbase();
            consecutiveErrors = 0;
            if (n) log('INFO', 'heartbeat-pushed', { feeds: n, source: 'coinbase' });
            return;
        }
        const updateData = await fetchVAAs();
        const tx = await propfund.pushPyth(updateData, { value: 300000n, gasLimit: 1_500_000n });
        await tx.wait();
        consecutiveErrors = 0;
        log('INFO', 'heartbeat-pushed', { feeds: ids.length, txHash: tx.hash });
    } catch (e) {
        consecutiveErrors++;
        log('ERROR', 'heartbeat-failed', { error: String(e.message || e).slice(0, 160), consecutiveErrors });
    }
}

await tick();
setInterval(tick, INTERVAL);

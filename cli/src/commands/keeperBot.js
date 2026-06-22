// Reference keeper bot for PropFund.
//
// What it does on each tick:
//   1. liquidate() any funded trader whose unrealized loss has eaten their margin
//   2. executeExit() any position whose TP/SL has hit at the current oracle price
//   3. forceClose() any position older than MAX_POSITION_BLOCKS (~14d)
//   4. processFundingQueue() when capacity exists and the queue isn't empty
//
// Runs as either a daemon (`keeper run`) or a one-shot pass (`keeper sweep`).
// Failed txs are logged and skipped — racing keepers are expected.
//
// Caveat: the contract currently pays no keeper fee. Running this is a public good (or
// useful for personal protection of your own positions). A production deployment should
// add a keeper-fee on liquidation/force-close before relying on third-party keepers.

import { formatUnits } from 'ethers';
import { buildContext } from '../context.js';
import { decodeError } from '../errors.js';
import { emitJson, fmtUsdc } from '../format.js';
import { isJson, flag } from '../args.js';
import { runWithWatchdog } from '../watchdog.js';

const MIN_BALANCE_WEI = 1_000_000_000_000_000n;  // 0.001 ETH — refuse to act below this

// Pull a fresh Pyth update from Hermes and push it on-chain so liquidate / executeExit see
// live prices instead of stale cached state. No-op on networks without Pyth wired (sepolia).
async function refreshPyth(propfund, network) {
    if (!network.pythPriceIds || !network.hermesUrl) return null;
    const url = `${network.hermesUrl}/v2/updates/price/latest?` +
        network.pythPriceIds.map(id => `ids[]=${id.startsWith('0x') ? id : '0x' + id}`).join('&');
    const res = await fetch(url, { headers: { 'User-Agent': 'propfund-keeper/0.1' } });
    if (!res.ok) throw new Error(`Hermes ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const body = await res.json();
    const hex = body.binary?.data;
    if (!hex || !Array.isArray(hex)) throw new Error(`Hermes returned no data`);
    const updateData = hex.map(d => '0x' + d);
    const tx = await propfund.pushPyth(updateData, { value: 100_000n, gasLimit: 600_000n });
    const receipt = await tx.wait();
    return { txHash: tx.hash, blockNumber: receipt.blockNumber };
}

// Detection: walk the funded-trader list, classify each into action buckets.
async function detectWork(propfund, json) {
    // getFundedTraders() was dropped to fit EIP-170 — walk the public array indexer.
    const count = await propfund.fundedTraderCount();
    const traders = [];
    for (let i = 0n; i < count; i++) traders.push(await propfund.fundedTraders(i));
    const work = { liquidate: [], execExit: [], forceClose: [] };
    if (traders.length === 0) return { work, traders: [], assets: [] };

    const assets = await propfund.getAssets();
    const assetPrice = new Map();
    for (const a of assets) {
        assetPrice.set(Number(a.id ?? a[0]), { price: a.price ?? a[1], fresh: a.fresh ?? a[2] });
    }

    // Read every trader's position + their isLiquidatable / positionExpired flags.
    // Three views per trader, n <= MAX_FUNDED_TRADERS = 50, so worst case 150 RPC reads.
    const reads = await Promise.all(traders.map(async t => {
        const [pos, liquidatable, expired] = await Promise.all([
            propfund.positions(t),
            propfund.isLiquidatable(t),
            propfund.positionExpired(t),
        ]);
        return { trader: t, pos, liquidatable, expired };
    }));

    for (const { trader, pos, liquidatable, expired } of reads) {
        const active = pos.active ?? pos[7];
        if (!active) continue;

        if (liquidatable) {
            work.liquidate.push(trader);
            continue;
        }
        if (expired) {
            work.forceClose.push(trader);
            continue;
        }

        // TP/SL hit detection. Done client-side so we don't burn gas on no-op executeExit calls.
        const tp = pos.tpPrice ?? pos[2];
        const sl = pos.slPrice ?? pos[3];
        if (tp === 0n && sl === 0n) continue;

        const assetId = Number(pos.assetId ?? pos[5]);
        const isShort = Boolean(pos.isShort ?? pos[8]);
        const spot = assetPrice.get(assetId);
        if (!spot || !spot.fresh) continue;

        const tpHit = isShort
            ? (tp !== 0n && spot.price <= tp)
            : (tp !== 0n && spot.price >= tp);
        const slHit = isShort
            ? (sl !== 0n && spot.price >= sl)
            : (sl !== 0n && spot.price <= sl);

        if (tpHit || slHit) work.execExit.push(trader);
    }

    return { work, traders, assets };
}

// Action: send the tx for one work item, decode any revert, return a structured result.
async function actOne(propfund, kind, target, json) {
    try {
        let tx;
        if (kind === 'liquidate') tx = await propfund.liquidate(target);
        else if (kind === 'execExit') tx = await propfund.executeExit(target);
        else if (kind === 'forceClose') tx = await propfund.forceClose(target);
        else if (kind === 'processQueue') tx = await propfund.processFundingQueue(target);  // target = max
        else throw new Error(`unknown kind ${kind}`);

        const receipt = await tx.wait();
        return { kind, target: String(target), ok: true, txHash: tx.hash, blockNumber: receipt.blockNumber };
    } catch (e) {
        const decoded = decodeError(e);
        return { kind, target: String(target), ok: false, error: decoded.errorName ?? decoded.message };
    }
}

// One pass: detect, gate, act, summarize.
async function tick({ propfund, provider, wallet, network, dryRun, maxGasGwei, json }) {
    const startedAt = Date.now();

    // Operational gates: refuse to act when the wallet is too low on ETH or gas is spiking.
    const [balance, feeData] = await Promise.all([
        provider.getBalance(wallet.address),
        provider.getFeeData(),
    ]);
    if (balance < MIN_BALANCE_WEI) {
        return { skipped: 'low-balance', balanceWei: balance.toString() };
    }
    const currentGwei = feeData.gasPrice ? Number(feeData.gasPrice / 1_000_000_000n) : null;
    if (maxGasGwei != null && currentGwei != null && currentGwei > maxGasGwei) {
        return { skipped: 'gas-too-high', currentGwei, maxGasGwei };
    }

    const { work, traders } = await detectWork(propfund, json);

    // Queue-process is independent of the per-trader work list — check separately.
    const [queueLength, canFundNow] = await Promise.all([
        propfund.queueLength(),
        propfund.canFund(),
    ]);
    const queueCandidates = (queueLength > 0n && canFundNow) ? [10n] : [];

    const totalActions = work.liquidate.length + work.execExit.length + work.forceClose.length + queueCandidates.length;

    if (dryRun) {
        return {
            tick: 'dry-run',
            tradersScanned: traders.length,
            wouldLiquidate: work.liquidate,
            wouldExecExit: work.execExit,
            wouldForceClose: work.forceClose,
            wouldProcessQueue: queueCandidates.length > 0,
            queueLength: queueLength.toString(),
            canFundNow,
        };
    }

    // Refresh Pyth once per tick if we're going to do any price-sensitive write.
    // liquidate / executeExit / forceClose all read spot — without a fresh push they'd see
    // whatever the cached on-chain price is, which can be minutes stale.
    let pythPushed = null;
    const needsFreshPrice = work.liquidate.length + work.execExit.length + work.forceClose.length > 0;
    if (needsFreshPrice && network) {
        try { pythPushed = await refreshPyth(propfund, network); }
        catch (e) {
            // Don't abort the tick — fall through and let the contract revert with StaleOracle
            // if needed. Some keeper actions (processQueue) don't need price.
            pythPushed = { error: String(e.message || e).slice(0, 200) };
        }
    }

    // Submit all actions in parallel. NonceManager (already wired) sequences nonces correctly.
    const actions = [
        ...work.liquidate.map(t => actOne(propfund, 'liquidate', t)),
        ...work.execExit.map(t => actOne(propfund, 'execExit', t)),
        ...work.forceClose.map(t => actOne(propfund, 'forceClose', t)),
        ...queueCandidates.map(max => actOne(propfund, 'processQueue', max)),
    ];
    const results = actions.length > 0 ? await Promise.all(actions) : [];

    const ok = results.filter(r => r.ok);
    const failed = results.filter(r => !r.ok);

    return {
        tick: 'done',
        elapsedMs: Date.now() - startedAt,
        tradersScanned: traders.length,
        balanceEth: formatUnits(balance, 18),
        gasGwei: currentGwei,
        pythPushed,
        attempted: results.length,
        succeeded: ok.length,
        failed: failed.length,
        results,
    };
}

function logTickSummary(net, summary) {
    if (summary.skipped === 'low-balance') {
        process.stderr.write(`[keeper] SKIP — wallet has ${formatUnits(BigInt(summary.balanceWei), 18)} ETH (need >= 0.001)\n`);
        return;
    }
    if (summary.skipped === 'gas-too-high') {
        process.stderr.write(`[keeper] SKIP — gas ${summary.currentGwei} gwei > cap ${summary.maxGasGwei}\n`);
        return;
    }
    if (summary.tick === 'dry-run') {
        const counts = `liq=${summary.wouldLiquidate.length} exit=${summary.wouldExecExit.length} force=${summary.wouldForceClose.length} queue=${summary.wouldProcessQueue ? 'yes' : 'no'}`;
        process.stdout.write(`[keeper:dry] ${summary.tradersScanned} traders scanned — ${counts}\n`);
        for (const t of summary.wouldLiquidate)  process.stdout.write(`  would liquidate ${t}\n`);
        for (const t of summary.wouldExecExit)   process.stdout.write(`  would exec-exit ${t}\n`);
        for (const t of summary.wouldForceClose) process.stdout.write(`  would force-close ${t}\n`);
        return;
    }
    const t = summary;
    process.stdout.write(`[keeper] ${t.tradersScanned} scanned in ${t.elapsedMs}ms — ${t.succeeded}/${t.attempted} ok, ${t.failed} failed (gas ${t.gasGwei ?? '?'} gwei, bal ${Number(t.balanceEth).toFixed(4)} ETH)\n`);
    for (const r of t.results) {
        if (r.ok) process.stdout.write(`  ✓ ${r.kind} ${r.target} — block ${r.blockNumber} tx ${r.txHash}\n`);
        else      process.stderr.write(`  ✗ ${r.kind} ${r.target} — ${r.error}\n`);
    }
}

// `propfund keeper sweep` — one-shot: detect, act, exit. Useful for cron.
export async function keeperSweep(args) {
    const { net, propfund, provider, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const dryRun = Boolean(flag(args, 'dry-run', false));
    const maxGasGwei = flag(args, 'max-gas-gwei', null);
    const json = isJson(args);

    const summary = await tick({
        propfund, provider, wallet, network: net,
        dryRun,
        maxGasGwei: maxGasGwei != null ? Number(maxGasGwei) : null,
        json,
    });

    if (json) emitJson({ network: net.key, ...summary });
    else logTickSummary(net, summary);
}

// `propfund keeper run` — daemon: tick every --interval seconds until SIGINT.
export async function keeperRun(args) {
    const { net, propfund, provider, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const interval = Number(flag(args, 'interval', 30));
    const dryRun = Boolean(flag(args, 'dry-run', false));
    const maxGasGwei = flag(args, 'max-gas-gwei', null);
    const json = isJson(args);

    if (!Number.isFinite(interval) || interval < 5) {
        throw new Error('--interval must be >= 5 seconds');
    }

    let stopped = false;
    const stop = () => {
        if (stopped) return;
        stopped = true;
        process.stderr.write('\n[keeper] SIGINT — finishing current tick, then exiting\n');
    };
    process.on('SIGINT', stop);
    process.on('SIGTERM', stop);

    if (!json) {
        process.stdout.write(`[keeper] starting on ${net.key} as ${wallet.address}\n`);
        process.stdout.write(`[keeper] interval=${interval}s dry-run=${dryRun} max-gas-gwei=${maxGasGwei ?? 'none'}\n`);
    }

    // Watchdog: a tick makes RPC + Hermes calls with no per-call timeout, so a dead socket can
    // hang the loop forever while the process stays alive (Restart=always never fires). Cap each
    // tick; on a hung tick, exit so Restart=always brings the keeper back fresh.
    const tickTimeoutMs = Number(process.env.KEEPER_TICK_TIMEOUT_SEC || 180) * 1000;
    let cycle = 0;
    while (!stopped) {
        cycle++;
        try {
            const summary = await runWithWatchdog(() => tick({
                propfund, provider, wallet, network: net,
                dryRun,
                maxGasGwei: maxGasGwei != null ? Number(maxGasGwei) : null,
                json,
            }), tickTimeoutMs);
            if (json) emitJson({ network: net.key, cycle, ...summary });
            else logTickSummary(net, summary);
        } catch (e) {
            if (e.message === 'watchdog-timeout') {
                process.stderr.write(`[keeper] FATAL: tick hung >${tickTimeoutMs / 1000}s — exiting so Restart=always recovers\n`);
                process.exit(1);
            }
            const decoded = decodeError(e);
            if (json) emitJson({ network: net.key, cycle, ok: false, error: decoded.message });
            else process.stderr.write(`[keeper] ERROR cycle ${cycle}: ${decoded.message}\n`);
        }

        if (stopped) break;
        await new Promise(r => setTimeout(r, interval * 1000));
    }

    if (!json) process.stdout.write(`[keeper] stopped after ${cycle} cycles\n`);
}

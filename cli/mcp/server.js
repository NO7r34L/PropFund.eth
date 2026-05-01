#!/usr/bin/env node
// MCP server for PropFund.
//
// Exposes every CLI command as a Model Context Protocol tool. Any MCP-compatible host
// (Cursor, LangGraph, custom in-house, etc.) can discover and call PropFund actions
// by name with structured arguments.
//
// Transport: stdio (the standard MCP transport — the host launches this as a child
// process and pipes JSON-RPC over stdin/stdout).
//
// Configuration: same env vars as the CLI:
//   PROPFUND_NETWORK   basesepolia | base | local        (default: basesepolia)
//   PROPFUND_RPC       override RPC URL
//   PROPFUND_KEY       hex private key (required for write tools)
//
// Example mcpServers config (most MCP hosts accept this shape):
//   {
//     "mcpServers": {
//       "propfund": {
//         "command": "node",
//         "args": ["/absolute/path/to/cli/mcp/server.js"],
//         "env": { "PROPFUND_KEY": "0x...", "PROPFUND_NETWORK": "basesepolia" }
//       }
//     }
//   }

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { parseUnits, getAddress, Contract } from 'ethers';
import { buildContext, resolveAssetId } from '../src/context.js';
import { decodeError } from '../src/errors.js';

// JSON-encode anything (BigInts, Result tuples) safely.
function jsonText(obj) {
    const s = JSON.stringify(obj, (_, v) => {
        if (typeof v === 'bigint') return v.toString();
        if (v && typeof v === 'object' && typeof v.toJSON === 'function') return v.toJSON();
        return v;
    }, 2);
    return { content: [{ type: 'text', text: s }] };
}

// Wrap an async tool so contract reverts come back as friendly errors instead of stack traces.
function safe(fn) {
    return async (args) => {
        try {
            return await fn(args ?? {});
        } catch (e) {
            const decoded = decodeError(e);
            return jsonText({
                ok: false,
                error: decoded.message,
                errorName: decoded.errorName,
                errorArgs: decoded.errorArgs,
                code: decoded.code,
            });
        }
    };
}

const server = new McpServer({
    name: 'propfund',
    version: '0.1.0',
});

// =============================================================================
// READ TOOLS — no PROPFUND_KEY needed
// =============================================================================

server.registerTool('get_assets', {
    description: 'List all tradeable assets on PropFund with their current oracle prices and freshness flags.',
    inputSchema: {},
}, safe(async () => {
    const { net, propfund } = buildContext();
    const list = await propfund.getAssets();
    const assets = list.map((a, i) => ({
        id: Number(a.id ?? a[0]),
        name: net.assetNames[i] ?? `asset_${i}`,
        priceRaw: (a.price ?? a[1]).toString(),
        priceDecimal: Number(a.price ?? a[1]) / 1e8,
        fresh: Boolean(a.fresh ?? a[2]),
    }));
    return jsonText({ ok: true, network: net.key, assets });
}));

server.registerTool('get_balance', {
    description: 'Get ETH and USDC balance for an address (defaults to the configured signer).',
    inputSchema: {
        address: z.string().optional().describe('Hex address to query. Defaults to PROPFUND_KEY signer.'),
    },
}, safe(async ({ address }) => {
    const { net, propfund, provider, usdc, wallet } = buildContext();
    const addr = address ?? (wallet && wallet.address);
    if (!addr) throw new Error('No address — pass `address` or set PROPFUND_KEY.');
    const [eth, usdcBal] = await Promise.all([
        provider.getBalance(addr),
        usdc.balanceOf(addr),
    ]);
    return jsonText({
        ok: true, network: net.key, address: addr,
        ethRaw: eth.toString(), usdcRaw: usdcBal.toString(),
        usdcDecimal: Number(usdcBal) / 1e6,
    });
}));

server.registerTool('get_stats', {
    description: 'Get a trader\'s funded-account stats: deposit, cumulative PnL, level, max deploy, and current open position if any.',
    inputSchema: {
        address: z.string().optional().describe('Trader address. Defaults to PROPFUND_KEY signer.'),
    },
}, safe(async ({ address }) => {
    const { net, propfund, wallet } = buildContext();
    const addr = address ?? (wallet && wallet.address);
    if (!addr) throw new Error('No address.');
    const s = await propfund.getTraderStats(addr);
    return jsonText({
        ok: true, network: net.key, address: addr,
        funded: Boolean(s.active),
        level: Number(s.level),
        depositRaw: s.deposit.toString(),
        cumulativePnlRaw: s.cumulativePnl.toString(),
        maxDeployRaw: s.maxDeploy.toString(),
        position: s.inPosition ? {
            assetId: Number(s.assetId),
            assetName: net.assetNames[Number(s.assetId)] ?? null,
            isShort: Boolean(s.isShort),
            deployedRaw: s.deployedAmount.toString(),
            entryPriceRaw: s.entryPrice.toString(),
            tpPriceRaw: s.tpPrice.toString(),
            slPriceRaw: s.slPrice.toString(),
        } : null,
    });
}));

server.registerTool('get_eval_status', {
    description: 'Check evaluation progress for an address: active, passed, return%, drawdown%, trades completed.',
    inputSchema: {
        address: z.string().optional().describe('Trader address. Defaults to PROPFUND_KEY signer.'),
    },
}, safe(async ({ address }) => {
    const { net, propfund, wallet } = buildContext();
    const addr = address ?? (wallet && wallet.address);
    if (!addr) throw new Error('No address.');
    const s = await propfund.getEvalStatus(addr);
    return jsonText({
        ok: true, network: net.key, address: addr,
        active: Boolean(s.active),
        passed: Boolean(s.passed),
        returnBps: Number(s.returnBps),
        targetBps: Number(s.targetBps),
        drawdownBps: Number(s.drawdownBps),
        maxDrawdownBps: Number(s.maxDrawdownBps),
        tradeCount: Number(s.tradeCount),
        tradesNeeded: Number(s.tradesNeeded),
        blocksLeft: s.blocksLeft.toString(),
        inTrade: Boolean(s.inTrade),
    });
}));

server.registerTool('get_queue_status', {
    description: 'Get the funding queue: total length, your position (if queued), and total escrowed deposits.',
    inputSchema: {
        address: z.string().optional().describe('Address to check queue position for. Defaults to PROPFUND_KEY signer.'),
    },
}, safe(async ({ address }) => {
    const { net, propfund, wallet } = buildContext();
    const addr = address ?? (wallet && wallet.address);
    const [length, escrow] = await Promise.all([
        propfund.queueLength(),
        propfund.queuedDeposits(),
    ]);
    // getFundingQueue() was dropped to fit EIP-170 — walk the public array indexer.
    const list = [];
    for (let i = 0n; i < length; i++) list.push(await propfund.fundingQueue(i));
    const myPos = addr ? await propfund.queuePosition(addr) : 0n;
    return jsonText({
        ok: true, network: net.key, address: addr,
        queueLength: length.toString(),
        myPosition: myPos.toString(),
        queuedDepositsRaw: escrow.toString(),
        queue: list,
    });
}));

server.registerTool('get_pool_risk', {
    description: 'Pool-wide risk view: total unrealized PnL across all open positions and active position count.',
    inputSchema: {},
}, safe(async () => {
    const { net, propfund } = buildContext();
    const r = await propfund.getPoolRisk();
    return jsonText({
        ok: true, network: net.key,
        totalUnrealizedPnlRaw: r.totalUnrealizedPnl.toString(),
        positionsAtRisk: r.positionsAtRisk.toString(),
    });
}));

server.registerTool('get_funded_traders', {
    description: 'List all currently-funded trader addresses. Useful for keeper sweeps.',
    inputSchema: {},
}, safe(async () => {
    const { net, propfund } = buildContext();
    // getFundedTraders() was dropped to fit EIP-170 — walk the public array indexer.
    const count = await propfund.fundedTraderCount();
    const traders = [];
    for (let i = 0n; i < count; i++) traders.push(await propfund.fundedTraders(i));
    return jsonText({ ok: true, network: net.key, traders });
}));

server.registerTool('is_liquidatable', {
    description: 'Check if a trader\'s position is currently liquidatable (loss has eaten the position margin).',
    inputSchema: {
        trader: z.string().describe('Trader address to check.'),
    },
}, safe(async ({ trader }) => {
    const { propfund } = buildContext();
    const t = getAddress(trader);
    const can = await propfund.isLiquidatable(t);
    return jsonText({ ok: true, trader: t, liquidatable: Boolean(can) });
}));

server.registerTool('get_position_age', {
    description: 'Position age in blocks + flag for whether it is past the 14-day max-duration (force-closeable).',
    inputSchema: {
        trader: z.string().describe('Trader address to check.'),
    },
}, safe(async ({ trader }) => {
    const { net, propfund } = buildContext();
    const t = getAddress(trader);
    const [age, expired] = await Promise.all([
        propfund.positionAge(t),
        propfund.positionExpired(t),
    ]);
    return jsonText({ ok: true, network: net.key, trader: t, ageBlocks: age.toString(), expired: Boolean(expired) });
}));

server.registerTool('get_effective_cap', {
    description: 'Max notional this trader can open right now — bounded by both their per-trader limit and their fair share of the pool.',
    inputSchema: {
        address: z.string().optional().describe('Trader address. Defaults to PROPFUND_KEY signer.'),
    },
}, safe(async ({ address }) => {
    const { net, propfund, wallet } = buildContext();
    const addr = address ?? (wallet && wallet.address);
    if (!addr) throw new Error('No address.');
    const cap = await propfund.effectiveCap(addr);
    return jsonText({ ok: true, network: net.key, address: addr, effectiveCapRaw: cap.toString() });
}));

server.registerTool('get_delegate_status', {
    description: 'Get the controller authorization for an address (the agent address authorized to act on its behalf, max notional, expiry).',
    inputSchema: {
        principal: z.string().optional().describe('Principal address. Defaults to PROPFUND_KEY signer.'),
    },
}, safe(async ({ principal }) => {
    const { net, propfund, wallet, usdc } = buildContext();
    const addr = principal ?? (wallet && wallet.address);
    if (!addr) throw new Error('No address.');
    const [auth, allowance] = await Promise.all([
        propfund.controllers(addr),
        usdc.allowance(addr, propfund.target),
    ]);
    return jsonText({
        ok: true, network: net.key, principal: addr,
        agent: auth.agent ?? auth[0],
        maxNotionalPerTradeRaw: (auth.maxNotionalPerTrade ?? auth[1]).toString(),
        expiry: (auth.expiry ?? auth[2]).toString(),
        usdcAllowanceRaw: allowance.toString(),
    });
}));

// =============================================================================
// WRITE TOOLS — require PROPFUND_KEY
// =============================================================================

server.registerTool('faucet', {
    description: 'Mint test USDC (testnet only). Defaults to 10,000 USDC.',
    inputSchema: {
        amountUsdc: z.string().optional().describe('USDC amount as decimal string (e.g. "10000"). Default 10000.'),
    },
}, safe(async ({ amountUsdc }) => {
    const { net, usdc, wallet } = buildContext({ requireSigner: true });
    if (!net.usdcMintable) throw new Error(`network "${net.key}" has no faucet`);
    const amt = parseUnits(amountUsdc ?? '10000', net.usdcDecimals);
    const tx = await usdc.mint(wallet.address, amt);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'faucet', amountRaw: amt.toString(), txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('eval_start', {
    description: 'Pay the eval fee and begin a new evaluation. Asset is picked per-trade via eval_trade_open, not at start.',
    inputSchema: {
        for_principal: z.string().optional().describe('Principal address — the agent acts on their behalf.'),
    },
}, safe(async ({ for_principal }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const principal = for_principal ? getAddress(for_principal) : null;
    const tx = principal ? await propfund.startEvalFor(principal) : await propfund.startEval();
    const r = await tx.wait();
    return jsonText({ ok: true, action: principal ? 'startEvalFor' : 'startEval', principal, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('eval_trade_open', {
    description: 'Open a virtual long on the chosen asset. Pick a different asset each trade if you want — agent rotates per-trade.',
    inputSchema: {
        asset_id: z.number().int().min(0).max(255).optional().describe('Asset index (0=ETH, 1=BTC, 2=SOL, …). Defaults to 0.'),
        for_principal: z.string().optional(),
    },
}, safe(async ({ asset_id, for_principal }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const principal = for_principal ? getAddress(for_principal) : null;
    const aid = asset_id ?? 0;
    const tx = principal ? await propfund.openEvalTradeFor(principal, aid) : await propfund.openEvalTrade(aid);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'openEvalTrade', principal, assetId: aid, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('eval_trade_close', {
    description: 'Close the open virtual eval trade and update pass/fail state.',
    inputSchema: {
        for_principal: z.string().optional(),
    },
}, safe(async ({ for_principal }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const principal = for_principal ? getAddress(for_principal) : null;
    const tx = principal ? await propfund.closeEvalTradeFor(principal) : await propfund.closeEvalTrade();
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'closeEvalTrade', principal, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('eval_claim', {
    description: 'Pay the trader deposit and become a funded trader. If pool capacity is full, auto-queues with deposit escrowed.',
    inputSchema: {
        for_principal: z.string().optional(),
    },
}, safe(async ({ for_principal }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const principal = for_principal ? getAddress(for_principal) : null;
    const tx = principal ? await propfund.claimFundingFor(principal) : await propfund.claimFunding();
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'claimFunding', principal, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('eval_cancel', {
    description: 'Abandon an active evaluation (eval fee is non-refundable).',
    inputSchema: {},
}, safe(async () => {
    const { propfund } = buildContext({ requireSigner: true });
    const tx = await propfund.cancelEval();
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'cancelEval', txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('trade_open', {
    description: 'Open a leveraged position on a Chainlink-feeded asset. `margin` is in USDC (≤ deposit/2). `leverage` 1..10. Optional TP/SL prices.',
    inputSchema: {
        asset: z.string().describe('Asset name (e.g. "ETH") or numeric id.'),
        side: z.enum(['long', 'short']),
        marginUsdc: z.string().describe('Margin in USDC as a decimal string (e.g. "250").'),
        leverage: z.number().int().min(1).max(10),
        tp: z.string().optional().describe('Take-profit price as decimal (e.g. "4500"). Optional.'),
        sl: z.string().optional().describe('Stop-loss price as decimal (e.g. "3500"). Optional.'),
        for_principal: z.string().optional(),
    },
}, safe(async ({ asset, side, marginUsdc, leverage, tp, sl, for_principal }) => {
    const { net, propfund, wallet } = buildContext({ requireSigner: true });
    const principal = for_principal ? getAddress(for_principal) : null;
    const subject = principal ?? wallet.address;

    const assetId = resolveAssetId(net, asset);
    const isShort = side === 'short';

    const stats = await propfund.getTraderStats(subject);
    if (!stats.active) throw new Error(`${principal ? 'principal' : 'caller'} is not a funded trader`);
    if (stats.inPosition) throw new Error('already in a position — close first');

    const maxMargin = stats.deposit / 2n;
    const marginRaw = parseUnits(marginUsdc, net.usdcDecimals);
    if (marginRaw > maxMargin) {
        throw new Error(`margin ${marginUsdc} exceeds max margin ${Number(maxMargin) / 1e6} (deposit/2)`);
    }
    const sizeBps = (marginRaw * 10_000n) / maxMargin;
    if (sizeBps === 0n) throw new Error('margin too small');

    const tpRaw = tp ? parseUnits(tp, net.priceDecimals) : 0n;
    const slRaw = sl ? parseUnits(sl, net.priceDecimals) : 0n;

    const tx = principal
        ? await propfund.openTradeFor(principal, assetId, sizeBps, isShort, tpRaw, slRaw, leverage)
        : await propfund.openTrade(assetId, sizeBps, isShort, tpRaw, slRaw, leverage);
    const r = await tx.wait();
    return jsonText({
        ok: true, action: 'openTrade', principal,
        assetId, asset: net.assetNames[assetId], side, leverage,
        sizeBps: sizeBps.toString(),
        marginRaw: ((maxMargin * sizeBps) / 10_000n).toString(),
        notionalRaw: (((maxMargin * sizeBps) / 10_000n) * BigInt(leverage)).toString(),
        txHash: tx.hash, blockNumber: r.blockNumber,
    });
}));

server.registerTool('trade_close', {
    description: 'Close (fully or partially) the caller\'s open position.',
    inputSchema: {
        bps: z.number().int().min(1).max(10_000).default(10_000).describe('Portion to close in basis points (10000 = full close).'),
        for_principal: z.string().optional(),
    },
}, safe(async ({ bps, for_principal }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const principal = for_principal ? getAddress(for_principal) : null;
    const closeBps = BigInt(bps ?? 10_000);
    const tx = principal
        ? await propfund.closeTradeFor(principal, closeBps)
        : await propfund.closeTrade(closeBps);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'closeTrade', principal, closeBps: closeBps.toString(), txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('trade_update', {
    description: 'Update the take-profit / stop-loss on the open position. Use 0 to clear an exit.',
    inputSchema: {
        tp: z.string().optional().describe('New TP as decimal price, or "0" to clear.'),
        sl: z.string().optional().describe('New SL as decimal price, or "0" to clear.'),
        for_principal: z.string().optional(),
    },
}, safe(async ({ tp, sl, for_principal }) => {
    const { net, propfund } = buildContext({ requireSigner: true });
    const principal = for_principal ? getAddress(for_principal) : null;
    const tpRaw = tp ? parseUnits(tp, net.priceDecimals) : 0n;
    const slRaw = sl ? parseUnits(sl, net.priceDecimals) : 0n;
    if (tpRaw === 0n && slRaw === 0n) throw new Error('pass at least one of tp / sl (use "0" to clear)');
    const tx = principal
        ? await propfund.updateExitFor(principal, tpRaw, slRaw)
        : await propfund.updateExit(tpRaw, slRaw);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'updateExit', principal, tpRaw: tpRaw.toString(), slRaw: slRaw.toString(), txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('withdraw_profit', {
    description: 'Withdraw realized profit from a funded account. Principal-only — agents cannot do this on someone else\'s behalf.',
    inputSchema: {
        amountUsdc: z.string().describe('USDC amount as decimal string.'),
    },
}, safe(async ({ amountUsdc }) => {
    const { net, propfund } = buildContext({ requireSigner: true });
    const amt = parseUnits(amountUsdc, net.usdcDecimals);
    const tx = await propfund.withdrawProfit(amt);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'withdrawProfit', amountRaw: amt.toString(), txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('resign', {
    description: 'Voluntarily exit funded status. Returns whatever is left of the deposit. Principal-only.',
    inputSchema: {},
}, safe(async () => {
    const { propfund } = buildContext({ requireSigner: true });
    const tx = await propfund.resignFunding();
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'resignFunding', txHash: tx.hash, blockNumber: r.blockNumber });
}));

// =============================================================================
// DELEGATION TOOLS
// =============================================================================

server.registerTool('delegate_set', {
    description: 'Authorize an agent to drive your full trader lifecycle (eval, funding, trades). Bounded by per-trade notional cap and expiry.',
    inputSchema: {
        agent: z.string().describe('Agent EOA to authorize.'),
        maxNotionalUsdc: z.string().describe('Per-trade notional cap in USDC.'),
        expiry: z.number().int().describe('Unix timestamp after which authorization is dead.'),
    },
}, safe(async ({ agent, maxNotionalUsdc, expiry }) => {
    const { net, propfund } = buildContext({ requireSigner: true });
    const agentAddr = getAddress(agent);
    const cap = parseUnits(maxNotionalUsdc, net.usdcDecimals);
    const tx = await propfund.setController(agentAddr, cap, expiry);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'setController', agent: agentAddr, maxNotionalRaw: cap.toString(), expiry, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('delegate_revoke', {
    description: 'Revoke any current controller authorization. Open positions are unaffected; only the agent\'s authority is killed.',
    inputSchema: {},
}, safe(async () => {
    const { propfund } = buildContext({ requireSigner: true });
    const tx = await propfund.revokeController();
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'revokeController', txHash: tx.hash, blockNumber: r.blockNumber });
}));

// =============================================================================
// KEEPER TOOLS — public, anyone can call
// =============================================================================

server.registerTool('liquidate', {
    description: 'Liquidate a funded trader\'s position when their unrealized loss has consumed their position margin.',
    inputSchema: { trader: z.string() },
}, safe(async ({ trader }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const t = getAddress(trader);
    const tx = await propfund.liquidate(t);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'liquidate', trader: t, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('exec_exit', {
    description: 'Settle a position when its TP or SL has been hit at the current oracle price.',
    inputSchema: { trader: z.string() },
}, safe(async ({ trader }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const t = getAddress(trader);
    const tx = await propfund.executeExit(t);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'executeExit', trader: t, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('force_close', {
    description: 'Settle a position older than the 14-day max-duration. Public — any keeper can call.',
    inputSchema: { trader: z.string() },
}, safe(async ({ trader }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const t = getAddress(trader);
    const tx = await propfund.forceClose(t);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'forceClose', trader: t, txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('process_funding_queue', {
    description: 'Advance the FIFO funding queue while pool capacity exists. Bounded per-call by `max`.',
    inputSchema: {
        max: z.number().int().min(1).max(50).default(10),
    },
}, safe(async ({ max }) => {
    const { propfund } = buildContext({ requireSigner: true });
    const tx = await propfund.processFundingQueue(BigInt(max ?? 10));
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'processFundingQueue', max, txHash: tx.hash, blockNumber: r.blockNumber });
}));

// =============================================================================
// LP TOOLS
// =============================================================================

server.registerTool('lp_status', {
    description: 'LP share balance, share fraction of pool, USDC value, and pool NAV.',
    inputSchema: {
        address: z.string().optional(),
    },
}, safe(async ({ address }) => {
    const { net, propfund, wallet } = buildContext();
    const addr = address ?? (wallet && wallet.address);
    if (!addr) throw new Error('No address.');
    const [shares, totalShares, poolBalance, poolValue] = await Promise.all([
        propfund.shares(addr),
        propfund.totalShares(),
        propfund.poolBalance(),
        propfund.poolValue(),
    ]);
    const myValue = totalShares > 0n ? (shares * poolValue) / totalShares : 0n;
    return jsonText({
        ok: true, network: net.key, address: addr,
        shares: shares.toString(),
        totalShares: totalShares.toString(),
        poolBalanceRaw: poolBalance.toString(),
        poolValueRaw: poolValue.toString(),
        myValueRaw: myValue.toString(),
    });
}));

server.registerTool('lp_deposit', {
    description: 'Deposit USDC into the LP pool, mint shares.',
    inputSchema: { amountUsdc: z.string() },
}, safe(async ({ amountUsdc }) => {
    const { net, propfund, usdc, wallet } = buildContext({ requireSigner: true });
    const amt = parseUnits(amountUsdc, net.usdcDecimals);
    // Approve if needed
    const allowance = await usdc.allowance(wallet.address, propfund.target);
    if (allowance < amt) {
        const a = await usdc.approve(propfund.target, (1n << 256n) - 1n);
        await a.wait();
    }
    const tx = await propfund.deposit(amt);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'lpDeposit', amountRaw: amt.toString(), txHash: tx.hash, blockNumber: r.blockNumber });
}));

server.registerTool('lp_withdraw', {
    description: 'Burn LP shares to withdraw USDC. Pass either `shares` (raw count) or `amountUsdc` (USDC equivalent, rounded up) or `all` to drain.',
    inputSchema: {
        shares: z.string().optional(),
        amountUsdc: z.string().optional(),
        all: z.boolean().optional(),
    },
}, safe(async ({ shares, amountUsdc, all }) => {
    const { net, propfund, wallet } = buildContext({ requireSigner: true });
    let shareAmount;
    if (all) {
        shareAmount = await propfund.shares(wallet.address);
        if (shareAmount === 0n) throw new Error('no shares');
    } else if (shares) {
        shareAmount = BigInt(shares);
    } else if (amountUsdc) {
        const amt = parseUnits(amountUsdc, net.usdcDecimals);
        const [totalShares, poolValue] = await Promise.all([propfund.totalShares(), propfund.poolValue()]);
        shareAmount = (amt * totalShares + poolValue - 1n) / poolValue;
        const owned = await propfund.shares(wallet.address);
        if (shareAmount > owned) shareAmount = owned;
    } else {
        throw new Error('pass `shares`, `amountUsdc`, or `all`');
    }
    const tx = await propfund.withdraw(shareAmount);
    const r = await tx.wait();
    return jsonText({ ok: true, action: 'lpWithdraw', sharesBurned: shareAmount.toString(), txHash: tx.hash, blockNumber: r.blockNumber });
}));

// =============================================================================
// PRICE DATA
// =============================================================================

const FEED_ABI = [
    'function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)',
    'function getRoundData(uint80) view returns (uint80, int256, uint256, uint256, uint80)',
];

server.registerTool('price_history', {
    description: 'Walk back N rounds on the asset\'s Chainlink feed. Returns the actual settlement-source data the contract uses.',
    inputSchema: {
        asset: z.string().describe('Asset name (e.g. "ETH") or numeric id.'),
        rounds: z.number().int().min(1).max(500).default(50),
    },
}, safe(async ({ asset, rounds }) => {
    const { net, propfund, provider } = buildContext();
    const assetId = resolveAssetId(net, asset);
    const feedAddr = await propfund.oracles(assetId);
    if (feedAddr === '0x0000000000000000000000000000000000000000') {
        throw new Error(`no feed wired for asset ${assetId}`);
    }
    const feed = new Contract(feedAddr, FEED_ABI, provider);
    const latest = await feed.latestRoundData();
    const latestId = latest[0];
    const reads = [];
    for (let i = 0; i < (rounds ?? 50); i++) {
        const rid = latestId - BigInt(i);
        if (rid === 0n) break;
        reads.push(feed.getRoundData(rid).then(r => ({
            roundId: r[0].toString(),
            timestamp: Number(r[3]),
            priceRaw: r[1].toString(),
        })).catch(() => null));
    }
    const results = (await Promise.all(reads)).filter(r => r != null);
    return jsonText({ ok: true, network: net.key, assetId, asset: net.assetNames[assetId], feed: feedAddr, rounds: results });
}));

const COINBASE_TF = { '1m': 60, '5m': 300, '15m': 900, '1h': 3600, '6h': 21600, '1d': 86400 };
const COINBASE_NO_MARKET = new Set(['XAU','XAG','EUR','GBP','JPY','AUD','CAD','CHF','GOLD','CRUDE']);

server.registerTool('candles', {
    description: 'Pull OHLCV from Coinbase REST. Useful for technical analysis. Some assets (XAU/EUR/etc.) have no Coinbase market — use price_history for those.',
    inputSchema: {
        asset: z.string().describe('Asset name (e.g. "ETH"). Maps to {ASSET}-USD on Coinbase.'),
        tf: z.enum(['1m','5m','15m','1h','6h','1d']).default('1h'),
        limit: z.number().int().min(1).max(300).default(100),
    },
}, safe(async ({ asset, tf, limit }) => {
    const upper = asset.toUpperCase();
    if (COINBASE_NO_MARKET.has(upper)) {
        throw new Error(`asset "${asset}" has no Coinbase market — use price_history for the on-chain Chainlink data instead`);
    }
    const product = `${upper}-USD`;
    const granularity = COINBASE_TF[tf ?? '1h'];
    const url = `https://api.exchange.coinbase.com/products/${product}/candles?granularity=${granularity}`;
    const res = await fetch(url, { headers: { 'User-Agent': 'propfund-mcp/0.1' } });
    if (!res.ok) throw new Error(`Coinbase request failed: ${res.status} ${res.statusText}`);
    const raw = await res.json();
    const trimmed = raw.slice(0, limit ?? 100).map(([t, low, high, open, close, volume]) => ({
        timestamp: t, open, high, low, close, volume,
    }));
    return jsonText({ ok: true, asset: upper, product, timeframe: tf ?? '1h', granularitySeconds: granularity, count: trimmed.length, candles: trimmed });
}));

// =============================================================================
// CONNECT
// =============================================================================

const transport = new StdioServerTransport();
await server.connect(transport);
process.stderr.write('[propfund-mcp] connected via stdio\n');

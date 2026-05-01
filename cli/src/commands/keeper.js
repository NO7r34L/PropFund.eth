import { getAddress } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtPrice, fmtUsdc, printRows, printTable } from '../format.js';
import { isJson } from '../args.js';
import { waitTx } from '../tx.js';

// Public liquidation: any address can call liquidate(target) when the position is underwater
// past the liquidation threshold. Useful for keeper bots and agents.
export async function liquidate(args) {
    const target = args._[0];
    if (!target) throw new Error('usage: propfund liquidate <traderAddress>');
    const trader = getAddress(target);

    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const tx = await propfund.liquidate(trader);
    const receipt = await waitTx(tx, 'liquidate', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: 'liquidate', trader, txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`liquidated ${trader}\n`);
}

// Settle a position when its TP or SL has been hit. Public — anyone can call.
export async function execExit(args) {
    const target = args._[0];
    if (!target) throw new Error('usage: propfund exec-exit <traderAddress>');
    const trader = getAddress(target);

    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const tx = await propfund.executeExit(trader);
    const receipt = await waitTx(tx, 'executeExit', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: 'executeExit', trader, txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`settled exit for ${trader}\n`);
}

// Pre-check whether a trader is currently liquidatable.
export async function liquidatable(args) {
    const target = args._[0];
    if (!target) throw new Error('usage: propfund liquidatable <traderAddress>');
    const trader = getAddress(target);
    const { propfund } = buildContext({ network: args.flags.network });
    const can = await propfund.isLiquidatable(trader);
    if (isJson(args)) return emitJson({ trader, liquidatable: Boolean(can) });
    process.stdout.write(`${trader} liquidatable: ${can ? 'yes' : 'no'}\n`);
}

// Pool-wide risk view: cumulative unrealized PnL, count of active positions.
export async function risk(args) {
    const { net, propfund } = buildContext({ network: args.flags.network });
    const r = await propfund.getPoolRisk();
    const obj = {
        network: net.key,
        totalUnrealizedPnl: r.totalUnrealizedPnl.toString(),
        positionsAtRisk: r.positionsAtRisk.toString(),
    };
    if (isJson(args)) return emitJson(obj);
    printRows([
        ['network', net.key],
        ['unrealized PnL', fmtUsdc(r.totalUnrealizedPnl, net.usdcDecimals) + ' USDC'],
        ['positions', r.positionsAtRisk.toString()],
    ]);
}

// Top traders by cumulative profit.
export async function leaderboard(args) {
    const { net, propfund } = buildContext({ network: args.flags.network });
    const board = await propfund.getLeaderboard();
    const rows = board.map(e => ({
        trader: e.trader ?? e[0],
        cumulativePnl: (e.cumulativePnl ?? e[1]).toString(),
        wins: Number(e.wins ?? e[2]),
        losses: Number(e.losses ?? e[3]),
        level: Number(e.level ?? e[4]),
    }));
    if (isJson(args)) return emitJson({ network: net.key, leaderboard: rows });

    printTable(
        ['TRADER', 'CUM PNL (USDC)', 'W', 'L', 'LVL'],
        rows.map(r => [r.trader, fmtUsdc(r.cumulativePnl, net.usdcDecimals), r.wins, r.losses, r.level]),
    );
}

// Enumerate all currently-funded trader addresses — useful for keeper sweeps.
export async function fundedList(args) {
    const { net, propfund } = buildContext({ network: args.flags.network });
    // getFundedTraders() was dropped to fit EIP-170 — walk the public array indexer instead.
    const count = await propfund.fundedTraderCount();
    const list = [];
    for (let i = 0n; i < count; i++) list.push(await propfund.fundedTraders(i));
    if (isJson(args)) return emitJson({ network: net.key, traders: list });
    if (list.length === 0) {
        process.stdout.write('(no funded traders)\n');
        return;
    }
    for (const a of list) process.stdout.write(`${a}\n`);
}

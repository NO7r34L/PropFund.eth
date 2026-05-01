import { buildContext } from '../context.js';
import { emitJson, fmtPrice, fmtUsdc, printRows } from '../format.js';
import { isJson } from '../args.js';

export async function stats(args) {
    const { net, propfund, wallet } = buildContext({ network: args.flags.network });
    const addr = args.flags.address || (wallet && wallet.address);
    if (!addr) throw new Error('pass --address or set PROPFUND_KEY');

    const s = await propfund.getTraderStats(addr);

    const obj = {
        network: net.key,
        address: addr,
        active: Boolean(s.active),
        level: Number(s.level),
        deposit: s.deposit.toString(),
        cumulativePnl: s.cumulativePnl.toString(),
        maxDeploy: s.maxDeploy.toString(),
        position: s.inPosition ? {
            assetId: Number(s.assetId),
            assetName: net.assetNames[Number(s.assetId)] ?? null,
            isShort: Boolean(s.isShort),
            deployedAmount: s.deployedAmount.toString(),
            entryPrice: s.entryPrice.toString(),
            tpPrice: s.tpPrice.toString(),
            slPrice: s.slPrice.toString(),
        } : null,
    };

    if (isJson(args)) return emitJson(obj);

    printRows([
        ['network', net.key],
        ['address', addr],
        ['funded', obj.active ? 'yes' : 'no'],
        ['level', String(obj.level)],
        ['deposit', fmtUsdc(s.deposit, net.usdcDecimals) + ' USDC'],
        ['cum PnL', fmtUsdc(s.cumulativePnl, net.usdcDecimals) + ' USDC'],
        ['max deploy', fmtUsdc(s.maxDeploy, net.usdcDecimals) + ' USDC'],
    ]);
    if (obj.position) {
        process.stdout.write('\nopen position:\n');
        printRows([
            ['  asset', `${obj.position.assetName ?? ''} (id ${obj.position.assetId})`],
            ['  side', obj.position.isShort ? 'short' : 'long'],
            ['  notional', fmtUsdc(s.deployedAmount, net.usdcDecimals) + ' USDC'],
            ['  entry', fmtPrice(s.entryPrice, net.priceDecimals)],
            ['  TP', s.tpPrice > 0n ? fmtPrice(s.tpPrice, net.priceDecimals) : '—'],
            ['  SL', s.slPrice > 0n ? fmtPrice(s.slPrice, net.priceDecimals) : '—'],
        ]);
    }
}

import { parseUnits, getAddress } from 'ethers';
import { buildContext, resolveAssetId } from '../context.js';
import { emitJson, fmtPrice, fmtUsdc, printRows } from '../format.js';
import { isJson, flag, requireFlag } from '../args.js';
import { waitTx } from './../tx.js';

// `propfund trade open --asset ETH --side long --margin 250 --leverage 5 [--tp 4500] [--sl 3500] [--for 0xPRINCIPAL]`
//
// The contract's openTrade takes sizeBps (fraction of *max margin*, where max margin = deposit / 2)
// rather than a raw USDC amount. We accept a USDC-denominated --margin and convert it.
export async function tradeOpen(args) {
    const { net, propfund, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = args.flags.for ? getAddress(args.flags.for) : null;
    const subject = principal ?? wallet.address;

    const assetId = resolveAssetId(net, requireFlag(args, 'asset'));
    const sideRaw = String(requireFlag(args, 'side')).toLowerCase();
    if (sideRaw !== 'long' && sideRaw !== 'short') throw new Error('--side must be long or short');
    const isShort = sideRaw === 'short';

    const leverage = Number(flag(args, 'leverage', 1));
    if (!Number.isInteger(leverage) || leverage < 1 || leverage > 10) {
        throw new Error('--leverage must be an integer 1..10');
    }

    const stats = await propfund.getTraderStats(subject);
    if (!stats.active) throw new Error(`${principal ? 'principal' : 'caller'} is not a funded trader`);
    if (stats.inPosition) throw new Error('already in a position — close it first');

    const maxMargin = stats.deposit / 2n;

    let sizeBps;
    if (args.flags.sizeBps != null) {
        sizeBps = BigInt(args.flags.sizeBps);
    } else {
        const marginUsdc = parseUnits(String(requireFlag(args, 'margin')), net.usdcDecimals);
        if (marginUsdc <= 0n) throw new Error('--margin must be positive');
        if (marginUsdc > maxMargin) {
            throw new Error(`--margin ${fmtUsdc(marginUsdc, net.usdcDecimals)} exceeds max margin ${fmtUsdc(maxMargin, net.usdcDecimals)} (deposit/2)`);
        }
        sizeBps = (marginUsdc * 10_000n) / maxMargin;
        if (sizeBps === 0n) throw new Error('--margin too small (rounds to 0 bps)');
    }
    if (sizeBps < 1n || sizeBps > 10_000n) throw new Error('size must be 1..10000 bps');

    const tp = parseOptionalPrice(flag(args, 'tp'), net.priceDecimals);
    const sl = parseOptionalPrice(flag(args, 'sl'), net.priceDecimals);

    const tx = principal
        ? await propfund.openTradeFor(principal, assetId, sizeBps, isShort, tp, sl, leverage)
        : await propfund.openTrade(assetId, sizeBps, isShort, tp, sl, leverage);
    const receipt = await waitTx(tx, 'openTrade', isJson(args));

    const expectedMargin = (maxMargin * sizeBps) / 10_000n;
    const expectedNotional = expectedMargin * BigInt(leverage);

    if (isJson(args)) {
        return emitJson({
            ok: true,
            action: principal ? 'openTradeFor' : 'openTrade',
            principal,
            assetId, asset: net.assetNames[assetId],
            side: isShort ? 'short' : 'long',
            leverage,
            sizeBps: sizeBps.toString(),
            margin: expectedMargin.toString(),
            notional: expectedNotional.toString(),
            tp: tp.toString(),
            sl: sl.toString(),
            txHash: tx.hash,
            blockNumber: receipt.blockNumber,
        });
    }

    const who = principal ? `for ${principal}` : '';
    process.stdout.write(`opened ${sideRaw} ${net.assetNames[assetId]} @ ${leverage}x  `);
    process.stdout.write(`margin ${fmtUsdc(expectedMargin, net.usdcDecimals)}  notional ${fmtUsdc(expectedNotional, net.usdcDecimals)} ${who}\n`);
}

// `propfund trade close [--bps 10000] [--for 0xPRINCIPAL]` — defaults to a full close.
export async function tradeClose(args) {
    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = args.flags.for ? getAddress(args.flags.for) : null;
    const closeBps = BigInt(flag(args, 'bps', 10_000));
    if (closeBps < 1n || closeBps > 10_000n) throw new Error('--bps must be 1..10000');

    const tx = principal
        ? await propfund.closeTradeFor(principal, closeBps)
        : await propfund.closeTrade(closeBps);
    const receipt = await waitTx(tx, 'closeTrade', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'closeTradeFor' : 'closeTrade', principal, closeBps: closeBps.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`closed ${closeBps === 10_000n ? 'full' : `${Number(closeBps) / 100}%`} of position\n`);
}

// `propfund trade update --tp 4500 --sl 3500 [--for 0xPRINCIPAL]`
export async function tradeUpdate(args) {
    const { net, propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = args.flags.for ? getAddress(args.flags.for) : null;
    const tp = parseOptionalPrice(flag(args, 'tp'), net.priceDecimals);
    const sl = parseOptionalPrice(flag(args, 'sl'), net.priceDecimals);
    if (tp === 0n && sl === 0n) {
        throw new Error('pass at least one of --tp or --sl (use 0 to clear)');
    }
    const tx = principal
        ? await propfund.updateExitFor(principal, tp, sl)
        : await propfund.updateExit(tp, sl);
    const receipt = await waitTx(tx, 'updateExit', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'updateExitFor' : 'updateExit', principal, tp: tp.toString(), sl: sl.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    printRows([
        ['TP', tp > 0n ? fmtPrice(tp, net.priceDecimals) : 'cleared'],
        ['SL', sl > 0n ? fmtPrice(sl, net.priceDecimals) : 'cleared'],
    ]);
}

function parseOptionalPrice(raw, decimals) {
    if (raw == null || raw === false || raw === '' || raw === '0') return 0n;
    return parseUnits(String(raw), decimals);
}

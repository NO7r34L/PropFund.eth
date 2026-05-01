import { getAddress } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc, printRows } from '../format.js';
import { isJson } from '../args.js';
import { waitTx } from '../tx.js';

// Force-close a position older than MAX_POSITION_BLOCKS. Anyone can call.
export async function forceClose(args) {
    const target = args._[0];
    if (!target) throw new Error('usage: propfund force-close <traderAddress>');
    const trader = getAddress(target);

    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const tx = await propfund.forceClose(trader);
    const receipt = await waitTx(tx, 'forceClose', isJson(args));
    if (isJson(args)) {
        return emitJson({ ok: true, action: 'forceClose', trader, txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`force-closed expired position for ${trader}\n`);
}

// Read: is this position past expiry, and how old is it (in blocks)?
export async function positionAge(args) {
    const target = args._[0];
    if (!target) throw new Error('usage: propfund position-age <traderAddress>');
    const trader = getAddress(target);
    const { net, propfund } = buildContext({ network: args.flags.network });
    const [age, expired] = await Promise.all([
        propfund.positionAge(trader),
        propfund.positionExpired(trader),
    ]);
    if (isJson(args)) return emitJson({ network: net.key, trader, ageBlocks: age.toString(), expired: Boolean(expired) });
    printRows([
        ['network', net.key],
        ['trader', trader],
        ['age (blocks)', age.toString()],
        ['expired', expired ? 'yes (force-closeable)' : 'no'],
    ]);
}

// What's this trader's current effective trade-open cap?
export async function cap(args) {
    const { net, propfund, wallet } = buildContext({ network: args.flags.network });
    const addr = args.flags.address || (wallet && wallet.address);
    if (!addr) throw new Error('pass --address or set PROPFUND_KEY');
    const c = await propfund.effectiveCap(addr);
    if (isJson(args)) return emitJson({ network: net.key, address: addr, effectiveCap: c.toString() });
    printRows([
        ['network', net.key],
        ['address', addr],
        ['effective cap', fmtUsdc(c, net.usdcDecimals) + ' USDC notional'],
    ]);
}

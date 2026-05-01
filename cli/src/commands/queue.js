import { getAddress } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc, printRows, printTable } from '../format.js';
import { isJson, flag } from '../args.js';
import { waitTx } from '../tx.js';

// View: queue length, your position (if any), total escrowed deposits.
export async function queueStatus(args) {
    const { net, propfund, wallet } = buildContext({ network: args.flags.network });
    const addr = args.flags.address || (wallet && wallet.address);

    const [length, escrow] = await Promise.all([
        propfund.queueLength(),
        propfund.queuedDeposits(),
    ]);
    // getFundingQueue() was dropped to fit EIP-170 — walk the public array indexer instead.
    const list = [];
    for (let i = 0n; i < length; i++) list.push(await propfund.fundingQueue(i));
    const myPos = addr ? await propfund.queuePosition(addr) : 0n;

    const obj = {
        network: net.key,
        address: addr,
        queueLength: length.toString(),
        myPosition: myPos.toString(),
        queuedDeposits: escrow.toString(),
        queue: [...list],
    };
    if (isJson(args)) return emitJson(obj);

    printRows([
        ['network', net.key],
        ['address', addr || '(none)'],
        ['queue length', length.toString()],
        ['your position', myPos === 0n ? 'not queued' : myPos.toString()],
        ['total escrow', fmtUsdc(escrow, net.usdcDecimals) + ' USDC'],
    ]);
    if (list.length > 0) {
        process.stdout.write('\nqueue (FIFO):\n');
        printTable(['POS', 'ADDRESS'], list.map((a, i) => [i + 1, a]));
    }
}

// Refund deposit and remove yourself from the queue.
export async function queueLeave(args) {
    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const tx = await propfund.leaveFundingQueue();
    const receipt = await waitTx(tx, 'leaveFundingQueue', isJson(args));
    if (isJson(args)) {
        return emitJson({ ok: true, action: 'leaveFundingQueue', txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write('left funding queue — deposit refunded\n');
}

// Anyone can call: drain the queue while capacity exists. --max bounds gas.
export async function queueProcess(args) {
    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const max = BigInt(flag(args, 'max', 10));
    const tx = await propfund.processFundingQueue(max);
    const receipt = await waitTx(tx, 'processFundingQueue', isJson(args));
    if (isJson(args)) {
        return emitJson({ ok: true, action: 'processFundingQueue', max: max.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`processed funding queue (max ${max})\n`);
}

import { parseUnits, getAddress } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc } from '../format.js';
import { isJson, requireFlag } from '../args.js';
import { waitTx } from '../tx.js';

// Withdraw realized profit from a funded account. With --for, agent withdraws to principal.
export async function withdraw(args) {
    const { net, propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = args.flags.for ? getAddress(args.flags.for) : null;
    const amountUsdc = String(requireFlag(args, 'amount'));
    const amount = parseUnits(amountUsdc, net.usdcDecimals);
    if (amount <= 0n) throw new Error('--amount must be positive');

    if (principal) {
        throw new Error('withdraw is principal-only — agent cannot pull profit on someone else\'s behalf. Have the principal run `propfund withdraw` themselves.');
    }
    const tx = await propfund.withdrawProfit(amount);
    const receipt = await waitTx(tx, 'withdrawProfit', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'withdrawProfitFor' : 'withdrawProfit', principal, amount: amount.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    const who = principal ? `to ${principal}` : '';
    process.stdout.write(`withdrew up to ${fmtUsdc(amount, net.usdcDecimals)} USDC of profit ${who}\n`);
}

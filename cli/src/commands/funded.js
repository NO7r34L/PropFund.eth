import { getAddress } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc } from '../format.js';
import { isJson } from '../args.js';
import { waitTx } from '../tx.js';

// Voluntary exit from funded status. Returns whatever is left of the deposit
// (could be more than the original if profits compounded, less if losses absorbed).
// With --for, agent resigns the principal's funded account; deposit returns to principal.
export async function fundedResign(args) {
    const { net, propfund, wallet, lens } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = args.flags.for ? getAddress(args.flags.for) : null;
    const subject = principal ?? wallet.address;
    const before = await lens.getTraderStats(subject);
    if (!before.active) throw new Error(`${principal ? 'principal' : 'caller'} is not a funded trader`);

    if (principal) {
        throw new Error('resign is principal-only — agent cannot end funding on someone else\'s behalf. Have the principal run `propfund resign` themselves.');
    }
    const tx = await propfund.resignFunding();
    const receipt = await waitTx(tx, 'resignFunding', isJson(args));
    if (isJson(args)) {
        return emitJson({
            ok: true,
            action: principal ? 'resignFundingFor' : 'resignFunding',
            principal,
            depositReturned: before.deposit.toString(),
            txHash: tx.hash,
            blockNumber: receipt.blockNumber,
        });
    }
    const who = principal ? `to ${principal}` : '';
    process.stdout.write(`resigned funding — ${fmtUsdc(before.deposit, net.usdcDecimals)} USDC returned ${who}\n`);
}

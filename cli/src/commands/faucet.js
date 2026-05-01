import { parseUnits } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc } from '../format.js';
import { isJson, flag } from '../args.js';
import { waitTx } from '../tx.js';

// Sepolia MockUSDC has a public mint(). Defaults to 10,000 USDC.
export async function faucet(args) {
    const { net, usdc, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    if (!net.usdcMintable) throw new Error(`network "${net.key}" has no faucet`);

    const amountUsdc = String(flag(args, 'amount', '10000'));
    const amount = parseUnits(amountUsdc, net.usdcDecimals);

    const tx = await usdc.mint(wallet.address, amount);
    const receipt = await waitTx(tx, 'mint', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: 'mint', amount: amount.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`minted ${fmtUsdc(amount, net.usdcDecimals)} test USDC to ${wallet.address}\n`);
}

import { buildContext } from '../context.js';
import { emitJson, fmtEth, fmtUsdc, printRows } from '../format.js';
import { isJson } from '../args.js';

export async function balance(args) {
    const { net, provider, propfund, usdc, wallet } = buildContext({ network: args.flags.network });
    const addr = args.flags.address || (wallet && wallet.address);
    if (!addr) throw new Error('pass --address or set PROPFUND_KEY');

    const [eth, usdcBal, contractUsdc] = await Promise.all([
        provider.getBalance(addr),
        usdc.balanceOf(addr),
        usdc.balanceOf(propfund.target),
    ]);

    const out = {
        network: net.key,
        address: addr,
        ethBalance: eth.toString(),
        usdcBalance: usdcBal.toString(),
        contractUsdcBalance: contractUsdc.toString(),
        usdcMintable: net.usdcMintable,
    };

    if (isJson(args)) return emitJson(out);

    printRows([
        ['network', net.key],
        ['address', addr],
        ['ETH', fmtEth(eth)],
        ['USDC', fmtUsdc(usdcBal, net.usdcDecimals)],
        ['pool USDC', fmtUsdc(contractUsdc, net.usdcDecimals)],
        ['faucet', net.usdcMintable ? 'available (`propfund faucet`)' : 'mainnet (no faucet)'],
    ]);
}

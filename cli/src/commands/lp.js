import { parseUnits } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc, printRows } from '../format.js';
import { isJson, flag, requireFlag } from '../args.js';
import { ensureAllowance, waitTx } from '../tx.js';

// Show LP position: share balance, share fraction of pool, USDC value, raw pool numbers.
export async function lpStatus(args) {
    const { net, propfund, wallet } = buildContext({ network: args.flags.network });
    const addr = args.flags.address || (wallet && wallet.address);
    if (!addr) throw new Error('pass --address or set PROPFUND_KEY');

    const [myShares, totalShares, poolBalance, poolValue] = await Promise.all([
        propfund.shares(addr),
        propfund.totalShares(),
        propfund.poolBalance(),
        propfund.poolValue(),
    ]);

    const myValueUsdc = totalShares > 0n ? (myShares * poolValue) / totalShares : 0n;
    const sharePctBps = totalShares > 0n ? (myShares * 10_000n) / totalShares : 0n;

    const obj = {
        network: net.key,
        address: addr,
        shares: myShares.toString(),
        totalShares: totalShares.toString(),
        poolBalance: poolBalance.toString(),
        poolValue: poolValue.toString(),
        myValueUsdc: myValueUsdc.toString(),
        sharePctBps: sharePctBps.toString(),
    };

    if (isJson(args)) return emitJson(obj);

    printRows([
        ['network', net.key],
        ['address', addr],
        ['shares', myShares.toString()],
        ['share %', `${(Number(sharePctBps) / 100).toFixed(4)}%`],
        ['my value', fmtUsdc(myValueUsdc, net.usdcDecimals) + ' USDC'],
        ['pool balance', fmtUsdc(poolBalance, net.usdcDecimals) + ' USDC'],
        ['pool value', fmtUsdc(poolValue, net.usdcDecimals) + ' USDC (NAV)'],
        ['total shares', totalShares.toString()],
    ]);
}

// `propfund lp deposit --amount 1000` — adds USDC to the pool, mints shares.
export async function lpDeposit(args) {
    const { net, propfund, usdc, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const amountUsdc = String(requireFlag(args, 'amount'));
    const amount = parseUnits(amountUsdc, net.usdcDecimals);
    if (amount < 1_000_000n) throw new Error('--amount must be >= 1 USDC (MIN_DEPOSIT)');

    await ensureAllowance({
        usdc, owner: wallet.address, spender: propfund.target, needed: amount, json: isJson(args),
    });

    const tx = await propfund.deposit(amount);
    const receipt = await waitTx(tx, 'deposit', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: 'deposit', amount: amount.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`deposited ${fmtUsdc(amount, net.usdcDecimals)} USDC into the LP pool\n`);
}

// `propfund lp withdraw --shares N` — exact share count
// `propfund lp withdraw --amount X` — USDC-denominated, converted to shares via pool ratio
// `propfund lp withdraw --all` — burn entire share balance
export async function lpWithdraw(args) {
    const { net, propfund, wallet } = buildContext({ requireSigner: true, network: args.flags.network });

    let shareAmount;
    if (flag(args, 'all')) {
        shareAmount = await propfund.shares(wallet.address);
        if (shareAmount === 0n) throw new Error('no shares to withdraw');
    } else if (args.flags.shares != null) {
        shareAmount = BigInt(args.flags.shares);
    } else if (args.flags.amount != null) {
        const usdcAmount = parseUnits(String(args.flags.amount), net.usdcDecimals);
        const [totalShares, poolValue] = await Promise.all([
            propfund.totalShares(), propfund.poolValue(),
        ]);
        if (totalShares === 0n) throw new Error('pool has no shares');
        // Round up so the trader gets at least the USDC amount they asked for, capped at their balance.
        shareAmount = (usdcAmount * totalShares + poolValue - 1n) / poolValue;
        const owned = await propfund.shares(wallet.address);
        if (shareAmount > owned) shareAmount = owned;
    } else {
        throw new Error('pass --shares N, --amount USDC, or --all');
    }

    if (shareAmount === 0n) throw new Error('shareAmount resolved to 0');

    const tx = await propfund.withdraw(shareAmount);
    const receipt = await waitTx(tx, 'withdraw', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: 'withdraw', shares: shareAmount.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write(`burned ${shareAmount} shares — USDC paid out from pool NAV\n`);
}

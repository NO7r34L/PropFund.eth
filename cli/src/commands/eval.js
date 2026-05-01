import { getAddress } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc, printRows } from '../format.js';
import { isJson, flag } from '../args.js';
import { ensureAllowance, waitTx } from '../tx.js';

// When --for <principal> is set, the agent is acting on the principal's behalf.
// USDC pulls/sends are sourced/sent to/from the principal, NOT the agent.
function resolvePrincipal(args) {
    const f = args.flags.for;
    if (!f) return null;
    return getAddress(f);
}

export async function evalStatus(args) {
    const { net, propfund, wallet } = buildContext({ network: args.flags.network });
    const addr = args.flags.address || (wallet && wallet.address);
    if (!addr) throw new Error('pass --address or set PROPFUND_KEY');

    const s = await propfund.getEvalStatus(addr);
    const obj = {
        network: net.key,
        address: addr,
        active: Boolean(s.active),
        passed: Boolean(s.passed),
        returnBps: Number(s.returnBps),
        targetBps: Number(s.targetBps),
        drawdownBps: Number(s.drawdownBps),
        maxDrawdownBps: Number(s.maxDrawdownBps),
        tradeCount: Number(s.tradeCount),
        tradesNeeded: Number(s.tradesNeeded),
        blocksLeft: s.blocksLeft.toString(),
        inTrade: Boolean(s.inTrade),
    };

    if (isJson(args)) return emitJson(obj);

    printRows([
        ['network', net.key],
        ['address', addr],
        ['eval active', obj.active ? 'yes' : 'no'],
        ['passed', obj.passed ? 'yes' : 'no'],
        ['return', `${(obj.returnBps / 100).toFixed(2)}% / ${(obj.targetBps / 100).toFixed(2)}%`],
        ['drawdown', `${(obj.drawdownBps / 100).toFixed(2)}% / ${(obj.maxDrawdownBps / 100).toFixed(2)}%`],
        ['trades', `${obj.tradeCount} / ${obj.tradesNeeded}`],
        ['blocks left', obj.blocksLeft],
        ['in trade', obj.inTrade ? 'yes' : 'no'],
    ]);
}

export async function evalStart(args) {
    const { net, propfund, usdc, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = resolvePrincipal(args);
    const fee = await propfund.EVAL_FEE();

    // Allowance must be on the funding source (principal when delegated, else the agent itself).
    const owner = principal ?? wallet.address;
    await ensureAllowance({
        usdc, owner, spender: propfund.target, needed: fee, json: isJson(args),
        // If we're delegating, the agent can't approve on behalf of the principal — bail with a clear hint.
        skipApprove: principal != null && wallet.address !== principal,
    });

    const tx = principal
        ? await propfund.startEvalFor(principal)
        : await propfund.startEval();
    const receipt = await waitTx(tx, 'startEval', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'startEvalFor' : 'startEval', principal, evalFee: fee.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    const who = principal ? `for ${principal}` : '';
    process.stdout.write(`paid ${fmtUsdc(fee, net.usdcDecimals)} USDC eval fee — eval started ${who}\n`);
}

// Resolve --asset SYM or --asset N to a numeric assetId. Used by evalTradeOpen.
function resolveAssetId(args, net) {
    const raw = args.flags.asset;
    if (raw === undefined || raw === '' || raw === true) return 0;
    if (/^\d+$/.test(String(raw))) {
        const idx = Number(raw);
        if (idx < 0 || idx >= (net.assetNames?.length ?? 256)) {
            throw new Error(`--asset index ${idx} out of range (0..${(net.assetNames?.length ?? 1) - 1})`);
        }
        return idx;
    }
    const sym = String(raw).toUpperCase();
    const idx = (net.assetNames ?? []).indexOf(sym);
    if (idx < 0) throw new Error(`--asset "${raw}" not listed on ${net.chainName}. options: ${(net.assetNames ?? []).join(', ')}`);
    return idx;
}

export async function evalClaim(args) {
    const { net, propfund, usdc, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = resolvePrincipal(args);
    const deposit = await propfund.TRADER_DEPOSIT();

    const owner = principal ?? wallet.address;
    await ensureAllowance({
        usdc, owner, spender: propfund.target, needed: deposit, json: isJson(args),
        skipApprove: principal != null && wallet.address !== principal,
    });

    const tx = principal
        ? await propfund.claimFundingFor(principal)
        : await propfund.claimFunding();
    const receipt = await waitTx(tx, 'claimFunding', isJson(args));

    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'claimFundingFor' : 'claimFunding', principal, deposit: deposit.toString(), txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    const who = principal ? `for ${principal}` : '';
    process.stdout.write(`paid ${fmtUsdc(deposit, net.usdcDecimals)} USDC deposit — funded ${who}\n`);
}

// Cancel an active evaluation. EVAL_FEE is non-refundable; this just frees up the slot.
export async function evalCancel(args) {
    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = resolvePrincipal(args);
    const tx = principal ? await propfund.cancelEvalFor(principal) : await propfund.cancelEval();
    const receipt = await waitTx(tx, 'cancelEval', isJson(args));
    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'cancelEvalFor' : 'cancelEval', principal, txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write('eval cancelled (EVAL_FEE non-refundable)\n');
}

// Virtual long on the chosen asset. Asset is picked per-trade — agent can rotate.
export async function evalTradeOpen(args) {
    const { net, propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = resolvePrincipal(args);
    const assetId = resolveAssetId(args, net);
    const tx = principal
        ? await propfund.openEvalTradeFor(principal, assetId)
        : await propfund.openEvalTrade(assetId);
    const receipt = await waitTx(tx, 'openEvalTrade', isJson(args));
    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'openEvalTradeFor' : 'openEvalTrade', principal, assetId, txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    const sym = net.assetNames?.[assetId] ?? `asset_${assetId}`;
    process.stdout.write(`eval trade opened (virtual long on ${sym})\n`);
}

export async function evalTradeClose(args) {
    const { propfund } = buildContext({ requireSigner: true, network: args.flags.network });
    const principal = resolvePrincipal(args);
    const tx = principal ? await propfund.closeEvalTradeFor(principal) : await propfund.closeEvalTrade();
    const receipt = await waitTx(tx, 'closeEvalTrade', isJson(args));
    if (isJson(args)) {
        return emitJson({ ok: true, action: principal ? 'closeEvalTradeFor' : 'closeEvalTrade', principal, txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write('eval trade closed\n');
}

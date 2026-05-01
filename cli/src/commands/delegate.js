import { getAddress, parseUnits } from 'ethers';
import { buildContext } from '../context.js';
import { emitJson, fmtUsdc, printRows } from '../format.js';
import { isJson, requireFlag, flag } from '../args.js';
import { waitTx } from '../tx.js';

// Authorize an agent to drive your full trader lifecycle.
//   --agent 0x...                  agent's EOA
//   --max-notional <USDC>          per-trade notional cap (USDC, not raw)
//   --expiry "2026-04-30T00:00:00Z" | --in 30d | --in 168h
export async function delegateSet(args) {
    const { net, propfund, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const agent = getAddress(requireFlag(args, 'agent'));
    const maxNotional = parseUnits(String(requireFlag(args, 'max-notional')), net.usdcDecimals);
    const expiry = parseExpiry(args);

    const tx = await propfund.setController(agent, maxNotional, expiry);
    const receipt = await waitTx(tx, 'setController', isJson(args));

    if (isJson(args)) {
        return emitJson({
            ok: true, action: 'setController',
            principal: wallet.address, agent,
            maxNotional: maxNotional.toString(),
            expiry: expiry.toString(),
            txHash: tx.hash, blockNumber: receipt.blockNumber,
        });
    }
    process.stdout.write(`authorized ${agent} on behalf of ${wallet.address}\n`);
    process.stdout.write(`  max notional ${fmtUsdc(maxNotional, net.usdcDecimals)} USDC / trade\n`);
    process.stdout.write(`  expires ${new Date(Number(expiry) * 1000).toISOString()}\n`);
    process.stdout.write(`\nremember to approve USDC: \`cast send <usdc> "approve(address,uint256)" <propfund> <budget>\`\n`);
}

export async function delegateRevoke(args) {
    const { propfund, wallet } = buildContext({ requireSigner: true, network: args.flags.network });
    const tx = await propfund.revokeController();
    const receipt = await waitTx(tx, 'revokeController', isJson(args));
    if (isJson(args)) {
        return emitJson({ ok: true, action: 'revokeController', principal: wallet.address, txHash: tx.hash, blockNumber: receipt.blockNumber });
    }
    process.stdout.write('controller revoked\n');
}

export async function delegateStatus(args) {
    const { net, propfund, wallet, usdc } = buildContext({ network: args.flags.network });
    const principal = args.flags.address || (wallet && wallet.address);
    if (!principal) throw new Error('pass --address or set PROPFUND_KEY');

    const [auth, allowance] = await Promise.all([
        propfund.controllers(principal),
        usdc.allowance(principal, propfund.target),
    ]);

    const obj = {
        network: net.key,
        principal,
        agent: auth.agent ?? auth[0],
        maxNotionalPerTrade: (auth.maxNotionalPerTrade ?? auth[1]).toString(),
        expiry: (auth.expiry ?? auth[2]).toString(),
        usdcAllowance: allowance.toString(),
    };
    if (isJson(args)) return emitJson(obj);

    const noAgent = obj.agent === '0x0000000000000000000000000000000000000000';
    const expiryNum = Number(obj.expiry);
    const expired = expiryNum > 0 && expiryNum < Math.floor(Date.now() / 1000);

    printRows([
        ['network', net.key],
        ['principal', principal],
        ['agent', noAgent ? '(none)' : obj.agent],
        ['max notional', noAgent ? '—' : fmtUsdc(obj.maxNotionalPerTrade, net.usdcDecimals) + ' USDC'],
        ['expiry', noAgent ? '—' : new Date(expiryNum * 1000).toISOString() + (expired ? ' (EXPIRED)' : '')],
        ['USDC allowance (budget)', fmtUsdc(allowance, net.usdcDecimals) + ' USDC'],
    ]);
}

function parseExpiry(args) {
    if (args.flags.expiry) {
        const t = new Date(String(args.flags.expiry));
        if (Number.isNaN(t.getTime())) throw new Error('invalid --expiry; use ISO 8601 (e.g., 2026-12-31T00:00:00Z)');
        return BigInt(Math.floor(t.getTime() / 1000));
    }
    if (args.flags.in) {
        const raw = String(args.flags.in).trim();
        const m = raw.match(/^(\d+)([smhd])$/);
        if (!m) throw new Error('invalid --in; use NN[smhd] e.g., 30d, 168h');
        const n = Number(m[1]);
        const mult = { s: 1n, m: 60n, h: 3600n, d: 86400n }[m[2]];
        return BigInt(Math.floor(Date.now() / 1000)) + BigInt(n) * mult;
    }
    throw new Error('pass --expiry ISO-timestamp or --in NN[smhd]');
}

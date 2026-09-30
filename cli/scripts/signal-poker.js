#!/usr/bin/env node
// SignalKeeper poker — the off-chain heartbeat for the fully on-chain, no-LLM agent.
//
// SignalKeeper.poke() is permissionless and logic-free from the caller's side: it samples the
// indicators when SAMPLE_INTERVAL has elapsed and opens a bracketed desk position when its long
// setup fires. Something still has to send the tx, because a pull oracle and the EVM never wake
// themselves up. This loop does that and nothing else — every decision stays on-chain.
//
// Each tick simulates poke() first (staticCall), so a stale oracle or any revert costs no gas.
//
// Env: PROPFUND_NETWORK / PROPFUND_RPC, PROPFUND_KEY (gas payer — use its own key, not a bot's,
//      so nonces never collide), SIGNAL_KEEPER (contract address), POKE_SEC (default 300).

import { JsonRpcProvider, Wallet, NonceManager, Contract, getAddress } from 'ethers';
import { resolveNetwork } from '../src/networks.js';

const net = resolveNetwork();
const rpcUrl = process.env.PROPFUND_RPC || net.rpcUrl;
const INTERVAL = Number(process.env.POKE_SEC || 300) * 1000;

const provider = new JsonRpcProvider(rpcUrl, net.chainId, { staticNetwork: true });
const signer = new NonceManager(new Wallet(
    (process.env.PROPFUND_KEY.startsWith('0x') ? '' : '0x') + process.env.PROPFUND_KEY, provider));
const keeper = new Contract(getAddress(process.env.SIGNAL_KEEPER), [
    'function poke(bytes[] priceUpdate) payable',
    'function samples() view returns (uint256)',
    'event Poked(uint256 price, bool sampled, bool entered, uint8 confirmations)',
], signer);

function log(level, event, extra = {}) {
    process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), level, event, ...extra }) + '\n');
}

log('INFO', 'poker-start', { network: net.key, rpc: rpcUrl, signalKeeper: keeper.target, intervalSec: INTERVAL / 1000 });

let consecutiveErrors = 0;
async function tick() {
    try {
        await keeper.poke.staticCall([], { gasLimit: 900_000n });
    } catch (e) {
        consecutiveErrors++;
        log('WARN', 'poke-skipped', { reason: String(e.shortMessage || e.message || e).slice(0, 160), consecutiveErrors });
        return;
    }
    try {
        const tx = await keeper.poke([], { gasLimit: 900_000n });
        const receipt = await tx.wait();
        const ev = receipt.logs.map(l => { try { return keeper.interface.parseLog(l); } catch { return null; } })
            .find(p => p?.name === 'Poked');
        consecutiveErrors = 0;
        log('INFO', ev?.args.entered ? 'poke-entered' : 'poked', {
            txHash: tx.hash,
            price: ev ? Number(ev.args.price) / 1e8 : null,
            sampled: ev?.args.sampled ?? null,
            confirmations: ev ? Number(ev.args.confirmations) : null,
            samples: Number(await keeper.samples()),
        });
    } catch (e) {
        consecutiveErrors++;
        log('ERROR', 'poke-failed', { error: String(e.shortMessage || e.message || e).slice(0, 160), consecutiveErrors });
    }
}

await tick();
setInterval(tick, INTERVAL);

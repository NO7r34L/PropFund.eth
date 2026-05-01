import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { JsonRpcProvider, Wallet, Contract, NonceManager, getAddress } from 'ethers';
import { resolveNetwork } from './networks.js';

const here = dirname(fileURLToPath(import.meta.url));
const ABI = JSON.parse(readFileSync(join(here, 'propfund.abi.json'), 'utf8'));

const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address,address) view returns (uint256)',
    'function approve(address,uint256) returns (bool)',
    'function mint(address,uint256)',
    'function decimals() view returns (uint8)',
    'function symbol() view returns (string)',
];

// Signed actions need PROPFUND_KEY. Read-only commands work with just an RPC.
export function buildContext({ requireSigner = false, network } = {}) {
    const net = resolveNetwork(network);
    if (!net.contractAddr) {
        throw new Error(`network "${net.key}" has no deployed contract address yet`);
    }

    const rpcUrl = process.env.PROPFUND_RPC || net.rpcUrl;
    const provider = new JsonRpcProvider(rpcUrl, net.chainId, { staticNetwork: true });

    let wallet = null;
    let signer = null;
    const key = process.env.PROPFUND_KEY;
    if (key) {
        const normalized = key.startsWith('0x') ? key : '0x' + key;
        wallet = new Wallet(normalized, provider);
        // Anvil sometimes returns a stale nonce from `pending` between back-to-back txs (e.g.
        // approve + startEval). NonceManager tracks the nonce locally, incrementing on each
        // submission so consecutive sends never collide.
        signer = new NonceManager(wallet);
    } else if (requireSigner) {
        throw new Error('PROPFUND_KEY env var required for signed transactions');
    }

    const runner = signer ?? provider;
    const propfund = new Contract(getAddress(net.contractAddr), ABI, runner);
    const usdc = new Contract(getAddress(net.usdcAddr), ERC20_ABI, runner);

    return { net, provider, wallet, propfund, usdc };
}

// Resolve human-readable asset names ("eth", "btc") to the on-chain index. Falls back
// to a numeric id if the user passes one directly.
export function resolveAssetId(net, input) {
    if (input == null) throw new Error('asset is required');
    const asNum = Number(input);
    if (Number.isInteger(asNum) && String(asNum) === String(input).trim()) {
        if (asNum < 0 || asNum >= net.assetNames.length) {
            throw new Error(`asset id ${asNum} out of range (0..${net.assetNames.length - 1})`);
        }
        return asNum;
    }
    const want = String(input).toUpperCase();
    const idx = net.assetNames.findIndex(n => n.toUpperCase() === want);
    if (idx < 0) {
        throw new Error(`unknown asset "${input}". known: ${net.assetNames.join(', ')}`);
    }
    return idx;
}

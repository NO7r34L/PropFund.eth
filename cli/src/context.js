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
        throw new Error(
            `network "${net.key}" has no contract address configured.\n` +
            `Three ways to fix this:\n` +
            `  1. Use a public deployment: edit cli/src/networks.js and set ` +
            `${net.key}.contractAddr / .usdcAddr to the official address.\n` +
            `  2. Deploy your own and paste the address into cli/src/networks.js. ` +
            `See script/Deploy${net.key === 'base' ? 'Base' : 'BaseSepolia'}.s.sol.\n` +
            `  3. Run a local fork: anvil + forge script script/DeployLocal.s.sol, ` +
            `then export PROPFUND_NETWORK=local PROPFUND_CONTRACT=0x... PROPFUND_USDC=0x... ` +
            `PROPFUND_RPC=http://localhost:8545.`
        );
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

/**
 * Verify networks.js asset ordering matches on-chain priceIds. Without this guard, an
 * out-of-sync `pythPriceIds` array (e.g. after a deploy where the asset list was rotated)
 * causes asset names to silently mis-resolve — "open LINK" actually opens SOL because
 * `assetNames[2]` is LINK off-chain but `priceIds(2)` is SOL/USD on-chain. Harmless
 * during eval (virtual balance), catastrophic in funded mode where it trades real USDC
 * against the wrong feed. Read-only; cheap; call once at agent / write-path startup.
 */
export async function assertAssetMapping(propfund, net) {
    if (!net.pythPriceIds || net.pythPriceIds.length === 0) {
        return;  // local-network deploys may not have pinned IDs — skip
    }
    const onChainCount = Number(await propfund.assetCount());
    const expected = net.pythPriceIds;
    if (onChainCount !== expected.length) {
        throw new Error(
            `asset-mapping: on-chain assetCount=${onChainCount} but networks.js[${net.key}] ` +
            `has ${expected.length} pythPriceIds. Update cli/src/networks.js to match the deploy.`
        );
    }
    for (let i = 0; i < onChainCount; i++) {
        const onChainId = (await propfund.priceIds(i)).toLowerCase();
        const expectedId = expected[i].toLowerCase();
        if (onChainId !== expectedId) {
            throw new Error(
                `asset-mapping mismatch at index ${i}: on-chain priceIds(${i}) = ${onChainId}, ` +
                `networks.js[${net.key}].pythPriceIds[${i}] = ${expectedId} ` +
                `(name "${net.assetNames?.[i]}"). Reorder cli/src/networks.js.assetNames + ` +
                `pythPriceIds to match the deployed contract, then restart.`
            );
        }
    }
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

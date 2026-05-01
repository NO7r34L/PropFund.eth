import { Interface } from 'ethers';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const ABI = JSON.parse(readFileSync(join(here, 'propfund.abi.json'), 'utf8'));
const IFACE = new Interface(ABI);

// Pyth's custom errors — used when pushPyth fails. Pyth reverts here with its own selectors;
// our PropFund ABI doesn't know them, so we'd see "unknown custom error" without this.
const PYTH_ERRORS = new Interface([
    'error InvalidArgument()',
    'error InvalidUpdateDataSource()',
    'error InvalidUpdateData()',
    'error InsufficientFee()',
    'error NoFreshUpdate()',
    'error PriceFeedNotFoundWithinRange()',
    'error PriceFeedNotFound()',
    'error StalePrice()',
    'error InvalidWormholeVaa()',
    'error InvalidGovernanceMessage()',
    'error InvalidGovernanceTarget()',
    'error InvalidGovernanceDataSource()',
    'error OldGovernanceMessage()',
    'error InvalidWormholeAddressToSet()',
]);

// Pull the contract revert hex out of an ethers CallException, wherever it landed.
// v6 stashes it in different places depending on RPC + provider path.
function extractRevertData(e) {
    if (!e) return null;
    if (typeof e.data === 'string' && e.data.startsWith('0x')) return e.data;
    const inner = e.info?.error?.data;
    if (typeof inner === 'string' && inner.startsWith('0x')) return inner;
    if (typeof e.revert?.data === 'string' && e.revert.data.startsWith('0x')) return e.revert.data;
    return null;
}

// Turn a contract revert into a friendly { name, args } pair when the ABI knows the selector.
// Falls back to the raw ethers message if it's not a known custom error.
export function decodeError(e) {
    const out = {
        message: e.shortMessage || e.reason || e.message || String(e),
        code: e.code,
    };
    const data = extractRevertData(e);
    if (!data || data === '0x') return out;

    // Try PropFund's interface first, then Pyth's. Either may be the actual originator.
    for (const iface of [IFACE, PYTH_ERRORS]) {
        try {
            const parsed = iface.parseError(data);
            if (parsed) {
                out.errorName = parsed.name;
                out.errorArgs = parsed.args.map(a => (typeof a === 'bigint' ? a.toString() : a));
                out.message = `${parsed.name}${parsed.args.length ? '(' + out.errorArgs.join(', ') + ')' : '()'}`;
                break;
            }
        } catch {}
    }
    out.data = data;
    return out;
}

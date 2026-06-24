// Network presets for the propfund CLI. Source of truth — no other configs depend on this.
// To add a new network, append an entry here and ship it as a CLI release.

export const NETWORKS = {
    basesepolia: {
        // PropFund on Base Sepolia. Fill `contractAddr` and `usdcAddr` after running
        // script/DeployBaseSepolia.s.sol — see README "Deploy" section.
        // Asset / Pyth-feed order matches the deploy script (and `base` mainnet entry below)
        // — must mirror the on-chain priceIds[i] order or asset names will mis-resolve.
        contractAddr: '',
        usdcAddr: '',
        chainId: 84532,
        chainName: 'Base Sepolia',
        rpcUrl: 'https://sepolia.base.org',
        assetNames: ['ETH', 'BTC', 'SOL', 'AVAX', 'LINK', 'AAVE', 'DOGE', 'ARB'],
        usdcDecimals: 6,
        priceDecimals: 8,
        usdcMintable: true,
        pythAddr: '0xA2aa501b19aff244D90cc15a4Cf739D2725B5729',
        pythPriceIds: [
            '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace',  // ETH/USD
            '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43',  // BTC/USD
            '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d',  // SOL/USD
            '0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7',  // AVAX/USD
            '0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221',  // LINK/USD
            '0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445',  // AAVE/USD
            '0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c',  // DOGE/USD
            '0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5',  // ARB/USD
        ],
        hermesUrl: 'https://hermes.pyth.network',
    },
    sepolia: {
        // PropFund on Ethereum Sepolia. Fill `contractAddr` and `usdcAddr` after running
        // script/DeploySepolia.s.sol. Asset / Pyth-feed order matches that deploy script
        // — must mirror the on-chain priceIds[i] order or asset names will mis-resolve.
        // Redeploy 2026-06-24: guardian/treasury role split + PropFundLens + $1 eval + bidirectional
        // scaling. TREASURY 0x85B73B9515c6edFa9d08248103dd384901d2403a, GUARDIAN 0x3ccEC158226f85960f6ddc14d64f03E657aA8411.
        contractAddr: '0x728d1739E494b7957B7b6A3Ba375006f58D296fc',
        usdcAddr: '0x92157CBCdf65DdC2F457B92e459E13e3eb258e33',
        // Atomic update+trade periphery — folds the Pyth update into the trade (one tx).
        routerAddr: '0x028c4D472c0173aea7cC378E9823F62f13eB2f42',
        // View layer — getTraderStats / getEvalStatus live here, not on the core contract.
        lensAddr: '0x7C8dB37aAb2678Ca2FE648d41e583A2F9187a8AE',
        chainId: 11155111,
        chainName: 'Ethereum Sepolia',
        // publicnode is more reliable than the flaky rpc.sepolia.org; matches the deployed bot's RPC.
        rpcUrl: 'https://ethereum-sepolia-rpc.publicnode.com',
        assetNames: ['ETH', 'BTC', 'SOL', 'AVAX', 'LINK', 'AAVE', 'DOGE', 'ARB'],
        usdcDecimals: 6,
        priceDecimals: 8,
        usdcMintable: true,
        // Pyth on Ethereum Sepolia — differs from Base Sepolia's 0xA2aa...; verified vs docs.pyth.network.
        pythAddr: '0xDd24F84d36BF92C65F92307595335bdFab5Bbd21',
        pythPriceIds: [
            '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace',  // ETH/USD
            '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43',  // BTC/USD
            '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d',  // SOL/USD
            '0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7',  // AVAX/USD
            '0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221',  // LINK/USD
            '0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445',  // AAVE/USD
            '0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c',  // DOGE/USD
            '0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5',  // ARB/USD
        ],
        hermesUrl: 'https://hermes.pyth.network',
    },
    base: {
        // Pyth-native PropFund on Base mainnet. ContractAddr filled in at mainnet launch.
        contractAddr: '',
        usdcAddr: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',  // native USDC on Base mainnet
        chainId: 8453,
        chainName: 'Base',
        rpcUrl: 'https://mainnet.base.org',
        assetNames: ['ETH', 'BTC', 'SOL', 'AVAX', 'LINK', 'AAVE', 'DOGE', 'ARB'],
        usdcDecimals: 6,
        priceDecimals: 8,
        usdcMintable: false,
        pythAddr: '0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a',
        pythPriceIds: [
            '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace',  // ETH/USD
            '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43',  // BTC/USD
            '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d',  // SOL/USD
            '0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7',  // AVAX/USD
            '0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221',  // LINK/USD
            '0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445',  // AAVE/USD
            '0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c',  // DOGE/USD
            '0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5',  // ARB/USD
        ],
        hermesUrl: 'https://hermes.pyth.network',
    },
};

export function resolveNetwork(name) {
    const key = (name || process.env.PROPFUND_NETWORK || 'basesepolia').toLowerCase();

    // The "local" preset is for an Anvil deploy. Addresses, asset names, and chain id come
    // from env vars so a fresh deploy is just a re-export — no code edits.
    if (key === 'local') {
        const required = ['PROPFUND_CONTRACT', 'PROPFUND_USDC', 'PROPFUND_RPC'];
        for (const v of required) {
            if (!process.env[v]) throw new Error(`network "local" needs ${required.join(', ')} env vars`);
        }
        const assetNames = (process.env.PROPFUND_ASSETS || 'ETH,BTC,LINK')
            .split(',').map(s => s.trim()).filter(Boolean);
        return {
            key: 'local',
            chainName: 'Anvil',
            chainId: Number(process.env.PROPFUND_CHAIN_ID || 31337),
            rpcUrl: process.env.PROPFUND_RPC,
            contractAddr: process.env.PROPFUND_CONTRACT,
            usdcAddr: process.env.PROPFUND_USDC,
            assetNames,
            usdcDecimals: 6,
            priceDecimals: 8,
            usdcMintable: true,
        };
    }

    const net = NETWORKS[key];
    if (!net) {
        const known = [...Object.keys(NETWORKS), 'local'].join(', ');
        throw new Error(`unknown network "${key}". known: ${known}`);
    }
    return { ...net, key };
}

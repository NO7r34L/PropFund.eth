// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Deploy on Base mainnet (chain id 8453) with real Pyth + native USDC.
// Run:
//   PRIVATE_KEY=0x... forge script script/DeployBase.s.sol:DeployBaseScript \
//     --rpc-url https://mainnet.base.org --broadcast

import {Script, console} from "forge-std/Script.sol";
import {PropFund} from "../src/PropFund.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

contract DeployBaseScript is Script {
    // Base mainnet (chain id 8453)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;  // native USDC on Base
    address constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;  // Pyth on Base mainnet

    // Canonical Pyth price IDs — same across all chains.
    bytes32 constant ETH_USD  = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant BTC_USD  = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant SOL_USD  = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    bytes32 constant AVAX_USD = 0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7;
    bytes32 constant LINK_USD = 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221;
    bytes32 constant AAVE_USD = 0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445;
    bytes32 constant DOGE_USD = 0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c;
    bytes32 constant ARB_USD  = 0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        bytes32[] memory ids = new bytes32[](8);
        ids[0] = ETH_USD;   // eval asset
        ids[1] = BTC_USD;
        ids[2] = SOL_USD;
        ids[3] = AVAX_USD;
        ids[4] = LINK_USD;
        ids[5] = AAVE_USD;
        ids[6] = DOGE_USD;
        ids[7] = ARB_USD;

        // Mainnet: tighter staleAfter — Base mainnet has many Pyth users pushing constantly.
        uint256[] memory staleAfter = new uint256[](8);
        staleAfter[0] = 5 minutes;   // ETH
        staleAfter[1] = 5 minutes;   // BTC
        staleAfter[2] = 5 minutes;   // SOL
        staleAfter[3] = 30 minutes;  // AVAX
        staleAfter[4] = 30 minutes;  // LINK
        staleAfter[5] = 30 minutes;  // AAVE
        staleAfter[6] = 30 minutes;  // DOGE
        staleAfter[7] = 30 minutes;  // ARB

        vm.startBroadcast(pk);

        PropFund fund = new PropFund(PropFund.Config({
            usdc: IERC20(USDC),
            pyth: IPyth(PYTH),
            treasury: deployer,
            evalFee: 10e6,
            fundedAllocation: 1_000e6,
            evalDuration: 1_296_000,      // 30 days at 2s blocks on Base
            traderDeposit: 100e6,
            maxFundedTraders: 50,
            priceIds: ids,
            staleAfter: staleAfter
        }));

        // NOTE: real USDC on Base mainnet — pool has to be seeded by an LP.
        // Deployer should approve + deposit separately, or run a follow-up `propfund lp deposit`.

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYED TO BASE MAINNET ===");
        console.log("PropFund:", address(fund));
        console.log("EvalCert:", address(fund.CERT()));
        console.log("Pyth:    ", PYTH);
        console.log("USDC:    ", USDC, "(native)");
        console.log("Assets:  ETH, BTC, SOL, AVAX, LINK, AAVE, DOGE, ARB (Pyth)");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Update cli/src/networks.js base.contractAddr");
        console.log("  2. Seed pool: propfund lp deposit --amount 50000 (or however much)");
        console.log("  3. Verify on https://basescan.org/address/<addr>");
    }
}

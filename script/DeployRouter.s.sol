// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Deploy the atomic-update periphery (PropFundRouter) alongside an existing PropFund.
// PropFund itself is untouched — the router is opt-in: a principal authorizes it via
// PropFund.setController(router, cap, expiry), then trades through it for single-tx update+trade.
//
// Run (Ethereum Sepolia, against the live PropFund + Pyth):
//   PRIVATE_KEY=0x... forge script script/DeployRouter.s.sol:DeployRouterScript \
//     --rpc-url <ETH_SEPOLIA_RPC> --broadcast --verify --etherscan-api-key <KEY>
//
// Override the targets with PROPFUND / PYTH env vars to deploy against any chain.

import {Script, console} from "forge-std/Script.sol";
import {PropFundRouter, IPropFundTrades} from "../src/PropFundRouter.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

contract DeployRouterScript is Script {
    // Defaults: live Ethereum Sepolia deployment.
    address constant DEFAULT_PROPFUND = 0xd566A2224915F2C8D1feE99109276340f1De937c;
    address constant DEFAULT_PYTH     = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address propfund = vm.envOr("PROPFUND", DEFAULT_PROPFUND);
        address pyth = vm.envOr("PYTH", DEFAULT_PYTH);

        console.log("Deployer:", vm.addr(pk));
        console.log("PropFund:", propfund);
        console.log("Pyth:    ", pyth);

        vm.startBroadcast(pk);
        PropFundRouter router = new PropFundRouter(IPyth(pyth), IPropFundTrades(propfund));
        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYED ===");
        console.log("PropFundRouter:", address(router));
        console.log("");
        console.log("Next: each trader authorizes the router once via");
        console.log("  PropFund.setController(router, maxNotionalPerTrade, expiry)");
        console.log("then calls router.openTrade/closeTrade/openEvalTrade/closeEvalTrade with Pyth updateData.");
    }
}

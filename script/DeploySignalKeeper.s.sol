// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Deploy a SignalKeeper — a fully on-chain, no-LLM systematic desk agent — against an existing
// AgentDesk. The firm must preapprove it (or it must qualify); the owner then fund()s its USDC
// deposit and calls admitToDesk(). A permissionless poker calls poke() on a cadence thereafter.
//
// Required env: PRIVATE_KEY, DESK, USDC, PYTH
// Optional env: ETH_PRICE_ID, SAMPLE_INTERVAL (900), STALE_AFTER (300), ORB_WINDOW (3600),
//               TP_BPS (600), SL_BPS (150), RSI_LONG_MAX_E2 (4000), MIN_CONFIRMATIONS (2)

import {Script, console} from "forge-std/Script.sol";
import {SignalKeeper, IAgentDeskMin} from "../src/SignalKeeper.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

contract DeploySignalKeeperScript is Script {
    bytes32 constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        SignalKeeper k = new SignalKeeper(SignalKeeper.Config({
            owner: vm.addr(pk),
            pyth: IPyth(vm.envAddress("PYTH")),
            ethPriceId: bytes32(vm.envOr("ETH_PRICE_ID", uint256(ETH_USD))),
            desk: IAgentDeskMin(vm.envAddress("DESK")),
            usdc: IERC20(vm.envAddress("USDC")),
            sampleInterval: vm.envOr("SAMPLE_INTERVAL", uint256(900)),
            staleAfter: vm.envOr("STALE_AFTER", uint256(300)),
            orbWindow: vm.envOr("ORB_WINDOW", uint256(3600)),
            tpBps: vm.envOr("TP_BPS", uint256(600)),
            slBps: vm.envOr("SL_BPS", uint256(150)),
            rsiLongMaxE2: vm.envOr("RSI_LONG_MAX_E2", uint256(4000)),
            minConfirmations: uint8(vm.envOr("MIN_CONFIRMATIONS", uint256(2)))
        }));
        vm.stopBroadcast();
        console.log("SignalKeeper:", address(k));
    }
}

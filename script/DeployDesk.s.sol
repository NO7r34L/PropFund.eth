// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Deploy AgentDesk against an existing PropFund lens.
//
// Required env:  PRIVATE_KEY, PROPFUND_LENS, USDC, PYTH
// Optional env:  WETH   (deploys MockWETH if unset)
//                VENUE  (deploys + funds a MockSwap at Pyth spot if unset — devnet/fork only)
//                FUND_USDC (6dp, default 5_000e6) — the firm's initial capital
//                BASE_ALLOCATION (default 500e6), AGENT_DEPOSIT (50e6), MAX_DD_BPS (1000),
//                AGENT_SPLIT_BPS (5000), MIN_CUM_PNL (10e6), MIN_TRADES (5), STALE_AFTER (300)
//
// Run (devnet):
//   PRIVATE_KEY=0x... PROPFUND_LENS=0x... USDC=0x... PYTH=0xA2aa50... \
//     forge script script/DeployDesk.s.sol:DeployDeskScript --rpc-url http://127.0.0.1:8550 --broadcast

import {Script, console} from "forge-std/Script.sol";
import {AgentDesk} from "../src/AgentDesk.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {ISwapVenue} from "../src/interfaces/ISwapVenue.sol";
import {IPropFundLens} from "../src/interfaces/IPropFundLens.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockSwap} from "../test/mocks/MockSwap.sol";

interface IMintable { function mint(address to, uint256 amount) external; }

contract DeployDeskScript is Script {
    bytes32 constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address lens = vm.envAddress("PROPFUND_LENS");
        address usdc = vm.envAddress("USDC");
        address pyth = vm.envAddress("PYTH");
        uint256 fundUsdc = vm.envOr("FUND_USDC", uint256(5_000e6));

        vm.startBroadcast(pk);

        address weth = vm.envOr("WETH", address(0));
        if (weth == address(0)) {
            weth = address(new MockWETH());
            console.log("MockWETH deployed:", weth);
        }

        address venue = vm.envOr("VENUE", address(0));
        if (venue == address(0)) {
            MockSwap ms = new MockSwap(IERC20(usdc), IERC20(weth), IPyth(pyth), ETH_USD, 10); // 0.1% haircut
            venue = address(ms);
            // seed the mock pool so it can fill both directions
            IMintable(usdc).mint(venue, 2_000_000e6);
            MockWETH(weth).mint(venue, 1_000e18);
            console.log("MockSwap deployed + seeded:", venue);
        }

        AgentDesk desk = new AgentDesk(AgentDesk.Config({
            owner: deployer,
            usdc: IERC20(usdc),
            weth: IERC20(weth),
            pyth: IPyth(pyth),
            ethPriceId: ETH_USD,
            lens: IPropFundLens(lens),
            venue: ISwapVenue(venue),
            baseAllocation: vm.envOr("BASE_ALLOCATION", uint256(500e6)),
            agentDeposit:   vm.envOr("AGENT_DEPOSIT", uint256(50e6)),
            maxDrawdownBps: vm.envOr("MAX_DD_BPS", uint256(1000)),
            agentSplitBps:  vm.envOr("AGENT_SPLIT_BPS", uint256(5000)),
            minCumPnl:      int256(vm.envOr("MIN_CUM_PNL", uint256(10e6))),
            minTrades:      vm.envOr("MIN_TRADES", uint256(5)),
            staleAfter:     vm.envOr("STALE_AFTER", uint256(300))
        }));

        // the firm funds its own desk
        IERC20(usdc).approve(address(desk), fundUsdc);
        desk.fund(fundUsdc);

        vm.stopBroadcast();

        console.log("");
        console.log("=== AGENT DESK DEPLOYED ===");
        console.log("AgentDesk:", address(desk));
        console.log("WETH:     ", weth);
        console.log("Venue:    ", venue);
        console.log("Lens:     ", lens);
        console.log("Firm idle:", desk.firmIdle());
    }
}

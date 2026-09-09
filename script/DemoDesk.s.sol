// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Self-contained AgentDesk DEMO on a throwaway local anvil: deploys every mock (USDC, WETH,
// Pyth, lens, swap venue) and a desk with tiny ladder thresholds so the whole lifecycle —
// admit → wins → scale-ups → loss → scale-down → keeper liquidation — runs in seconds.
//
// Demo settings (NOT the production defaults in DeployDesk.s.sol):
//   ladder tiers $10 / $25 / $50 realized (vs $100 / $250 / $600), 2 / 4 / 6 closed trades
//   (vs 40 / 80 / 120), lens bar disabled (agent is preapproved). Everything else is production.
//
// Required env: PRIVATE_KEY (firm/deployer), AGENT (address to preapprove)
// Run:  forge script script/DemoDesk.s.sol:DemoDeskScript --rpc-url http://127.0.0.1:8546 --broadcast

import {Script, console} from "forge-std/Script.sol";
import {AgentDesk} from "../src/AgentDesk.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {ISwapVenue} from "../src/interfaces/ISwapVenue.sol";
import {IPropFundLens} from "../src/interfaces/IPropFundLens.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockPyth} from "../test/mocks/MockPyth.sol";
import {MockLens} from "../test/mocks/MockLens.sol";
import {MockSwap} from "../test/mocks/MockSwap.sol";

contract DemoDeskScript is Script {
    bytes32 constant ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address agent = vm.envAddress("AGENT");
        vm.startBroadcast(pk);

        MockUSDC usdc = new MockUSDC();
        MockWETH weth = new MockWETH();
        MockPyth pyth = new MockPyth();
        MockLens lens = new MockLens();
        pyth.setSpotE8(ETH_USD, 2500e8);
        MockSwap venue = new MockSwap(IERC20(address(usdc)), IERC20(address(weth)), IPyth(address(pyth)), ETH_USD, 10); // 0.1%/side, like the devnet
        usdc.mint(address(venue), 2_000_000e6);
        weth.mint(address(venue), 1_000e18);

        AgentDesk desk = new AgentDesk(AgentDesk.Config({
            owner: vm.addr(pk),
            usdc: IERC20(address(usdc)),
            weth: IERC20(address(weth)),
            pyth: IPyth(address(pyth)),
            ethPriceId: ETH_USD,
            lens: IPropFundLens(address(lens)),
            venue: ISwapVenue(address(venue)),
            baseAllocation: 500e6,
            agentDeposit: 50e6,
            maxDrawdownBps: 1000,
            agentSplitBps: 4000,
            minCumPnl: 0,
            minTrades: 0,
            minProfitFactorBps: 0,
            staleAfter: 1 hours,
            scaleT2Bps: 200,     // $10 realized  -> 2x   (demo; prod 2000 = $100)
            scaleT4Bps: 500,     // $25           -> 4x   (demo; prod 5000 = $250)
            scaleT8Bps: 1000,    // $50           -> 8x   (demo; prod 12000 = $600)
            maxAllocationMult: 8,
            scaleMinTrades: 2,   // 2 / 4 / 6 closed trades (demo; prod 40 / 80 / 120)
            alphaMarginBps: 0
        }));

        usdc.mint(vm.addr(pk), 10_000e6);
        usdc.approve(address(desk), 10_000e6);
        desk.fund(10_000e6);
        desk.setPreapproved(agent, true);
        usdc.mint(agent, 1_000e6);

        vm.stopBroadcast();

        console.log("DESK:", address(desk));
        console.log("USDC:", address(usdc));
        console.log("PYTH:", address(pyth));
        console.log("VENUE:", address(venue));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PropFund} from "../src/PropFund.sol";
import {PropFundRouter, IPropFundTrades} from "../src/PropFundRouter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice The atomic-update periphery drives a trader's full lifecycle via the delegation
/// system. Prices are set directly on MockPyth, so tests pass an empty updateData (the
/// _update path is exercised on-chain against live Pyth, not here). The router must end every
/// call holding no position, deposit, or balance.
contract RouterTest is Test {
    PropFund fund;
    PropFundRouter router;
    MockUSDC usdc;
    MockPyth pyth;
    bytes32 constant ETH_ID = bytes32(uint256(1));

    address lp = address(0x1111);
    address treasury = address(0xDE5);
    address trader = address(0xA11CE);

    uint256 constant EVAL_FEE = 10e6;
    uint256 constant TRADER_DEPOSIT = 100e6;

    function setUp() public {
        usdc = new MockUSDC();
        pyth = new MockPyth();
        pyth.setSpotE8(ETH_ID, 4000e8);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 1 hours;

        fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: treasury,
            evalFee: EVAL_FEE,
            fundedAllocation: 1_000e6,
            evalDuration: 50_400,
            traderDeposit: TRADER_DEPOSIT,
            maxFundedTraders: 5,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));
        router = new PropFundRouter(IPyth(address(pyth)), IPropFundTrades(address(fund)));

        usdc.mint(lp, 1_000_000e6);
        vm.prank(lp); usdc.approve(address(fund), type(uint256).max);
        vm.prank(lp); fund.deposit(50_000e6);

        usdc.mint(trader, 10_000e6);
        vm.prank(trader); usdc.approve(address(fund), type(uint256).max);
        // Authorize the router as the trader's controller — the one-time setup.
        vm.prank(trader); fund.setController(address(router), 1_000e6, uint64(block.timestamp + 365 days));
    }

    function _empty() internal pure returns (bytes[] memory) {
        return new bytes[](0);
    }

    /// Full lifecycle: every price-sensitive action goes through the router; the
    /// non-price-sensitive ones (startEval/claimFunding/withdraw) the trader does directly.
    function test_RouterDrivesFullLifecycle() public {
        vm.prank(trader); fund.startEval();

        uint256[3] memory prices = [uint256(4120e8), 4243e8, 4370e8];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader); router.openEvalTrade(_empty(), 0);
            pyth.setSpotE8(ETH_ID, int256(prices[i]));
            vm.roll(block.number + 10);
            vm.prank(trader); router.closeEvalTrade(_empty());
        }
        (,,,,,,, bool passed,) = fund.evals(trader);
        assertTrue(passed, "eval passes via router");

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader); fund.claimFunding();
        (bool active,,,) = fund.funded(trader);
        assertTrue(active);

        // Funded open via the router (leverage 2 = baseline level, no level-up needed).
        vm.prank(trader); router.openTrade(_empty(), 0, 10_000, false, 8000e8, 2000e8, 2);
        (,,,,,, bool posActive,,) = fund.positions(trader);
        assertTrue(posActive, "position opened via router");

        // Price up, close via the router for profit.
        pyth.setSpotE8(ETH_ID, 4200e8);
        vm.prank(trader); router.closeTrade(_empty(), 10_000);
        (, int256 cumPnl,,) = fund.funded(trader);
        assertGt(cumPnl, 0, "profit realized via router");

        // Router is custody-free: never holds a position, deposit, or balance.
        (,,,,,, bool stillOpen,,) = fund.positions(trader);
        assertFalse(stillOpen);
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no USDC");
        assertEq(address(router).balance, 0, "router holds no ETH");
    }

    /// Unused msg.value (sent to cover the Pyth fee) is refunded in the same tx.
    function test_RouterRefundsExcessValue() public {
        vm.prank(trader); fund.startEval();
        vm.deal(trader, 1 ether);
        uint256 before = trader.balance;
        // Empty update -> no Pyth fee charged -> the whole msg.value comes back.
        vm.prank(trader); router.openEvalTrade{value: 0.5 ether}(_empty(), 0);
        assertEq(trader.balance, before, "all unused value refunded");
        assertEq(address(router).balance, 0, "router retains nothing");
    }

    /// A caller who never authorized the router can't drive trades through it.
    function test_RouterRequiresAuthorization() public {
        address stranger = address(0xBEEF);
        usdc.mint(stranger, 1_000e6);
        vm.prank(stranger); usdc.approve(address(fund), type(uint256).max);
        vm.prank(stranger); fund.startEval();
        vm.prank(stranger);
        vm.expectRevert(PropFund.NotAuthorized.selector);
        router.openEvalTrade(_empty(), 0);
    }
}

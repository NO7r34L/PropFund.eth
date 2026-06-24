// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// End-to-end lifecycle traces with verbose console output.
// Run:    forge test --match-contract LifecycleTest -vvv
// Shows every state transition a real trader walks through.

import {Test, console} from "forge-std/Test.sol";
import {PropFund} from "../src/PropFund.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract LifecycleTest is Test {
    PropFund fund;
    MockUSDC usdc;
    MockPyth pyth;
    bytes32 constant ETH_ID = bytes32(uint256(1));

    address lp = address(0x1111);
    address trader = address(0xA11CE);
    address treasury = address(0xDE5);
    address guardian = address(0xDEA);

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
            guardian: guardian,
            evalFee: 10e6,
            fundedAllocation: 1_000e6,
            evalDuration: 50_400,
            traderDeposit: 100e6,
            maxFundedTraders: 50,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));

        usdc.mint(lp, 100_000e6);
        usdc.mint(trader, 1_000e6);
        vm.prank(lp); usdc.approve(address(fund), type(uint256).max);
        vm.prank(trader); usdc.approve(address(fund), type(uint256).max);

        vm.prank(lp); fund.deposit(50_000e6);
    }

    /// Happy path: eval → pass → claim funding → profitable trade → withdraw.
    function test_Lifecycle_HappyPath() public {
        _banner("HAPPY PATH: eval -> pass -> fund -> profit -> withdraw");

        _logTraderState("0. Fresh wallet");

        // 1. Start eval ($10 fee)
        vm.prank(trader); fund.startEval();
        _logEvalState("1. Eval started");

        // 2. Three eval trades each gaining ~3% (3% * 3 = ~9% - passes the 8% bar)
        _evalTrade(4120e8);  // +3%
        _logEvalState("2a. After eval trade 1 (+3%)");
        _evalTrade(4243e8);  // +3% on top
        _logEvalState("2b. After eval trade 2 (+3%)");
        _evalTrade(4370e8);  // +3% more
        _logEvalState("2c. After eval trade 3 (+3%) -> PASSED");

        // 3. Claim funding ($100 deposit)
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader); fund.claimFunding();
        _grantMaxLevel();
        _logTraderState("3. Funded - $100 deposit, ready to trade");

        // 4. Open a 100% long position. With $100 deposit, deploys $200.
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        _logPositionState("4. Long ETH opened @ $4000 (deployed $200)");

        // 5. ETH +10%
        pyth.setSpotE8(ETH_ID, 4400e8);
        _logPositionState("5. ETH +10% -> position has $20 unrealized");

        // 6. Close at profit. PnL=+$20. Trader keeps 80%=$16, LP 15%=$3, Treasury 5%=$1.
        vm.prank(trader); fund.closeTrade(10_000);
        _logTraderState("6. Closed at profit ($16 to deposit, $1 to treasury)");

        // 7. Withdraw $10 of profit
        vm.prank(trader); fund.withdrawProfit(10e6);
        _logTraderState("7. Withdrew $10 of profit");

        // Final assertions - confirm the math matches what the user sees in the UI
        (, int256 cumPnl, uint256 dep,) = fund.funded(trader);
        assertGt(dep, 100e6, "deposit must have grown beyond initial $100");
        assertGt(cumPnl, 0, "cumPnl must be positive");
        // Treasury fees accrue and are pulled separately (post-M-3 treasury-path pull-pattern fix).
        assertEq(fund.treasuryBalance(), 1e6, "treasury fees accrued = $1");
        vm.prank(treasury); fund.withdrawTreasury();
        assertEq(usdc.balanceOf(treasury), 1e6, "treasury got 5% fee after withdraw = $1");
    }

    /// Failure path: eval → pass → claim → trade → LOSS.
    /// Same setup as happy path, but the trade goes against the trader.
    function test_Lifecycle_FailAtProfitStage() public {
        _banner("FAIL AT TRADE STAGE: eval -> pass -> fund -> losing trade");

        _logTraderState("0. Fresh wallet");

        // 1-3. Same eval pass + funding
        vm.prank(trader); fund.startEval();
        _evalTrade(4120e8); _evalTrade(4243e8); _evalTrade(4370e8);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader); fund.claimFunding();
        _grantMaxLevel();
        _logTraderState("1-3. Funded ($100 deposit)");

        // 4. Open 100% long
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        _logPositionState("4. Long ETH opened @ $4000 (deployed $200)");

        // 5. ETH -10%
        pyth.setSpotE8(ETH_ID, 3600e8);
        _logPositionState("5. ETH -10% -> position has -$20 unrealized");

        // 6. Close at loss. -$20 absorbed by deposit. Pool keeps the gain (counterparty).
        vm.prank(trader); fund.closeTrade(10_000);
        _logTraderState("6. Closed at loss (deposit $100 -> $80, no treasury fee on losses)");

        // Final assertions
        (, int256 cumPnl, uint256 dep,) = fund.funded(trader);
        assertEq(dep, 80e6, "deposit dropped to $80 after $20 loss");
        assertLt(cumPnl, 0, "cumPnl must be negative");
        assertEq(fund.treasuryBalance(), 0, "no treasury fees accrue on losses");
    }

    /// Helpers ────────────────────────────────────────────────────────────

    function _evalTrade(uint256 closePrice) internal {
        vm.prank(trader); fund.openEvalTrade(0);
        pyth.setSpotE8(ETH_ID, int256(closePrice));
        vm.roll(block.number + 10);
        vm.prank(trader); fund.closeEvalTrade();
    }

    /// Hot-patch funded[trader].lastLevel = MAX_LEVERAGE so leverage-4 lifecycle traces
    /// don't have to grind through tier crossings first.
    function _grantMaxLevel() internal {
        bytes32 baseSlot = keccak256(abi.encode(trader, uint256(11)));
        vm.store(address(fund), bytes32(uint256(baseSlot) + 3), bytes32(uint256(10)));
    }

    function _banner(string memory s) internal pure {
        console.log("");
        console.log("================================================================");
        console.log(s);
        console.log("================================================================");
    }

    function _logTraderState(string memory label) internal view {
        console.log("");
        console.log(label);
        (bool active, int256 cumPnl, uint256 deposit,) = fund.funded(trader);
        console.log("  funded.active   :", active);
        console.log("  deposit         :", deposit / 1e6, "USDC");
        console.log("  cumulative PnL  :");
        console.logInt(cumPnl / 1e6);
        console.log("  trader balance  :", usdc.balanceOf(trader) / 1e6, "USDC");
        console.log("  pool balance    :", fund.poolBalance() / 1e6, "USDC");
        console.log("  treasury fees earned :", fund.treasuryBalance() / 1e6, "USDC");
    }

    function _logEvalState(string memory label) internal view {
        console.log("");
        console.log(label);
        PropFund.EvalStatus memory s = fund.getEvalStatus(trader);
        console.log("  eval.active     :", s.active);
        console.log("  eval.passed     :", s.passed);
        console.log("  return (bps)    :", s.returnBps, "/", s.targetBps);
        console.log("  drawdown (bps)  :", s.drawdownBps, "/", s.maxDrawdownBps);
        console.log("  trade count     :", s.tradeCount, "/", s.tradesNeeded);
    }

    function _logPositionState(string memory label) internal view {
        console.log("");
        console.log(label);
        (uint256 deployed, uint64 entryPrice,,,, uint8 assetId, bool active, bool isShort,) = fund.positions(trader);
        console.log("  position.active :", active);
        console.log("  deployed        :", deployed / 1e6, "USDC");
        console.log("  entryPrice      :", entryPrice);
        console.log("  isShort         :", isShort);
        console.log("  assetId         :", assetId);
    }
}

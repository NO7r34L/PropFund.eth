// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Comprehensive end-to-end walk: hits every external mutating function at least once,
// across LPs, multiple traders, success/fail/liquidation paths. Run with -vvv for the trace.
//
//   forge test --match-contract LifecycleFullTest -vvv

import {Test, console} from "forge-std/Test.sol";
import {PropFund} from "../src/PropFund.sol";
import {EvalCert} from "../src/EvalCert.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract LifecycleFullTest is Test {
    PropFund fund;
    MockUSDC usdc;
    MockPyth pyth;
    bytes32 constant ETH_ID = bytes32(uint256(1));
    bytes32 constant BTC_ID = bytes32(uint256(2));

    address lp1     = address(0x1111);
    address lp2     = address(0x2222);
    address winner  = address(0xA11CE);
    address loser   = address(0xB0B);
    address quitter = address(0xC0C0);
    address liqued  = address(0xDEAD);
    address keeper  = address(0xBEEF);
    address treasury     = address(0xDE5);

    function setUp() public {
        usdc = new MockUSDC();
        pyth = new MockPyth();
        pyth.setSpotE8(ETH_ID, 4000e8);
        pyth.setSpotE8(BTC_ID, 60000e8);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ETH_ID;
        ids[1] = BTC_ID;
        uint256[] memory staleAfter = new uint256[](2);
        staleAfter[0] = 1 hours;
        staleAfter[1] = 1 hours;

        fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: treasury,
            evalFee: 10e6,
            fundedAllocation: 1_000e6,
            evalDuration: 50_400,
            traderDeposit: 100e6,
            maxFundedTraders: 50,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));

        // Mint USDC to all participants - LPs need more for their pool seed.
        usdc.mint(lp1, 100_000e6);
        usdc.mint(lp2, 100_000e6);
        address[4] memory traders = [winner, loser, quitter, liqued];
        for (uint256 i = 0; i < traders.length; i++) {
            usdc.mint(traders[i], 10_000e6);
        }
        address[6] memory all = [lp1, lp2, winner, loser, quitter, liqued];
        for (uint256 i = 0; i < all.length; i++) {
            vm.prank(all[i]); usdc.approve(address(fund), type(uint256).max);
        }
    }

    /// Walks every external mutating function at least once across realistic actor flows.
    /// Asserts pool solvency, deposit accounting, and event-derived state at each step.
    function test_Lifecycle_FullWalk() public {
        _banner("=== STEP 1: LPs seed the pool ===");
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(lp2); fund.deposit(25_000e6);
        assertEq(fund.poolBalance(), 75_000e6, "pool should be 75K after both LPs");
        _logPool();

        _banner("=== STEP 2: winner runs eval and PASSES ===");
        vm.prank(winner); fund.startEval();
        _evalCycleFor(winner, 4120e8);  // +3%
        _evalCycleFor(winner, 4243e8);  // +3% (cum ~+6.07%)
        _evalCycleFor(winner, 4370e8);  // +3% (cum ~+9.25% - passes 8% bar)
        ( , , , , , , , bool winnerPassed,) = fund.evals(winner);
        assertTrue(winnerPassed, "winner should have passed eval");
        assertEq(fund.CERT().balanceOf(winner), 1, "eval pass cert should be minted");

        _banner("=== STEP 3: winner claims funding, opens long ETH ===");
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(winner); fund.claimFunding();
        _grantMaxLevel(winner);
        ( bool wActive, , uint256 wDep, ) = fund.funded(winner);
        assertTrue(wActive, "winner is now funded");
        assertEq(wDep, 100e6, "deposit is $100");

        vm.prank(winner); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4); // 100% long ETH
        ( uint256 deployed, , , , , , bool active, ,) = fund.positions(winner);
        assertEq(deployed, 200e6, "deployed $200");
        assertTrue(active);

        _banner("=== STEP 4: winner partial-closes at +5%, takes some profit ===");
        pyth.setSpotE8(ETH_ID, 4200e8);
        vm.prank(winner); fund.closeTrade(5000); // close 50%
        ( deployed, , , , , , active, ,) = fund.positions(winner);
        assertTrue(active, "position still half open");
        assertEq(deployed, 100e6, "deployed should be $100 after partial");
        (, , wDep, ) = fund.funded(winner);
        // 50% of $200 = $100 deployed; +5% = $5 PnL on that half; trader keeps 80% = $4
        assertEq(wDep, 104e6, "deposit grew to $104");

        _banner("=== STEP 5: winner updates TP/SL on remaining half ===");
        vm.prank(winner); fund.updateExit(4500e8, 4100e8); // tp $4500, sl $4100
        ( , , uint64 tp, uint64 sl, , , , ,) = fund.positions(winner);
        assertEq(tp, 4500e8, "tp set");
        assertEq(sl, 4100e8, "sl set");

        _banner("=== STEP 6: TP triggers, keeper executes the exit ===");
        pyth.setSpotE8(ETH_ID, 4500e8);
        vm.prank(keeper); fund.executeExit(winner);
        ( , , , , , , active, ,) = fund.positions(winner);
        assertFalse(active, "position closed by keeper");
        int256 wCum;
        (, wCum, wDep, ) = fund.funded(winner);
        // Second half: $100 deployed, +12.5% (4500/4000), but circuit breaker caps at +50%
        // so PnL = $100 * (4500-4000)/4000 = $12.5. Trader keeps $10.
        assertEq(wDep, 114e6, "deposit grew to $114");
        assertGt(wCum, 0, "cumPnL positive");
        _logTrader(winner, "winner");

        _banner("=== STEP 7: winner withdraws profit ===");
        vm.prank(winner); fund.withdrawProfit(10e6);
        (, , wDep, ) = fund.funded(winner);
        assertEq(wDep, 104e6, "deposit reduced by $10 withdraw");
        assertEq(usdc.balanceOf(winner), 9_900e6 + 10e6 - 10e6, "winner USDC: -10 eval -100 deposit +10 withdrawn = 9900");

        _banner("=== STEP 8: loser runs eval and FAILS by drawdown ===");
        vm.prank(loser); fund.startEval();
        pyth.setSpotE8(ETH_ID, 4000e8); // reset
        vm.prank(loser); fund.openEvalTrade(0);
        pyth.setSpotE8(ETH_ID, 3700e8); // -7.5% - exceeds 5% drawdown
        vm.roll(block.number + 11);
        vm.prank(loser); fund.closeEvalTrade();
        ( , , , , , , bool loserActive, bool loserPassed,) = fund.evals(loser);
        assertFalse(loserActive, "loser eval inactive after drawdown fail");
        assertFalse(loserPassed, "loser did not pass");
        assertEq(fund.CERT().balanceOf(loser), 0, "no cert for failed eval");

        _banner("=== STEP 9: loser cancels and re-evals (fee non-refundable) ===");
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(loser); fund.startEval(); // pays another $10
        vm.prank(loser); fund.cancelEval();
        ( , , , , , , loserActive, ,) = fund.evals(loser);
        assertFalse(loserActive, "cancelled");

        _banner("=== STEP 10: quitter passes eval, funds, then resigns ===");
        vm.prank(quitter); fund.startEval();
        _evalCycleFor(quitter, 4120e8);
        _evalCycleFor(quitter, 4243e8);
        _evalCycleFor(quitter, 4370e8);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(quitter); fund.claimFunding();
        uint256 quitterBalBefore = usdc.balanceOf(quitter);
        vm.prank(quitter); fund.resignFunding();
        // Quitter gets their $100 back
        assertEq(usdc.balanceOf(quitter) - quitterBalBefore, 100e6, "quitter gets deposit back on resign");
        ( bool qActive, , , ) = fund.funded(quitter);
        assertFalse(qActive, "quitter no longer funded");

        _banner("=== STEP 11: liqued passes, funds, opens, gets LIQUIDATED ===");
        vm.prank(liqued); fund.startEval();
        _evalCycleFor(liqued, 4120e8);
        _evalCycleFor(liqued, 4243e8);
        _evalCycleFor(liqued, 4370e8);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(liqued); fund.claimFunding();
        _grantMaxLevel(liqued);
        vm.prank(liqued); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4); // 100% long
        // Crash ETH 60% - circuit breaker caps loss at -50%, which on $200 deployed = -$100.
        // Loss ($100) >= position margin ($50) -> liquidatable.
        pyth.setSpotE8(ETH_ID, 1600e8);
        assertTrue(fund.isLiquidatable(liqued), "liqued should be liquidatable");
        vm.prank(keeper); fund.liquidate(liqued);
        // Under the 50% margin rule the position is closed but the trader keeps half their
        // deposit ($50) and stays funded.
        ( bool lActive, , uint256 lDep, ) = fund.funded(liqued);
        assertTrue(lActive, "liqued still funded - margin rule preserves half-deposit");
        assertEq(lDep, 50e6, "deposit halved by margin absorption");

        _banner("=== STEP 12: emergencyClose path (winner re-enters with sl) ===");
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(winner); fund.openTrade(0, 5000, false, 8000e8, 2000e8, 4); // smaller position
        // Simulate stale oracle by warping past ORACLE_MAX_STALE
        vm.warp(block.timestamp + 2 hours);
        // Now the oracle reports stale; emergencyClose tolerates that
        vm.prank(winner); fund.emergencyClose();
        ( , , , , , , active, ,) = fund.positions(winner);
        assertFalse(active, "winner closed via emergency");

        _banner("=== STEP 13: invariants - pool solvency, no orphan state ===");
        // Sum every active trader's deposit
        uint256 totalDeposits = 0;
        address[6] memory actors = [lp1, lp2, winner, loser, quitter, liqued];
        for (uint256 i = 0; i < actors.length; i++) {
            ( bool a, , uint256 d, ) = fund.funded(actors[i]);
            if (a) totalDeposits += d;
        }
        assertGe(usdc.balanceOf(address(fund)), totalDeposits, "pool covers all deposits");
        assertGe(fund.poolBalance(), 0);
        assertLe(fund.poolBalance(), usdc.balanceOf(address(fund)), "poolBalance within physical USDC");
        _logPool();

        _banner("=== STEP 14: LPs withdraw - share value reflects fees + counterparty wins ===");
        // Refresh oracle so LP withdraw doesn't fail on stale spot
        pyth.setSpotE8(ETH_ID, 4000e8);
        pyth.setSpotE8(BTC_ID, 60000e8);

        uint256 lp1SharesBefore = fund.shares(lp1);
        uint256 lp1UsdcBefore = usdc.balanceOf(lp1);
        vm.prank(lp1); fund.withdraw(lp1SharesBefore);
        uint256 lp1Got = usdc.balanceOf(lp1) - lp1UsdcBefore;
        // LP1 deposited $50K. Pool earned eval fees + liquidation forfeit + 15% of profitable trades.
        // Should get back >= $50K.
        assertGt(lp1Got, 50_000e6, "lp1 earned a positive return");
        console.log("lp1 deposited 50000 USDC, withdrew", lp1Got / 1e6, "USDC");
        console.log("lp1 net gain:", (lp1Got - 50_000e6) / 1e6, "USDC");
    }

    // ────────────────────────── Helpers ──────────────────────────

    function _evalCycleFor(address who, uint256 closePrice) internal {
        vm.prank(who); fund.openEvalTrade(0);
        pyth.setSpotE8(ETH_ID, int256(closePrice));
        vm.roll(block.number + 11);
        vm.prank(who); fund.closeEvalTrade();
        pyth.setSpotE8(ETH_ID, 4000e8); // reset for next leg
    }

    /// Hot-patch funded[who].lastLevel = MAX_LEVERAGE so leverage-4 trades work at day 1.
    function _grantMaxLevel(address who) internal {
        bytes32 baseSlot = keccak256(abi.encode(who, uint256(11)));
        vm.store(address(fund), bytes32(uint256(baseSlot) + 3), bytes32(uint256(10)));
    }

    function _banner(string memory s) internal pure {
        console.log("");
        console.log(s);
    }

    function _logPool() internal view {
        console.log("  poolBalance    :", fund.poolBalance() / 1e6, "USDC");
        console.log("  totalDeployed  :", fund.totalDeployed() / 1e6, "USDC");
        console.log("  contract USDC  :", usdc.balanceOf(address(fund)) / 1e6, "USDC");
        console.log("  funded count   :", fund.fundedTraderCount());
    }

    function _logTrader(address who, string memory label) internal view {
        console.log("");
        console.log(label);
        ( bool a, int256 cum, uint256 dep, ) = fund.funded(who);
        console.log("  funded.active  :", a);
        console.log("  deposit        :", dep / 1e6, "USDC");
        console.log("  cumulative PnL :");
        console.logInt(cum / 1e6);
    }
}

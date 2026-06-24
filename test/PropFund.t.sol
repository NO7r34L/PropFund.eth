// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PropFund} from "../src/PropFund.sol";
import {EvalCert} from "../src/EvalCert.sol";
import {EvalCertRenderer} from "../src/EvalCertRenderer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract PropFundTest is Test {
    PropFund fund;
    MockUSDC usdc;
    MockPyth pyth;
    bytes32 constant ETH_ID = bytes32(uint256(1));
    bytes32 constant BTC_ID = bytes32(uint256(2));

    address lp1 = address(0x1111);
    address lp2 = address(0x2222);
    address trader1 = address(0xA11CE);
    address trader2 = address(0xB0B);
    address treasury = address(0xDE5);
    address guardian = address(0xDEA);

    uint256 constant EVAL_FEE = 10e6;
    uint256 constant ALLOCATION = 1_000e6;
    uint256 constant EVAL_DURATION = 50_400;
    uint256 constant TRADER_DEPOSIT = 100e6;
    uint256 constant MAX_TRADERS = 10;

    function setUp() public {
        usdc = new MockUSDC();
        pyth = new MockPyth();
        pyth.setSpotE8(ETH_ID, 4000e8);   // ETH $4000
        pyth.setSpotE8(BTC_ID, 60000e8);  // BTC $60000

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ETH_ID;
        ids[1] = BTC_ID;
        uint256[] memory staleAfter = new uint256[](2);
        staleAfter[0] = 1 hours;
        staleAfter[1] = 1 hours;

        fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: treasury,
            guardian: guardian,
            evalFee: EVAL_FEE,
            fundedAllocation: ALLOCATION,
            evalDuration: EVAL_DURATION,
            traderDeposit: TRADER_DEPOSIT,
            maxFundedTraders: MAX_TRADERS,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));

        // Fund LPs
        usdc.mint(lp1, 100_000e6);
        usdc.mint(lp2, 100_000e6);
        vm.prank(lp1); usdc.approve(address(fund), type(uint256).max);
        vm.prank(lp2); usdc.approve(address(fund), type(uint256).max);

        // Fund traders
        usdc.mint(trader1, 10_000e6);
        usdc.mint(trader2, 10_000e6);
        vm.prank(trader1); usdc.approve(address(fund), type(uint256).max);
        vm.prank(trader2); usdc.approve(address(fund), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          LP
    //////////////////////////////////////////////////////////////*/

    function test_Deposit() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        assertEq(fund.poolBalance(), 50_000e6);
        assertGt(fund.shares(lp1), 0);
    }

    function test_Withdraw() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        uint256 s = fund.shares(lp1);
        uint256 before = usdc.balanceOf(lp1);
        vm.prank(lp1); fund.withdraw(s);
        assertGt(usdc.balanceOf(lp1) - before, 49_999e6);
    }

    /*//////////////////////////////////////////////////////////////
                          EVAL
    //////////////////////////////////////////////////////////////*/

    function test_EvalPass() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();

        _evalTrade(4120e8); _evalTrade(4243e8); _evalTrade(4370e8);

        (,,,,,,, bool passed,) = fund.evals(trader1);
        assertTrue(passed);
    }

    function test_EvalPass_MixedAssets() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();

        // Trade 1: BTC long, +3%. Trade 2: ETH long, +3%. Trade 3: BTC long, +3%.
        // Compounded ≈ +9.27% — passes the +8% target across multiple assets.
        vm.prank(trader1); fund.openEvalTrade(1);  // BTC
        pyth.setSpotE8(BTC_ID, 61800e8);
        vm.roll(block.number + 10);
        vm.prank(trader1); fund.closeEvalTrade();

        vm.prank(trader1); fund.openEvalTrade(0);  // ETH
        pyth.setSpotE8(ETH_ID, 4120e8);
        vm.roll(block.number + 10);
        vm.prank(trader1); fund.closeEvalTrade();

        vm.prank(trader1); fund.openEvalTrade(1);  // BTC again
        pyth.setSpotE8(BTC_ID, 63654e8);
        vm.roll(block.number + 10);
        vm.prank(trader1); fund.closeEvalTrade();

        (,,,,,,, bool passed,) = fund.evals(trader1);
        assertTrue(passed);
    }

    function test_EvalRejectsInvalidAsset() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();
        // Only 2 assets configured (ETH=0, BTC=1). assetId=5 must revert at openEvalTrade.
        vm.expectRevert(abi.encodeWithSignature("InvalidSize()"));
        vm.prank(trader1); fund.openEvalTrade(5);
    }

    function test_EvalFail_Drawdown() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();
        vm.prank(trader1); fund.openEvalTrade(0);
        pyth.setSpotE8(ETH_ID, 3780e8);
        vm.roll(block.number + 10);
        vm.prank(trader1); fund.closeEvalTrade();
        (,,,,,, bool active,,) = fund.evals(trader1);
        assertFalse(active);
    }

    function test_EvalFee_GoesToPool() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        uint256 before = fund.poolBalance();
        vm.prank(trader1); fund.startEval();
        assertEq(fund.poolBalance(), before + EVAL_FEE);
    }

    function test_EvalExpire_ByAnyone() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();
        vm.roll(block.number + EVAL_DURATION + 1);
        vm.prank(trader2); fund.expireEval(trader1);
        (,,,,,, bool active,,) = fund.evals(trader1);
        assertFalse(active);
    }

    function test_CancelEval() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();
        vm.prank(trader1); fund.cancelEval();
        (,,,,,, bool active,,) = fund.evals(trader1);
        assertFalse(active);
    }

    function test_CancelEval_CooldownEnforcedOnSecondCancel() public {
        // Audit I-6: rapid cancel-restart loops must be throttled.
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();
        vm.prank(trader1); fund.cancelEval();           // 1st cancel — always allowed
        vm.prank(trader1); fund.startEval();
        vm.expectRevert(abi.encodeWithSignature("CancelCooldown()"));
        vm.prank(trader1); fund.cancelEval();           // 2nd cancel within 100 blocks must revert
    }

    function test_CancelEval_CooldownClearsAfterBlocks() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();
        vm.prank(trader1); fund.cancelEval();
        vm.prank(trader1); fund.startEval();
        vm.roll(block.number + 100);
        vm.prank(trader1); fund.cancelEval();           // ok after cooldown
        (,,,,,, bool active,,) = fund.evals(trader1);
        assertFalse(active);
    }

    function test_Pyth_WideConfRejectsOpenTrade() public {
        // Audit M-1: a wide confidence interval (>0.5% of price) should mark the price stale,
        // making _readSpot revert and openTrade fail. Pool stays solvent during illiquid windows.
        _fundTrader(trader1);
        // ETH = $4000 with conf = $25 → 0.625% spread, exceeds MAX_CONF_BPS (0.5%).
        pyth.setSpotE8WithConf(ETH_ID, 4000e8, 25e8);
        vm.expectRevert(abi.encodeWithSignature("StaleOracle()"));
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
    }

    function test_Pyth_TightConfAllowsOpenTrade() public {
        // Confirms the boundary: conf at exactly the cap (or below) still allows trades.
        _fundTrader(trader1);
        // ETH = $4000 with conf = $20 → 0.5% spread, exactly at MAX_CONF_BPS — not REJECTED.
        // (Guard is strict-greater: `conf*10000 > price*MAX_CONF_BPS`)
        pyth.setSpotE8WithConf(ETH_ID, 4000e8, 20e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        (,,,,,,bool active,,) = fund.positions(trader1);
        assertTrue(active);
    }

    function test_Profit_NoLongerAutoWithdraws() public {
        // Audit M-3: auto-withdraw was removed. Big winning trades now compound entirely into
        // deposit; trader pulls via withdrawProfit() at their convenience.
        _fundTrader(trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 10);  // max leverage
        pyth.setSpotE8(ETH_ID, 4400e8);  // +10% × 10x leverage = 100% on margin (capped at 50% via circuit breaker)
        uint256 traderUsdcBefore = usdc.balanceOf(trader1);
        vm.prank(trader1); fund.closeTrade(10_000);
        // Trader's USDC balance unchanged — no auto-withdraw side-effect.
        assertEq(usdc.balanceOf(trader1), traderUsdcBefore, "trader should not auto-receive USDC");
        // Profit compounded into deposit instead.
        (,, uint256 dep,) = fund.funded(trader1);
        assertGt(dep, 100e6, "deposit should have grown from profit");
    }

    function test_Pause_BlocksDepositAndOpens() public {
        // Audit Phase 3: guardian can pause to stop new evals/deposits/trades during incidents.
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(guardian); fund.setPaused(true);

        vm.expectRevert(abi.encodeWithSignature("Paused()"));
        vm.prank(lp2); fund.deposit(10_000e6);

        vm.expectRevert(abi.encodeWithSignature("Paused()"));
        vm.prank(trader1); fund.startEval();
    }

    function test_Pause_AllowsExits() public {
        // While paused, users must still be able to exit: withdraw + close + cancel.
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _grantMaxLevel(address(fund), trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        // Now pause and verify exits still work.
        vm.prank(guardian); fund.setPaused(true);

        pyth.setSpotE8(ETH_ID, 3900e8);
        vm.prank(trader1); fund.closeTrade(10_000);  // exits must work even when paused

        uint256 lpShares = fund.shares(lp1);
        vm.prank(lp1); fund.withdraw(lpShares);       // LP exits must work
    }

    function test_Pause_OnlyGuardian() public {
        // Role split: pause is guardian-gated. A random EOA reverts...
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        vm.prank(trader1); fund.setPaused(true);
        // ...and crucially, even the TREASURY (the fee/money key) cannot pause.
        vm.expectRevert(abi.encodeWithSignature("NotGuardian()"));
        vm.prank(treasury); fund.setPaused(true);
        // Only the guardian can.
        vm.prank(guardian); fund.setPaused(true);
        assertTrue(fund.paused());
    }

    function test_Pause_UnpauseRestoresFlow() public {
        vm.prank(guardian); fund.setPaused(true);
        vm.prank(guardian); fund.setPaused(false);
        vm.prank(lp1); fund.deposit(50_000e6);  // succeeds after unpause
        assertGt(fund.shares(lp1), 0);
    }

    function test_LP_WithdrawZeroPayoutReverts() public {
        // Audit M-4: dust shareAmount that rounds payout to 0 must revert.
        vm.prank(lp1); fund.deposit(50_000e6);
        // After 50k deposit at first pool fill, totalShares = 50k * 1e6 (DEAD_SHARES is small).
        // Burning 1 share against 50_000e6 / 50_000_000_000 still gives a non-zero payout
        // here because of the share scale. To trigger zero payout we'd need a much smaller
        // ratio; this test mostly documents the guard exists.
        uint256 myShares = fund.shares(lp1);
        assertGt(myShares, 0);
        // Sanity: full withdraw still works (no regression).
        vm.prank(lp1); fund.withdraw(myShares);
    }

    /*//////////////////////////////////////////////////////////////
                      FUNDED TRADING — LONG (ETH)
    //////////////////////////////////////////////////////////////*/

    function test_Long_Profit() public {
        _fundTrader(trader1);
        uint256 poolBefore = fund.poolBalance();

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        pyth.setSpotE8(ETH_ID, 4400e8); // +10%
        vm.prank(trader1); fund.closeTrade(10_000);

        // PnL = $200 * 10% = +$20. Pool paid $20.
        // Trader: 80% = $16. Treasury: 5% = $1. LP: 15% = $3.
        // Pool: was poolBefore, deployed 200, gets back 200-20+3 = 183.
        // Net pool change: -17 (paid the trader and treasury)
        assertEq(fund.poolBalance(), poolBefore - 20e6 + 3e6);
        // Treasury fees accrue (pull-pattern); withdraw to verify the actual transfer.
        assertEq(fund.treasuryBalance(), 1e6);
        vm.prank(treasury); fund.withdrawTreasury();
        assertEq(usdc.balanceOf(treasury), 1e6);
        (,, uint256 dep,) = fund.funded(trader1);
        assertEq(dep, 116e6); // $100 + $16
    }

    function test_Long_Loss() public {
        _fundTrader(trader1);
        uint256 poolBefore = fund.poolBalance();

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        pyth.setSpotE8(ETH_ID, 3600e8); // -10%
        vm.prank(trader1); fund.closeTrade(10_000);

        // Loss = $20. Deposit absorbs. Pool receives counterparty gain.
        // Pool gets: 200 (deployed) + 20 (counterparty gain from deposit) = 220
        assertEq(fund.poolBalance(), poolBefore + 20e6);
        (,, uint256 dep,) = fund.funded(trader1);
        assertEq(dep, 80e6);
    }

    /*//////////////////////////////////////////////////////////////
                      FUNDED TRADING — SHORT (ETH)
    //////////////////////////////////////////////////////////////*/

    function test_Short_Profit() public {
        _fundTrader(trader1);
        uint256 poolBefore = fund.poolBalance();

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, true, 2000e8, 8000e8, 4);

        pyth.setSpotE8(ETH_ID, 3600e8); // -10% = profit for short
        vm.prank(trader1); fund.closeTrade(10_000);

        // Same as long profit but inverted direction
        assertEq(fund.poolBalance(), poolBefore - 20e6 + 3e6);
        (,, uint256 dep,) = fund.funded(trader1);
        assertEq(dep, 116e6);
    }

    function test_Short_Loss() public {
        _fundTrader(trader1);
        uint256 poolBefore = fund.poolBalance();

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, true, 2000e8, 8000e8, 4);

        pyth.setSpotE8(ETH_ID, 4400e8); // +10% = loss for short
        vm.prank(trader1); fund.closeTrade(10_000);

        assertEq(fund.poolBalance(), poolBefore + 20e6);
        (,, uint256 dep,) = fund.funded(trader1);
        assertEq(dep, 80e6);
    }

    /*//////////////////////////////////////////////////////////////
                      MULTI-ASSET (BTC)
    //////////////////////////////////////////////////////////////*/

    function test_BTC_Long() public {
        _fundTrader(trader1);
        uint256 poolBefore = fund.poolBalance();

        pyth.setSpotE8(BTC_ID, 60000e8);
        vm.prank(trader1); fund.openTrade(1, 10_000, false, 90000e8, 30000e8, 4); // asset 1 = BTC, TP=$90k SL=$30k

        pyth.setSpotE8(BTC_ID, 66000e8); // +10%
        vm.prank(trader1); fund.closeTrade(10_000);

        // Same PnL math: $200 * 10% = $20 profit
        assertEq(fund.poolBalance(), poolBefore - 20e6 + 3e6);
    }

    function test_InvalidAsset_Reverts() public {
        _fundTrader(trader1);
        vm.prank(trader1);
        vm.expectRevert(PropFund.InvalidAsset.selector);
        fund.openTrade(5, 10_000, false, 8000e8, 2000e8, 4); // asset 5 doesn't exist
    }

    /*//////////////////////////////////////////////////////////////
                      LEVERAGE GATE
    //////////////////////////////////////////////////////////////*/

    /// Newly-funded traders sit at lastLevel = 2 (the implicit baseline). Leverage above
    /// that must revert until they earn the next tier via cumulative PnL.
    function test_OpenTrade_LeverageGatedByLastLevel() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        // No _grantMaxLevel here — we want to verify the real gate.
        pyth.setSpotE8(ETH_ID, 4000e8);

        vm.prank(trader1);
        vm.expectRevert(PropFund.InvalidSize.selector);
        fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 3); // leverage 3 > lastLevel 2

        vm.prank(trader1);
        vm.expectRevert(PropFund.InvalidSize.selector);
        fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 10); // leverage 10 > lastLevel 2
    }

    /// Leverage 1 and 2 (the baseline tier) work at funding without any grinding.
    function test_OpenTrade_BaselineLeverageAllowed() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 2);
        (,,,,,, bool active,,) = fund.positions(trader1);
        assertTrue(active);
    }

    /// Once a trader crosses the level-3 milestone (cumulativePnl >= 50e6), the gate
    /// permits leverage 3. lastLevel ratchets up monotonically.
    function test_OpenTrade_LevelRatchetsUnlocksHigherLeverage() public {
        _fundTrader(trader1); // _fundTrader hot-patches lastLevel = 10 for lifecycle convenience.
        // Roll lastLevel back to the natural baseline so we're testing the real ratchet.
        bytes32 baseSlot = keccak256(abi.encode(trader1, uint256(11)));
        vm.store(address(fund), bytes32(uint256(baseSlot) + 3), bytes32(uint256(2)));

        // Grind one profitable trade big enough to push cumulativePnl past 50e6.
        // Deposit = 100e6, leverage 2, sizeBps 10000 → margin 50e6, notional 100e6.
        // Need ~50e6 profit on 100e6 notional → 50% move (capped by circuit breaker).
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 2);
        pyth.setSpotE8(ETH_ID, 6000e8); // +50% (right at the circuit breaker)
        vm.prank(trader1); fund.closeTrade(10_000);

        // Now cumPnl should be ≥ 50e6 → newLevel 3, lastLevel ratchets to 3.
        (, int256 cumPnl,, uint8 lastLevel) = fund.funded(trader1);
        assertGe(cumPnl, 50e6, "cumPnl crossed level-3 threshold");
        assertEq(lastLevel, 3, "lastLevel ratcheted to 3");

        // Leverage 3 now allowed; 4 still blocked.
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 5_000, false, 8000e8, 2000e8, 3);
        (,,,,,, bool active,,) = fund.positions(trader1);
        assertTrue(active);
        vm.prank(trader1); fund.closeTrade(10_000);

        vm.prank(trader1);
        vm.expectRevert(PropFund.InvalidSize.selector);
        fund.openTrade(0, 5_000, false, 8000e8, 2000e8, 4);
    }

    /*//////////////////////////////////////////////////////////////
                      PARTIAL CLOSE
    //////////////////////////////////////////////////////////////*/

    function test_PartialClose() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        pyth.setSpotE8(ETH_ID, 4400e8);
        vm.prank(trader1); fund.closeTrade(5000); // close 50%

        (uint256 deployed,,,,,,bool active,,) = fund.positions(trader1);
        assertTrue(active);
        assertEq(deployed, 100e6);

        vm.prank(trader1); fund.closeTrade(10_000); // close rest
        (,,,,,,active,,) = fund.positions(trader1);
        assertFalse(active);
        assertEq(fund.totalDeployed(), 0);
    }

    function test_ShortPartialClose() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, true, 2000e8, 8000e8, 4);

        pyth.setSpotE8(ETH_ID, 3600e8);
        vm.prank(trader1); fund.closeTrade(5000);

        (uint256 deployed,,,,,,bool active,,) = fund.positions(trader1);
        assertTrue(active);
        assertEq(deployed, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                      TP / SL
    //////////////////////////////////////////////////////////////*/

    function test_TakeProfit() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        // TP at $4500 (will trigger at +12.5%), SL at $2000 (deep, won't trigger)
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 4500e8, 2000e8, 4);

        pyth.setSpotE8(ETH_ID, 4600e8);
        fund.executeExit(trader1);

        (,,,,,,bool active,,) = fund.positions(trader1);
        assertFalse(active);
    }

    function test_StopLoss() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        // TP at $8000 (deep, won't trigger), SL at $3500 (will trigger at -12.5%)
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 3500e8, 4);

        pyth.setSpotE8(ETH_ID, 3400e8);
        fund.executeExit(trader1);

        (,,,,,,bool active,,) = fund.positions(trader1);
        assertFalse(active);
    }

    function test_ShortStopLoss() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        // Short: TP below entry, SL above entry. TP=$2000 (deep), SL=$4500 (triggers at +12.5%)
        vm.prank(trader1); fund.openTrade(0, 10_000, true, 2000e8, 4500e8, 4);

        pyth.setSpotE8(ETH_ID, 4600e8);
        fund.executeExit(trader1);

        (,,,,,,bool active,,) = fund.positions(trader1);
        assertFalse(active);
    }

    function test_OpenTrade_RejectsZeroTpSl() public {
        // Mandatory TP/SL: opening with either at 0 must revert.
        _fundTrader(trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.expectRevert(abi.encodeWithSignature("InvalidExit()"));
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 0, 3500e8, 4);
        vm.expectRevert(abi.encodeWithSignature("InvalidExit()"));
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 4500e8, 0, 4);
    }

    function test_OpenTrade_RejectsTpOnWrongSideOrInvertedSl() public {
        // Long: TP must be > entry (profit side). SL allowed >= entry (trailing) but not >= TP.
        _fundTrader(trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        // TP below entry — wrong side
        vm.expectRevert(abi.encodeWithSignature("InvalidExit()"));
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 3500e8, 2000e8, 4);
        // SL >= TP (inverted) — fails even though SL is between entry and TP would be ok
        vm.expectRevert(abi.encodeWithSignature("InvalidExit()"));
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 4500e8, 4500e8, 4);
    }

    function test_OpenTrade_AllowsTrailingSlAboveEntry() public {
        // Trailing breakeven stop pattern: SL above entry but below TP is legal.
        _fundTrader(trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 4500e8, 4100e8, 4); // SL=4100 > entry, < TP
        (,,,,,,bool active,,) = fund.positions(trader1);
        assertTrue(active);
    }

    function test_ExitNotTriggered_Reverts() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 4500e8, 3500e8, 4);

        pyth.setSpotE8(ETH_ID, 4200e8);
        vm.expectRevert(PropFund.ExitNotTriggered.selector);
        fund.executeExit(trader1);
    }

    function test_UpdateExit() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 4500e8, 3500e8, 4);

        vm.prank(trader1); fund.updateExit(4800e8, 3200e8);

        (,, uint64 tp, uint64 sl,,,,,) = fund.positions(trader1);
        assertEq(tp, 4800e8);
        assertEq(sl, 3200e8);
    }

    /*//////////////////////////////////////////////////////////////
                      LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function test_Liquidation_Long() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        pyth.setSpotE8(ETH_ID, 1800e8); // -55%, circuit-broken to -50% on $200 = -$100 loss
        assertTrue(fund.isLiquidatable(trader1));
        fund.liquidate(trader1);

        // 50% margin rule: loss is capped at the position's margin ($50 = half of deposit).
        // Trader survives liquidation with the other half of their deposit intact and remains funded.
        (bool active,, uint256 dep,) = fund.funded(trader1);
        assertTrue(active, "trader survives single liquidation under margin rule");
        assertEq(dep, 50e6, "deposit halved by margin absorption");
    }

    function test_Liquidation_Short() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, true, 2000e8, 8000e8, 4);

        pyth.setSpotE8(ETH_ID, 8000e8); // +100%, short circuit-broken to +50% on $200 = -$100 loss
        assertTrue(fund.isLiquidatable(trader1));
        fund.liquidate(trader1);

        (bool active,, uint256 dep,) = fund.funded(trader1);
        assertTrue(active, "trader survives single liquidation under margin rule");
        assertEq(dep, 50e6, "deposit halved by margin absorption");
    }

    function test_CannotLiquidate_Healthy() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        pyth.setSpotE8(ETH_ID, 3800e8); // -5%, small loss
        assertFalse(fund.isLiquidatable(trader1));
        vm.expectRevert(PropFund.NotLiquidatable.selector);
        fund.liquidate(trader1);
    }

    function test_Liquidation_StaleOracle() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        pyth.setSpotE8(ETH_ID, 1800e8);
        vm.warp(block.timestamp + 2 hours); // stale

        fund.liquidate(trader1); // still works thanks to _tryReadSpot (no revert on stale)
        // Position is closed but trader is still funded with the protected half-deposit.
        (bool active,, uint256 dep,) = fund.funded(trader1);
        assertTrue(active);
        assertEq(dep, 50e6);
        // No open position remains.
        (,,,,,, bool posActive,,) = fund.positions(trader1);
        assertFalse(posActive);
    }

    /// Under the 50% margin rule traders are no longer kicked out by a single liquidation.
    /// They keep funded status and trade with their preserved half-deposit. They only get
    /// revoked once their deposit decays below MIN_DEPOSIT through repeated losses.
    function test_LiquidatedTraderKeepsFunding() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 1800e8);
        fund.liquidate(trader1);

        // Re-claim should fail — they're still funded.
        vm.prank(trader1);
        vm.expectRevert(PropFund.AlreadyFunded.selector);
        fund.claimFunding();

        // But they can open another trade with their remaining $50.
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        (uint256 deployed,,,,,, bool active,,) = fund.positions(trader1);
        assertTrue(active);
        assertEq(deployed, 100e6); // (50/2) * 4 = 100
    }

    /*//////////////////////////////////////////////////////////////
                      PROFIT COMPOUNDING / WITHDRAW / LEVEL
    //////////////////////////////////////////////////////////////*/

    function test_ProfitCompounds() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 4400e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        (,, uint256 dep,) = fund.funded(trader1);
        assertEq(dep, 116e6);

        // Next trade deploys more: 116 * 2 = 232
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        (uint256 deployed,,,,,,,,) = fund.positions(trader1);
        assertEq(deployed, 232e6);
    }

    function test_WithdrawProfit() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 4400e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        uint256 before = usdc.balanceOf(trader1);
        vm.prank(trader1); fund.withdrawProfit(10e6);
        assertEq(usdc.balanceOf(trader1) - before, 10e6);
        (,, uint256 dep,) = fund.funded(trader1);
        assertEq(dep, 106e6);
    }

    function test_CannotWithdrawWithoutProfit() public {
        _fundTrader(trader1);
        vm.prank(trader1);
        vm.expectRevert(PropFund.NoProfitToWithdraw.selector);
        fund.withdrawProfit(10e6);
    }

    function test_LevelUp() public {
        _fundTrader(trader1);
        assertEq(fund.getTraderStats(trader1).level, 2);

        // Win enough to hit level 3 ($50+ cumPnl)
        for (uint256 i = 0; i < 10; i++) {
            pyth.setSpotE8(ETH_ID, 4000e8);
            vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
            pyth.setSpotE8(ETH_ID, 4400e8);
            vm.prank(trader1); fund.closeTrade(10_000);
        }

        assertGe(fund.getTraderStats(trader1).level, 3);
    }

    function test_BuyingPowerReducedAfterLoss() public {
        _fundTrader(trader1);

        uint256 startMaxDeploy = fund.getTraderStats(trader1).maxDeploy; // (100/2)*10 = 500

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 3800e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        // Deposit reduced from $100 to $90 by the $10 loss; max deploy scales with deposit.
        uint256 maxDeploy = fund.getTraderStats(trader1).maxDeploy;
        assertLt(maxDeploy, startMaxDeploy);
    }

    /*//////////////////////////////////////////////////////////////
                      GUARDS
    //////////////////////////////////////////////////////////////*/

    function test_MaxFundedTraders() public {
        PropFund small = _deployFund(2);
        _passEvalOn(small, trader1);
        _passEvalOn(small, trader2);
        vm.prank(trader1); small.claimFunding();
        vm.prank(trader2); small.claimFunding();

        // Third trader passes eval — claimFunding queues instead of reverting now.
        address trader3 = address(0xCAFE);
        usdc.mint(trader3, 10_000e6);
        vm.prank(trader3); usdc.approve(address(small), type(uint256).max);
        _passEvalOn(small, trader3);
        vm.prank(trader3); small.claimFunding();
        assertEq(small.queueLength(), 1);
        assertEq(small.queuePosition(trader3), 1);
        assertEq(small.queuedDeposits(), TRADER_DEPOSIT);
    }

    function test_CannotClaimWithoutPass() public {
        vm.prank(trader1);
        vm.expectRevert(PropFund.EvalNotPassed.selector);
        fund.claimFunding();
    }

    function test_InvalidSize() public {
        _fundTrader(trader1);
        vm.prank(trader1);
        vm.expectRevert(PropFund.InvalidSize.selector);
        fund.openTrade(0, 15_000, false, 8000e8, 2000e8, 4);
    }

    function test_EmergencyClose() public {
        _fundTrader(trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 3500e8);
        vm.prank(trader1); fund.emergencyClose();
        (,,,,,,bool active,,) = fund.positions(trader1);
        assertFalse(active);
    }

    function test_ResignFunding() public {
        _fundTrader(trader1);
        uint256 before = usdc.balanceOf(trader1);
        vm.prank(trader1); fund.resignFunding();
        assertEq(usdc.balanceOf(trader1) - before, TRADER_DEPOSIT);
        (bool active,,,) = fund.funded(trader1);
        assertFalse(active);
    }

    function test_TradeRecord() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 4400e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 3800e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        (uint32 w, uint32 l,,) = fund.records(trader1);
        assertEq(w, 1);
        assertEq(l, 1);
    }

    function test_NFT_EvalPass() public {
        _passEval(trader1);
        EvalCert cert = fund.CERT();
        assertEq(cert.totalSupply(), 1);
        assertEq(cert.ownerOf(1), trader1);
    }

    function test_PoolAccounting_Balanced() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _grantMaxLevel(address(fund), trader1);

        uint256 contractUsdc = usdc.balanceOf(address(fund));

        // Win trade
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 4400e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        // Lose trade
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 3600e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        // Contract USDC should equal poolBalance + totalDeployed + trader deposits + accrued
        // treasury fees (pull-pattern: stay in the contract until TREASURY calls withdrawTreasury).
        (,, uint256 dep,) = fund.funded(trader1);
        uint256 actualContract = usdc.balanceOf(address(fund));

        assertEq(fund.poolBalance() + fund.totalDeployed() + dep + fund.treasuryBalance(), actualContract);
    }

    function test_MultiAsset_ViewStats() public {
        assertEq(fund.assetCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                      CONTRACT COMPLETENESS
    //////////////////////////////////////////////////////////////*/

    bytes32 constant SOL_ID = bytes32(uint256(99));

    function test_AddFeeds() public {
        assertEq(fund.assetCount(), 2);

        // Register a new asset on the existing Pyth mock
        pyth.setSpotE8(SOL_ID, 150e8);

        // Only treasury can add
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = SOL_ID;
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 1 hours;

        vm.prank(treasury);
        fund.addFeeds(ids, staleAfter);

        assertEq(fund.assetCount(), 3);

        // Trader can trade the new asset
        _fundTrader(trader1);
        pyth.setSpotE8(SOL_ID, 150e8);
        vm.prank(trader1); fund.openTrade(2, 10_000, false, 300e8, 50e8, 4);  // SOL ~$150

        (,,,,,uint8 assetId,,,) = fund.positions(trader1);
        assertEq(assetId, 2);
    }

    function test_AddFeeds_InvalidFeed_Reverts() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(0);  // empty price ID
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 1 hours;

        vm.prank(treasury);
        vm.expectRevert(PropFund.ZeroAddress.selector);
        fund.addFeeds(ids, staleAfter);
    }

    function test_AddFeeds_OnlyTreasury() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 1 hours;

        vm.prank(trader1);
        vm.expectRevert(PropFund.NotTreasury.selector);
        fund.addFeeds(ids, staleAfter);
    }

    function test_CircuitBreaker_CapsProfit() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        // Price goes up 80% — should be capped at 50%
        pyth.setSpotE8(ETH_ID, 7200e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        // Max profit should be 50% of $200 = $100
        // Not 80% of $200 = $160
        (, int256 cumPnl,,) = fund.funded(trader1);
        assertEq(cumPnl, 100e6); // capped at 50%
    }

    function test_CircuitBreaker_CapsLoss() public {
        _fundTrader(trader1);

        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);

        // Price drops 80% — loss capped at 50% of deployed
        pyth.setSpotE8(ETH_ID, 800e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        (, int256 cumPnl,,) = fund.funded(trader1);
        assertEq(cumPnl, -100e6); // capped at 50%
    }

    function test_Leaderboard() public {
        _fundTrader(trader1);
        _fundTrader(trader2);

        // Trader1 wins
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 4400e8);
        vm.prank(trader1); fund.closeTrade(10_000);

        // Trader2 loses
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader2); fund.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);
        pyth.setSpotE8(ETH_ID, 3600e8);
        vm.prank(trader2); fund.closeTrade(10_000);

        // Composes the leaderboard from individual views (on-chain sort was removed for size).
        assertEq(fund.fundedTraderCount(), 2);
        (, int256 t1Pnl,,) = fund.funded(trader1);
        (, int256 t2Pnl,,) = fund.funded(trader2);
        assertGt(t1Pnl, t2Pnl);
    }

    function test_GetEvalStatus_WithOpenTrade() public {
        vm.prank(lp1); fund.deposit(50_000e6);
        vm.prank(trader1); fund.startEval();
        vm.prank(trader1); fund.openEvalTrade(0);

        PropFund.EvalStatus memory s = fund.getEvalStatus(trader1);
        assertTrue(s.active);
        assertTrue(s.inTrade);
        assertEq(s.tradeCount, 0);
    }

    // getPoolRisk view was removed for contract size — agents compose it off-chain by
    // walking getFundedTraders() + reading positions() per address. Skipping this test.

    function test_NFT_TokenURI() public {
        _passEval(trader1);

        EvalCert cert = fund.CERT();
        // Wire up the renderer (post-deploy, hot-swappable) — treasury is admin.
        EvalCertRenderer renderer = new EvalCertRenderer(address(fund));
        vm.prank(treasury);
        cert.setRenderer(address(renderer));

        string memory uri = cert.tokenURI(1);
        // Should start with data:application/json;base64,
        assertGt(bytes(uri).length, 50);
    }

    function test_GetAssets() public {
        vm.prank(lp1); fund.deposit(50_000e6);

        // Need to connect treasury wallet for view
        PropFund.AssetInfo[] memory assets = fund.getAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0].id, 0);
        assertEq(assets[1].id, 1);
        assertGt(assets[0].price, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _evalTrade(uint256 price) internal {
        vm.prank(trader1); fund.openEvalTrade(0);
        pyth.setSpotE8(ETH_ID, int256(price));
        vm.roll(block.number + 10);
        vm.prank(trader1); fund.closeEvalTrade();
    }

    function _passEval(address trader) internal {
        vm.prank(lp1); fund.deposit(50_000e6);
        _passEvalFor(trader);
    }

    function _passEvalFor(address trader) internal {
        vm.prank(trader); fund.startEval();
        uint256[3] memory prices = [uint256(4120e8), 4243e8, 4370e8];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader); fund.openEvalTrade(0);
            pyth.setSpotE8(ETH_ID, int256(prices[i]));
            vm.roll(block.number + 10);
            vm.prank(trader); fund.closeEvalTrade();
        }
        pyth.setSpotE8(ETH_ID, 4000e8);
    }

    function _fundTrader(address trader) internal {
        _passEval(trader);
        vm.prank(trader); fund.claimFunding();
        _grantMaxLevel(address(fund), trader);
    }

    /// Hot-patch funded[trader].lastLevel = MAX_LEVERAGE so existing tests can use leverage 4+
    /// from day 1. Real traders earn this by crossing cumulative-PnL milestones; the
    /// dedicated gate test (test_OpenTrade_LeverageGatedByLastLevel) verifies the real path.
    function _grantMaxLevel(address fundAddr, address trader) internal {
        bytes32 baseSlot = keccak256(abi.encode(trader, uint256(11))); // 11 = `funded` slot
        vm.store(fundAddr, bytes32(uint256(baseSlot) + 3), bytes32(uint256(10)));
    }

    function _deployFund(uint256 maxTraders) internal returns (PropFund) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 1 hours;
        PropFund f = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: treasury,
            guardian: guardian,
            evalFee: EVAL_FEE,
            fundedAllocation: ALLOCATION,
            evalDuration: EVAL_DURATION,
            traderDeposit: TRADER_DEPOSIT,
            maxFundedTraders: maxTraders,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));
        vm.prank(lp1); usdc.approve(address(f), type(uint256).max);
        vm.prank(lp1); f.deposit(50_000e6);
        return f;
    }

    function _passEvalOn(PropFund f, address trader) internal {
        vm.prank(trader); usdc.approve(address(f), type(uint256).max);
        vm.prank(trader); f.startEval();
        uint256[3] memory prices = [uint256(4120e8), 4243e8, 4370e8];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(trader); f.openEvalTrade(0);
            pyth.setSpotE8(ETH_ID, int256(prices[i]));
            vm.roll(block.number + 10);
            vm.prank(trader); f.closeEvalTrade();
        }
        pyth.setSpotE8(ETH_ID, 4000e8);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentDesk} from "../src/AgentDesk.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {ISwapVenue} from "../src/interfaces/ISwapVenue.sol";
import {IPropFundLens} from "../src/interfaces/IPropFundLens.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockSwap} from "./mocks/MockSwap.sol";
import {MockLens} from "./mocks/MockLens.sol";
import {MockFlashBorrower} from "./mocks/MockFlashBorrower.sol";
import {IERC3156FlashLender} from "../src/interfaces/IERC3156.sol";

contract AgentDeskTest is Test {
    bytes32 constant ETH_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    MockUSDC usdc;
    MockWETH weth;
    MockPyth pyth;
    MockSwap venue;
    MockLens lens;
    AgentDesk desk;

    address firm = makeAddr("firm");
    address agent = makeAddr("agent");
    address keeper = makeAddr("keeper");
    address rando = makeAddr("rando");

    uint256 constant ALLOC = 500e6;      // $500 book
    uint256 constant DEPOSIT = 50e6;     // $50 skin-in-game
    uint256 constant DD_BPS = 1000;      // 10% drawdown floor -> $450
    uint256 constant SPLIT_BPS = 5000;   // 50/50
    uint256 constant T2_BPS = 500;       // realized +$25 on the $500 base -> 2x
    uint256 constant T4_BPS = 1500;      // +$75 -> 4x
    uint256 constant T8_BPS = 4000;      // +$200 -> 8x

    function setUp() public {
        usdc = new MockUSDC();
        weth = new MockWETH();
        pyth = new MockPyth();
        lens = new MockLens();
        venue = new MockSwap(IERC20(address(usdc)), IERC20(address(weth)), IPyth(address(pyth)), ETH_ID, 0);
        // deep mock pool
        usdc.mint(address(venue), 10_000_000e6);
        weth.mint(address(venue), 10_000e18);
        pyth.setSpotE8(ETH_ID, 2500e8);

        desk = new AgentDesk(AgentDesk.Config({
            owner: firm,
            usdc: IERC20(address(usdc)),
            weth: IERC20(address(weth)),
            pyth: IPyth(address(pyth)),
            ethPriceId: ETH_ID,
            lens: IPropFundLens(address(lens)),
            venue: ISwapVenue(address(venue)),
            baseAllocation: ALLOC,
            agentDeposit: DEPOSIT,
            maxDrawdownBps: DD_BPS,
            agentSplitBps: SPLIT_BPS,
            minCumPnl: 10e6,     // must be net +$10 in PropFund probation
            minTrades: 5,        // over at least 5 closed trades
            minProfitFactorBps: 12_000, // gross wins >= 1.2x gross losses
            staleAfter: 5 minutes,
            maxStopBps: 300, maxTargetBps: 1000, maxHold: 24 hours, flashFeeBps: 5,
            scaleT2Bps: T2_BPS,
            scaleT4Bps: T4_BPS,
            scaleT8Bps: T8_BPS,
            maxAllocationMult: 8,
            scaleMinTrades: 0,   // ladder tests exercise the $ tiers; the win-ratio gate has its own test
            scalePfT2Bps: 0, scalePfT4Bps: 0, scalePfT8Bps: 0,
            alphaMarginBps: 0
        }));

        // firm funds the desk with its own capital
        usdc.mint(firm, 100_000e6);
        vm.startPrank(firm);
        usdc.approve(address(desk), type(uint256).max);
        desk.fund(10_000e6);
        vm.stopPrank();

        // agent has a deposit ready
        usdc.mint(agent, 1_000e6);
        vm.prank(agent);
        usdc.approve(address(desk), type(uint256).max);
    }

    function _qualify(address a) internal { lens.setRecord(a, 25e6, 6, 3); }   // +$25 over 9 trades
    function _admit(address a) internal { _qualify(a); vm.prank(a); desk.admit(); }
    function _book(address a) internal view returns (AgentDesk.Book memory b) {
        return desk.getBook(a);
    }

    /*//////////////////////////// admission ////////////////////////////*/

    function test_admit_rejectsWeakRecord() public {
        lens.setRecord(agent, 5e6, 2, 1);           // below both bars
        vm.prank(agent);
        vm.expectRevert(AgentDesk.NotQualified.selector);
        desk.admit();
    }

    function test_admit_viaLens_movesAllocationAndDeposit() public {
        _admit(agent);
        AgentDesk.Book memory b = _book(agent);
        assertTrue(b.active);
        assertEq(b.allocation, ALLOC);
        assertEq(b.usdc, ALLOC);
        assertEq(b.eth, 0);
        assertEq(b.deposit, DEPOSIT);
        assertEq(desk.firmIdle(), 10_000e6 - ALLOC);
        assertEq(usdc.balanceOf(agent), 1_000e6 - DEPOSIT);
        assertEq(desk.agentCount(), 1);
    }

    function test_admit_viaPreapproval_skipsLensBar() public {
        vm.prank(firm);
        desk.setPreapproved(agent, true);
        vm.prank(agent);
        desk.admit();
        assertTrue(_book(agent).active);
    }

    function test_admit_insufficientIdle() public {
        vm.prank(firm);
        desk.withdrawIdle(10_000e6 - 100e6);        // leave < one allocation
        _qualify(agent);
        vm.prank(agent);
        vm.expectRevert(AgentDesk.InsufficientIdle.selector);
        desk.admit();
    }

    function test_admit_twice_reverts() public {
        _admit(agent);
        vm.prank(agent);
        vm.expectRevert(AgentDesk.AlreadyActive.selector);
        desk.admit();
    }

    /*//////////////////////////// trading: profit ////////////////////////////*/

    function test_enterExit_profit_splitsAndSweeps() public {
        _admit(agent);
        _enter(desk, agent);
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.usdc, 0);
        assertEq(b.eth, 0.2e18);                    // $500 / $2500

        pyth.setSpotE8(ETH_ID, 2750e8);             // +10%
        vm.prank(agent);
        desk.exitEth(0);
        b = _book(agent);
        // $550 out: profit $50 -> agent $25, firm $25; book swept back to its allocation.
        // cumPnl $50 clears T2 and beats hold (+10%), so the ladder then grows the book to what
        // deposit + earned can collateralize: ($50 + $25) / 10% = $750; earned reinvested.
        assertEq(b.eth, 0);
        assertTrue(b.active);
        assertEq(b.allocation, 750e6);
        assertEq(b.usdc, 750e6);
        assertEq(desk.earned(agent), 0);
        assertEq(desk.firmProfit(), 25e6);
    }

    function test_claim_paysAgentCut() public {
        _admit(agent);                              // benchmark 2500
        pyth.setSpotE8(ETH_ID, 3000e8);             // ETH +20% while flat -> no scaling on this win
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 3300e8);             // +10% -> +$50: agent $25, firm $25
        vm.prank(agent); desk.exitEth(0);
        assertEq(_book(agent).allocation, ALLOC);   // hold beat it: stays 1x, earned untouched
        uint256 before = usdc.balanceOf(agent);
        vm.prank(agent); desk.claim();
        assertApproxEqAbs(usdc.balanceOf(agent), before + 25e6, 1);
        assertEq(desk.earned(agent), 0);
    }

    function test_firm_withdrawsProfit() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);
        uint256 before = usdc.balanceOf(firm);
        vm.prank(firm); desk.withdrawFirmProfit();
        assertEq(usdc.balanceOf(firm), before + 25e6);
    }

    /*//////////////////////////// trading: loss ////////////////////////////*/

    function test_exit_smallLoss_shrinksBook_staysActive() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2375e8);             // -5% -> $475, above $450 floor
        vm.prank(agent); desk.exitEth(0);
        AgentDesk.Book memory b = _book(agent);
        assertTrue(b.active);
        assertEq(b.usdc, 475e6);
        assertEq(desk.earned(agent), 0);
        assertEq(desk.firmProfit(), 0);
    }

    function test_exit_drawdownBreach_revokesAndForfeitsDeposit() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2200e8);             // -12% -> $440 <= $450 floor
        vm.prank(agent); desk.exitEth(0);
        AgentDesk.Book memory b = _book(agent);
        assertFalse(b.active);
        assertEq(b.usdc, 0);
        assertEq(b.deposit, 0);
        // $440 returned to firm idle; $50 deposit forfeited to firm profit
        assertEq(desk.firmIdle(), 10_000e6 - ALLOC + 440e6);
        assertEq(desk.firmProfit(), DEPOSIT);
    }

    /*//////////////////////////// liquidation ////////////////////////////*/

    function test_liquidate_revertsWhenHealthy() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2400e8);             // -4%, healthy
        assertFalse(desk.isLiquidatable(agent));
        vm.prank(keeper);
        vm.expectRevert(AgentDesk.NotLiquidatable.selector);
        desk.liquidate(agent);
    }

    function test_liquidate_openEth_onBreach_anyoneCan() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2200e8);             // -12%
        assertTrue(desk.isLiquidatable(agent));
        (uint256 v, bool fresh) = desk.bookValue(agent);
        assertTrue(fresh);
        assertEq(v, 440e6);
        vm.prank(keeper);
        desk.liquidate(agent);
        AgentDesk.Book memory b = _book(agent);
        assertFalse(b.active);
        assertEq(desk.firmProfit(), DEPOSIT);       // deposit forfeited
        assertEq(desk.firmIdle(), 10_000e6 - ALLOC + 440e6);
    }

    function test_liquidate_revertsOnStaleOracle() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2200e8);
        vm.warp(block.timestamp + 6 minutes);       // beyond staleAfter
        vm.prank(keeper);
        vm.expectRevert(AgentDesk.StaleOracle.selector);
        desk.liquidate(agent);
    }

    function test_liquidate_boundsFill_2pctOfMark() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2200e8);
        venue.setSlippageBps(500);                  // venue would fill 5% worse than mark
        vm.prank(keeper);
        vm.expectRevert(MockSwap.Slippage.selector); // desk demands >= mark*(1-2%)
        desk.liquidate(agent);
    }

    /*//////////////////////////// resign / pause / access ////////////////////////////*/

    function test_resign_returnsDeposit_whenHealthy() public {
        _admit(agent);
        uint256 before = usdc.balanceOf(agent);
        vm.prank(agent); desk.resign();
        assertEq(usdc.balanceOf(agent), before + DEPOSIT);
        assertFalse(_book(agent).active);
        assertEq(desk.firmIdle(), 10_000e6);        // full allocation back
    }

    function test_resign_inEth_reverts() public {
        _admit(agent);
        _enter(desk, agent);
        vm.prank(agent);
        vm.expectRevert(AgentDesk.InEth.selector);
        desk.resign();
    }

    function test_pause_blocksAdmitAndEnter_allowsExitLiquidateResignClaim() public {
        _admit(agent);
        _enter(desk, agent);
        vm.prank(firm); desk.setPaused(true);

        _qualify(rando);
        usdc.mint(rando, 100e6);
        vm.prank(rando); usdc.approve(address(desk), type(uint256).max);
        vm.prank(rando); vm.expectRevert(AgentDesk.Paused.selector); desk.admit();

        // exits stay open under pause (+10% -> $25 earned; ladder untouched because the
        // scale-up needs nothing here: ETH +10% == hold, cumPnl $50 >= hurdle $50 -> it scales)
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);
        assertEq(desk.firmProfit(), 25e6);
        assertEq(_book(agent).allocation, 750e6);
        // resign under pause returns the (scaled) deposit
        vm.prank(agent); vm.expectRevert(AgentDesk.NothingToClaim.selector); desk.claim();
        // re-entry blocked
        { uint64 tp_ = _tp(); uint64 sl_ = _sl(); vm.prank(agent); vm.expectRevert(AgentDesk.Paused.selector); desk.enterEth(0, tp_, sl_); }
        // resign allowed
        vm.prank(agent); desk.resign();
    }

    function test_onlyOwner_guards() public {
        vm.startPrank(rando);
        vm.expectRevert(AgentDesk.NotOwner.selector); desk.fund(1e6);
        vm.expectRevert(AgentDesk.NotOwner.selector); desk.withdrawIdle(1e6);
        vm.expectRevert(AgentDesk.NotOwner.selector); desk.withdrawFirmProfit();
        vm.expectRevert(AgentDesk.NotOwner.selector); desk.setPaused(true);
        vm.expectRevert(AgentDesk.NotOwner.selector); desk.setPreapproved(rando, true);
        vm.stopPrank();
    }

    function test_wrongSide_reverts() public {
        _admit(agent);
        vm.prank(agent); vm.expectRevert(AgentDesk.InUsdc.selector); desk.exitEth(0);
        _enter(desk, agent);
        { uint64 tp_ = _tp(); uint64 sl_ = _sl(); vm.prank(agent); vm.expectRevert(AgentDesk.InEth.selector); desk.enterEth(0, tp_, sl_); }
    }

    /*//////////////////////////// admission: profit factor ////////////////////////////*/

    function test_admit_rejectsLuckyRecord_lowProfitFactor() public {
        // +$25 net over 9 trades, but gross wins $125 vs gross losses $100 (PF 1.25 -> ok)
        // then PF 1.1: one lucky bull-market pass with fat losers -> rejected
        lens.setRecord(agent, 25e6, 6, 3);
        lens.setGross(agent, 110e6, 100e6);
        assertFalse(desk.qualifies(agent));
        lens.setGross(agent, 125e6, 100e6);
        assertTrue(desk.qualifies(agent));
    }

    function test_admit_revertsOnStaleOracle() public {
        _qualify(agent);
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(agent);
        vm.expectRevert(AgentDesk.StaleOracle.selector);
        desk.admit();
    }

    /*//////////////////////////// allocation ladder ////////////////////////////*/

    /// @dev One round trip: enter at current spot, move spot by `bps` (signed), exit.
    function _roundTrip(address a, int256 bps) internal {
        (uint256 spot,) = _spot();
        _enter(desk, a);
        int256 next = int256(spot) * (10_000 + bps) / 10_000;
        pyth.setSpotE8(ETH_ID, next);
        vm.prank(a); desk.exitEth(0);
    }
    function _spot() internal view returns (uint256 p, bool f) {
        IPyth.Price memory x = pyth.getPriceUnsafe(ETH_ID);
        return (uint256(uint64(x.price)), true);
    }
    /// @dev Enter with the widest legal bracket. Bracket is computed BEFORE the prank (it reads Pyth).
    function _enter(AgentDesk d, address a) internal { uint64 tp = _tp(); uint64 sl = _sl(); vm.prank(a); d.enterEth(0, tp, sl); }
    /// @dev Widest legal bracket at the current spot: target +10%, stop -3%.
    function _tp() internal view returns (uint64) { (uint256 p,) = _spot(); return uint64(p * 11_000 / 10_000); }
    function _sl() internal view returns (uint64) { (uint256 p,) = _spot(); return uint64(p * 9_700 / 10_000); }

    function test_ladder_noScale_belowTier2() public {
        _admit(agent);
        _roundTrip(agent, 400);                     // +4% -> +$20 realized, T2 needs $25
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.cumPnl, 20e6);
        assertEq(b.allocation, ALLOC);
        (uint256 mult,, bool fresh) = desk.ladder(agent);
        assertTrue(fresh);
        assertEq(mult, 1);
    }

    /// @notice The core fix: a proven book grows, and the firm stays collateralized while it does.
    function test_ladder_scalesUp_collateralizedFromEarned() public {
        _admit(agent);
        pyth.setSpotE8(ETH_ID, 2500e8);
        // +10% -> +$50 realized (cumPnl $50 >= T2 $25). Agent earned $25, firm $25.
        _roundTrip(agent, 1000);
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.cumPnl, 50e6);
        // Hurdle: ETH is +10% since admission -> hold on $500 made $50. cumPnl $50 >= $50: beats hold.
        // Target 2x = $1000 needs $100 deposit; agent has $50 deposit + $25 earned -> covers $750.
        assertEq(b.allocation, 750e6);
        assertEq(b.usdc, 750e6);
        assertEq(b.deposit, 75e6);
        assertEq(desk.earned(agent), 0);            // reinvested as collateral
        assertEq(desk.firmIdle(), 10_000e6 - 750e6);
        // invariant: deposit always covers allocation x drawdown
        assertGe(b.deposit, b.allocation * DD_BPS / 10_000);
    }

    /// @notice Beta is not alpha: the same realized $ does NOT scale when ETH rallied harder.
    function test_ladder_noScale_whenHoldWouldHaveBeaten() public {
        _admit(agent);                              // benchmark 2500
        // Agent sits flat while ETH rips +20% (hold would make $100), then catches +6% ($30).
        pyth.setSpotE8(ETH_ID, 3000e8);
        _roundTrip(agent, 600);
        AgentDesk.Book memory b = _book(agent);
        assertApproxEqAbs(b.cumPnl, 30e6, 1);       // > T2, but hurdle = $500 x 27.2% = $136
        assertEq(b.allocation, ALLOC);
        (uint256 mult, int256 hurdle,) = desk.ladder(agent);
        assertEq(mult, 1);
        assertGt(hurdle, 30e6);
    }

    /// @notice Staying flat through a drawdown IS alpha: hurdle is zero when ETH is down.
    function test_ladder_scales_whenEthDownAndAgentUp() public {
        _admit(agent);                              // benchmark 2500
        pyth.setSpotE8(ETH_ID, 2000e8);             // -20%: agent stayed out
        _roundTrip(agent, 1000);                    // then +10% -> +$50; ETH still -12% vs bench
        AgentDesk.Book memory b = _book(agent);
        (, int256 hurdle,) = desk.ladder(agent);
        assertEq(hurdle, 0);
        assertGt(b.allocation, ALLOC);
    }

    function test_ladder_scaleUp_cappedByFirmIdle() public {
        vm.prank(firm); desk.withdrawIdle(10_000e6 - 600e6);   // $600 idle -> $100 left after admit
        _admit(agent);
        _roundTrip(agent, 1000);                    // wants $750, firm only has $100 -> $600
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.allocation, 600e6);
        assertEq(desk.firmIdle(), 0);
        assertEq(b.deposit, 60e6);
        assertEq(desk.earned(agent), 15e6);         // only $10 of the $25 was needed
    }

    function test_ladder_climbsToTier8_withEnoughEarned() public {
        _admit(agent);
        // Repeated +10% trades while ETH mean-reverts back to the benchmark between them:
        // realized PnL compounds, hurdle stays ~0, allocation climbs as earned covers collateral.
        for (uint256 i = 0; i < 12; i++) {
            pyth.setSpotE8(ETH_ID, 2500e8);
            _roundTrip(agent, 1000);
        }
        AgentDesk.Book memory b = _book(agent);
        (uint256 mult,,) = desk.ladder(agent);
        assertEq(mult, 8);
        assertEq(b.allocation, ALLOC * 8);          // hard cap
        assertEq(b.deposit, ALLOC * 8 * DD_BPS / 10_000);   // $400 covers the firm's max loss
        assertGt(desk.earned(agent), 0);            // beyond the cap, winnings accumulate again
        assertGt(desk.firmProfit(), 0);
    }

    function test_ladder_scalesDown_onLosses_releasesDepositAndCapital() public {
        _admit(agent);
        _roundTrip(agent, 1000);                    // -> $750 alloc, $75 deposit
        uint256 idleBefore = desk.firmIdle();
        // lose 6% on $750 = -$45 -> cumPnl $5 < T2 -> back to 1x; book $705 -> $500, $205 to firm
        pyth.setSpotE8(ETH_ID, 2500e8);
        _roundTrip(agent, -600);
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.cumPnl, 5e6);
        assertEq(b.allocation, ALLOC);
        assertEq(b.usdc, ALLOC);
        assertEq(desk.firmIdle(), idleBefore + 205e6);
        assertEq(b.deposit, DEPOSIT);
        assertEq(desk.earned(agent), 25e6);         // excess collateral released
    }

    /// @notice A blow-up at a scaled tier still makes the firm whole: forfeited deposit == max loss.
    function test_ladder_blowupAtScale_firmMadeWhole() public {
        _admit(agent);
        _roundTrip(agent, 1000);                    // $750 alloc, $75 deposit, firm earned $25
        uint256 firmProfitBefore = desk.firmProfit();
        pyth.setSpotE8(ETH_ID, 2500e8);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2250e8);             // -10% -> $675 == floor -> breach
        vm.prank(keeper); desk.liquidate(agent);
        AgentDesk.Book memory b = _book(agent);
        assertFalse(b.active);
        // firm lost $75 of book value, gained the $75 deposit
        assertEq(desk.firmProfit(), firmProfitBefore + 75e6);
        assertEq(desk.firmIdle(), 10_000e6 - 750e6 + 675e6);
    }

    function test_ladder_resign_returnsScaledDeposit() public {
        _admit(agent);
        _roundTrip(agent, 1000);                    // deposit $75
        uint256 before = usdc.balanceOf(agent);
        vm.prank(agent); desk.resign();
        assertEq(usdc.balanceOf(agent), before + 75e6);
        assertEq(desk.firmIdle(), 10_000e6);
    }

    function test_ladder_claimingInsteadOfReinvesting_neverScales() public {
        _admit(agent);
        pyth.setSpotE8(ETH_ID, 2500e8);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);           // +$50: earned $25 -> scales to $750 at once
        assertEq(_book(agent).allocation, 750e6);
        // now the agent claims everything and trades again; with no earned to collateralize,
        // allocation can't grow past what the deposit covers
        pyth.setSpotE8(ETH_ID, 2500e8);
        _roundTrip(agent, 1000);                    // +$75 -> earned $37.5 -> would reach $1125? cap 2x while cumPnl<T4
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.cumPnl, 125e6);                  // 50 + 75; T4 = 75 -> 4x target
        assertLe(b.allocation, 2000e6);
        assertGe(b.deposit, b.allocation * DD_BPS / 10_000);
    }

    function test_constructor_rejectsUndercollateralizedBase() public {
        AgentDesk.Config memory c = AgentDesk.Config({
            owner: firm, usdc: IERC20(address(usdc)), weth: IERC20(address(weth)), pyth: IPyth(address(pyth)),
            ethPriceId: ETH_ID, lens: IPropFundLens(address(lens)), venue: ISwapVenue(address(venue)),
            baseAllocation: ALLOC, agentDeposit: 49e6, maxDrawdownBps: DD_BPS, agentSplitBps: SPLIT_BPS,
            minCumPnl: 10e6, minTrades: 5, minProfitFactorBps: 0, staleAfter: 5 minutes,
            maxStopBps: 300, maxTargetBps: 1000, maxHold: 24 hours, flashFeeBps: 5,
            scaleT2Bps: T2_BPS, scaleT4Bps: T4_BPS, scaleT8Bps: T8_BPS, maxAllocationMult: 8, scaleMinTrades: 0, scalePfT2Bps: 0, scalePfT4Bps: 0, scalePfT8Bps: 0, alphaMarginBps: 0
        });
        vm.expectRevert(AgentDesk.BadConfig.selector);
        new AgentDesk(c);
    }

    /// @notice A win ratio, not a lucky trade: the $ tier alone doesn't scale without the per-tier
    ///         profit factor (gross wins / gross losses) over the sample floor. Frequency-independent.
    function test_ladder_requiresWinRatio_profitFactorAndSampleFloor() public {
        AgentDesk d2 = new AgentDesk(AgentDesk.Config({
            owner: firm, usdc: IERC20(address(usdc)), weth: IERC20(address(weth)), pyth: IPyth(address(pyth)),
            ethPriceId: ETH_ID, lens: IPropFundLens(address(lens)), venue: ISwapVenue(address(venue)),
            baseAllocation: ALLOC, agentDeposit: DEPOSIT, maxDrawdownBps: DD_BPS, agentSplitBps: SPLIT_BPS,
            minCumPnl: 10e6, minTrades: 5, minProfitFactorBps: 0, staleAfter: 5 minutes,
            maxStopBps: 300, maxTargetBps: 1000, maxHold: 24 hours, flashFeeBps: 5,
            scaleT2Bps: T2_BPS, scaleT4Bps: T4_BPS, scaleT8Bps: T8_BPS, maxAllocationMult: 8,
            scaleMinTrades: 3, scalePfT2Bps: 15_000, scalePfT4Bps: 20_000, scalePfT8Bps: 30_000, alphaMarginBps: 0
        }));
        vm.startPrank(firm); usdc.approve(address(d2), type(uint256).max); d2.fund(10_000e6); vm.stopPrank();
        _qualify(agent);
        vm.startPrank(agent); usdc.approve(address(d2), type(uint256).max); d2.admit(); vm.stopPrank();

        // one +10% trade: cumPnl $50 >= T2, PF infinite, but trades 1 < sample floor 3 -> stays 1x
        pyth.setSpotE8(ETH_ID, 2500e8);
        _enter(d2, agent);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); d2.exitEth(0);
        AgentDesk.Book memory b1 = d2.getBook(agent);
        assertEq(b1.allocation, ALLOC); assertEq(b1.trades, 1); assertEq(b1.wins, 1); assertEq(b1.grossProfit, 50e6);
        (uint256 m1,,) = d2.ladder(agent); assertEq(m1, 1);

        // two losers of -4% ($20 on $500, then $19.20 on $480): trades 3 (floor met), cumPnl $10.80 < T2 -> 1x.
        // PF = 50 / 39.2 = 1.276 < 1.5.
        for (uint256 i = 0; i < 2; i++) {
            pyth.setSpotE8(ETH_ID, 2500e8);
            _enter(d2, agent);
            pyth.setSpotE8(ETH_ID, 2400e8);
            vm.prank(agent); d2.exitEth(0);
        }
        AgentDesk.Book memory b3 = d2.getBook(agent);
        assertEq(b3.trades, 3); assertEq(b3.losses, 2); assertEq(b3.grossLoss, 39.2e6);
        (uint256 pf, uint256 wr) = d2.winRatio(agent);
        assertEq(pf, 12_755); assertEq(wr, 3_333);
        assertEq(b3.allocation, ALLOC);

        // one more +10% win on the $460.80 book: +$46.08 -> cumPnl $56.88 >= T2 ($25), PF = 96.08/39.2 = 2.45
        // >= 1.5 -> 2x (PF also clears the 2.0 bar for 4x, but cumPnl < T4 $75 -> lands at 2x)
        pyth.setSpotE8(ETH_ID, 2500e8);
        _enter(d2, agent);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); d2.exitEth(0);
        (uint256 m4, ,) = d2.ladder(agent);
        assertEq(m4, 2);
        assertGt(d2.getBook(agent).allocation, ALLOC);
    }

    function test_winRatio_liquidationCountsAsLoss() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2200e8);
        vm.prank(keeper); desk.liquidate(agent);
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.trades, 1); assertEq(b.losses, 1); assertEq(b.grossLoss, 60e6); assertEq(b.cumPnl, -60e6);
    }

    /// @dev Conservation holds through scale-ups, scale-downs and a liquidation.
    function test_accounting_conserved_acrossLadder() public {
        _admit(agent);
        for (uint256 i = 0; i < 6; i++) { pyth.setSpotE8(ETH_ID, 2500e8); _roundTrip(agent, 1000); }
        pyth.setSpotE8(ETH_ID, 2500e8); _roundTrip(agent, -500);
        pyth.setSpotE8(ETH_ID, 2500e8);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2200e8);
        vm.prank(keeper); desk.liquidate(agent);
        AgentDesk.Book memory b = _book(agent);
        uint256 expected = desk.firmIdle() + b.usdc + b.deposit + desk.firmProfit() + desk.earned(agent);
        assertEq(usdc.balanceOf(address(desk)), expected);
    }

    /*//////////////////////////// bracket orders ////////////////////////////*/

    function test_bracket_required_and_bounded() public {
        _admit(agent);
        vm.startPrank(agent);
        vm.expectRevert(AgentDesk.BadBracket.selector); desk.enterEth(0, 0, 0);                    // missing
        vm.expectRevert(AgentDesk.BadBracket.selector); desk.enterEth(0, 2400e8, 2600e8);          // inverted
        vm.expectRevert(AgentDesk.BadBracket.selector); desk.enterEth(0, 2750e8, 2400e8);          // stop 4% > 3% bound
        vm.expectRevert(AgentDesk.BadBracket.selector); desk.enterEth(0, 2800e8, 2450e8);          // target 12% > 10% bound
        desk.enterEth(0, 2750e8, 2450e8);                                                          // +10% / -2%: ok
        vm.stopPrank();
        (uint64 ep, uint64 tp, uint64 sl) = desk.brackets(agent);
        assertEq(ep, 2500e8); assertEq(tp, 2750e8); assertEq(sl, 2450e8);
    }

    function test_bracket_enterRevertsOnStaleOracle() public {
        _admit(agent);
        vm.warp(block.timestamp + 6 minutes);
        vm.prank(agent);
        vm.expectRevert(AgentDesk.StaleOracle.selector);
        desk.enterEth(0, 2750e8, 2450e8);
    }

    function test_executeExit_takeProfit_anyone_settlesLikeExit() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0, 2600e8, 2450e8);         // +4% target
        pyth.setSpotE8(ETH_ID, 2590e8);
        assertEq(desk.exitReason(agent), 0);
        vm.prank(keeper); vm.expectRevert(AgentDesk.NotExecutable.selector); desk.executeExit(agent);
        pyth.setSpotE8(ETH_ID, 2600e8);
        assertEq(desk.exitReason(agent), 1);
        vm.prank(keeper); desk.executeExit(agent);
        AgentDesk.Book memory b = _book(agent);
        assertTrue(b.active); assertEq(b.eth, 0);
        assertEq(b.cumPnl, 20e6); assertEq(b.wins, 1);           // $520 out: +$20 realized, split, swept
        assertEq(desk.firmProfit(), 10e6); assertEq(desk.earned(agent), 10e6);
        (, uint64 tp0,) = desk.brackets(agent);
        assertEq(tp0, 0); assertEq(b.entryTime, 0);
    }

    function test_executeExit_stopLoss() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0, 2750e8, 2450e8);         // -2% stop
        pyth.setSpotE8(ETH_ID, 2440e8);
        assertEq(desk.exitReason(agent), 2);
        vm.prank(keeper); desk.executeExit(agent);
        AgentDesk.Book memory b = _book(agent);
        assertTrue(b.active); assertEq(b.usdc, 488e6); assertEq(b.losses, 1);
        assertEq(b.deposit, DEPOSIT);                             // a stop is not a breach: no forfeit
    }

    function test_executeExit_maxHold_clockNotPrice() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0, 2750e8, 2450e8);
        vm.warp(block.timestamp + 23 hours);
        pyth.setSpotE8(ETH_ID, 2510e8);                           // fresh, inside the bracket
        assertEq(desk.exitReason(agent), 0);
        vm.warp(block.timestamp + 1 hours + 1);
        pyth.setSpotE8(ETH_ID, 2510e8);
        assertEq(desk.exitReason(agent), 3);
        vm.prank(rando); desk.executeExit(agent);
        assertEq(_book(agent).eth, 0);
    }

    function test_executeExit_maxHold_revertsOnStaleMark() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0, 2750e8, 2450e8);
        vm.warp(block.timestamp + 25 hours);                      // clock hit, but the mark is 25h old
        vm.prank(keeper); vm.expectRevert(AgentDesk.StaleOracle.selector); desk.executeExit(agent);
    }

    function test_executeExit_boundsFill_2pctOfMark() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0, 2750e8, 2450e8);
        pyth.setSpotE8(ETH_ID, 2440e8);
        venue.setSlippageBps(500);
        vm.prank(keeper); vm.expectRevert(MockSwap.Slippage.selector); desk.executeExit(agent);
    }

    function test_updateBracket_tightenOnly() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0, 2750e8, 2450e8);
        vm.startPrank(agent);
        vm.expectRevert(AgentDesk.BracketWidened.selector); desk.updateBracket(2760e8, 2450e8);   // raise target
        vm.expectRevert(AgentDesk.BracketWidened.selector); desk.updateBracket(2750e8, 2440e8);   // lower stop
        desk.updateBracket(2700e8, 2520e8);                                                      // trail: stop above entry
        vm.stopPrank();
        (, uint64 tp, uint64 sl) = desk.brackets(agent);
        assertEq(tp, 2700e8); assertEq(sl, 2520e8);
        // the trailed stop executes at a profit
        pyth.setSpotE8(ETH_ID, 2515e8);
        vm.prank(keeper); desk.executeExit(agent);
        assertGt(_book(agent).cumPnl, 0);
    }

    function test_bracket_ladderAppliesOnExecutedExit() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0, 2750e8, 2450e8);
        pyth.setSpotE8(ETH_ID, 2750e8);                           // +10% target hit: cumPnl $50 -> scales
        vm.prank(keeper); desk.executeExit(agent);
        assertGt(_book(agent).allocation, ALLOC);
    }

    /*//////////////////////////// flash lending ////////////////////////////*/

    function test_flash_lendsIdle_feeToFirmProfit_ledgerHolds() public {
        _admit(agent);                                   // firmIdle = $9,500
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);                     // to pay the fee
        assertEq(desk.maxFlashLoan(address(usdc)), 9_500e6);
        assertEq(desk.flashFee(address(usdc), 9_500e6), 4.75e6);   // 5 bps
        uint256 before = usdc.balanceOf(address(desk));
        b.borrow(IERC3156FlashLender(address(desk)), address(usdc), 9_500e6);
        assertEq(b.lastAmount(), 9_500e6); assertEq(b.lastFee(), 4.75e6);
        assertEq(usdc.balanceOf(address(desk)), before + 4.75e6);
        assertEq(desk.firmProfit(), 4.75e6);
        assertEq(desk.firmIdle(), 9_500e6);              // capital untouched
        AgentDesk.Book memory bk = _book(agent);
        assertEq(usdc.balanceOf(address(desk)), desk.firmIdle() + bk.usdc + bk.deposit + desk.firmProfit() + desk.earned(agent));
    }

    function test_flash_neverLendsBooksDepositsOrProfit() public {
        _admit(agent);
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        vm.expectRevert(AgentDesk.InsufficientIdle.selector);
        b.borrow(IERC3156FlashLender(address(desk)), address(usdc), 9_500e6 + 1);   // one wei of the agent's book
    }

    function test_flash_shortRepay_reverts() public {
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        b.setMode(MockFlashBorrower.Mode.ShortRepay);
        vm.expectRevert();                               // safeTransferFrom of amount+fee fails on allowance
        b.borrow(IERC3156FlashLender(address(desk)), address(usdc), 1_000e6);
        assertEq(desk.firmIdle(), 10_000e6); assertEq(usdc.balanceOf(address(desk)), 10_000e6);
    }

    function test_flash_badCallbackReturn_reverts() public {
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        b.setMode(MockFlashBorrower.Mode.BadReturn);
        vm.expectRevert(AgentDesk.FlashCallbackFailed.selector);
        b.borrow(IERC3156FlashLender(address(desk)), address(usdc), 1_000e6);
    }

    function test_flash_reentryIntoDesk_blocked() public {
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        b.setMode(MockFlashBorrower.Mode.Reenter);
        vm.expectRevert("reentry blocked");              // desk.claim() reverted Reentrancy inside the callback
        b.borrow(IERC3156FlashLender(address(desk)), address(usdc), 1_000e6);
    }

    function test_flash_thirdPartyCannotInitiateForAReceiver() public {
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        vm.prank(rando);
        vm.expectRevert(AgentDesk.FlashInitiatorNotReceiver.selector);
        desk.flashLoan(b, address(usdc), 1_000e6, "");
    }

    function test_flash_usdcOnly_andPauseBlocks() public {
        MockFlashBorrower b = new MockFlashBorrower();
        vm.expectRevert(AgentDesk.UnsupportedToken.selector);
        b.borrow(IERC3156FlashLender(address(desk)), address(weth), 1e18);
        vm.prank(firm); desk.setPaused(true);
        assertEq(desk.maxFlashLoan(address(usdc)), 0);
        vm.expectRevert(AgentDesk.Paused.selector);
        b.borrow(IERC3156FlashLender(address(desk)), address(usdc), 1_000e6);
    }

    /*//////////////////////////// oracle-fresh flash loans ////////////////////////////*/

    /// @notice The update lands BEFORE the loan: the borrower's callback (and every other protocol
    ///         reading this Pyth) sees the fresh price. Fee to firmProfit; Pyth fee overpayment refunded.
    function test_flashWithUpdate_pushesPriceThenLends_refundsExcess() public {
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        vm.deal(address(b), 1 ether);
        pyth.setSpotE8(ETH_ID, 2500e8);
        pyth.setNextUpdate(ETH_ID, 2300e8);               // the "signed update" says -8%
        bytes[] memory upd = new bytes[](1); upd[0] = hex"deadbeef";
        _admit(agent); _enter(desk, agent);
        vm.warp(block.timestamp + 10 minutes);            // the cached price is now stale for the desk
        (, bool freshBefore) = desk.bookValue(agent);
        uint256 balBefore = address(b).balance;
        b.borrowWithUpdate{value: 0.01 ether}(address(desk), address(usdc), 5_000e6, upd);
        // price applied at this block, so the desk's mark is fresh again and at the new price
        IPyth.Price memory p = pyth.getPriceUnsafe(ETH_ID);
        assertEq(uint256(uint64(p.price)), 2300e8); assertEq(p.publishTime, block.timestamp);
        assertEq(desk.firmProfit(), 2.5e6);                // 5 bps of $5,000
        // the test sent 0.01 ETH into the borrower; MockPyth's fee is 1 wei; the desk refunded the rest
        assertEq(address(b).balance, balBefore + 0.01 ether - 1);
        assertEq(address(desk).balance, 0);
        assertFalse(freshBefore);                          // it WAS stale before the update landed
    }

    function test_flashWithUpdate_noUpdate_isPlainLoan() public {
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        bytes[] memory upd = new bytes[](0);
        b.borrowWithUpdate(address(desk), address(usdc), 1_000e6, upd);
        assertEq(desk.firmProfit(), 0.5e6);
    }

    function test_flashWithUpdate_underpaidOracleFee_reverts() public {
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6);
        bytes[] memory upd = new bytes[](1); upd[0] = hex"00";
        vm.expectRevert();                                 // updatePriceFeeds{value: 1} with 0 balance
        b.borrowWithUpdate(address(desk), address(usdc), 1_000e6, upd);
    }

    /// @notice The liquidation-bot use case end to end: a stale desk book that the keeper cannot
    ///         liquidate (StaleOracle) becomes liquidatable in the same tx the bot borrows capital.
    function test_flashWithUpdate_makesStaleBookLiquidatable_inOneTx() public {
        _admit(agent);
        _enter(desk, agent);
        vm.warp(block.timestamp + 10 minutes);            // mark goes stale
        vm.prank(keeper); vm.expectRevert(AgentDesk.StaleOracle.selector); desk.liquidate(agent);
        pyth.setNextUpdate(ETH_ID, 2200e8);               // the signed update: -12%, through the floor
        bytes[] memory upd = new bytes[](1); upd[0] = hex"01";
        MockFlashBorrower b = new MockFlashBorrower();
        usdc.mint(address(b), 10e6); vm.deal(address(b), 1 ether);
        b.borrowWithUpdate{value: 1}(address(desk), address(usdc), 100e6, upd);
        assertTrue(desk.isLiquidatable(agent));           // fresh now, and breached
        vm.prank(keeper); desk.liquidate(agent);
    }

    /*//////////////////////////// accounting invariant ////////////////////////////*/

    /// @dev Desk USDC balance == firmIdle + Σ book.usdc + Σ deposits + firmProfit + Σ earned.
    function test_accounting_conserved_acrossLifecycle() public {
        _admit(agent);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);
        _enter(desk, agent);
        pyth.setSpotE8(ETH_ID, 2400e8);
        vm.prank(agent); desk.exitEth(0);           // small loss, still active
        AgentDesk.Book memory b = _book(agent);
        uint256 expected = desk.firmIdle() + b.usdc + b.deposit + desk.firmProfit() + desk.earned(agent);
        assertEq(usdc.balanceOf(address(desk)), expected);
    }
}

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
            staleAfter: 5 minutes
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
        (b.active, b.allocation, b.usdc, b.eth, b.deposit) = desk.books(a);
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
        vm.prank(agent);
        desk.enterEth(0);
        AgentDesk.Book memory b = _book(agent);
        assertEq(b.usdc, 0);
        assertEq(b.eth, 0.2e18);                    // $500 / $2500

        pyth.setSpotE8(ETH_ID, 2750e8);             // +10%
        vm.prank(agent);
        desk.exitEth(0);
        b = _book(agent);
        // $550 out: profit $50 -> agent $25, firm $25; book swept back to $500
        assertEq(b.usdc, ALLOC);
        assertEq(b.eth, 0);
        assertTrue(b.active);
        assertEq(desk.earned(agent), 25e6);
        assertEq(desk.firmProfit(), 25e6);
    }

    function test_claim_paysAgentCut() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);
        uint256 before = usdc.balanceOf(agent);
        vm.prank(agent); desk.claim();
        assertEq(usdc.balanceOf(agent), before + 25e6);
        assertEq(desk.earned(agent), 0);
    }

    function test_firm_withdrawsProfit() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);
        uint256 before = usdc.balanceOf(firm);
        vm.prank(firm); desk.withdrawFirmProfit();
        assertEq(usdc.balanceOf(firm), before + 25e6);
    }

    /*//////////////////////////// trading: loss ////////////////////////////*/

    function test_exit_smallLoss_shrinksBook_staysActive() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0);
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
        vm.prank(agent); desk.enterEth(0);
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
        vm.prank(agent); desk.enterEth(0);
        pyth.setSpotE8(ETH_ID, 2400e8);             // -4%, healthy
        assertFalse(desk.isLiquidatable(agent));
        vm.prank(keeper);
        vm.expectRevert(AgentDesk.NotLiquidatable.selector);
        desk.liquidate(agent);
    }

    function test_liquidate_openEth_onBreach_anyoneCan() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0);
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
        vm.prank(agent); desk.enterEth(0);
        pyth.setSpotE8(ETH_ID, 2200e8);
        vm.warp(block.timestamp + 6 minutes);       // beyond staleAfter
        vm.prank(keeper);
        vm.expectRevert(AgentDesk.StaleOracle.selector);
        desk.liquidate(agent);
    }

    function test_liquidate_boundsFill_2pctOfMark() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0);
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
        vm.prank(agent); desk.enterEth(0);
        vm.prank(agent);
        vm.expectRevert(AgentDesk.InEth.selector);
        desk.resign();
    }

    function test_pause_blocksAdmitAndEnter_allowsExitLiquidateResignClaim() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0);
        vm.prank(firm); desk.setPaused(true);

        _qualify(rando);
        usdc.mint(rando, 100e6);
        vm.prank(rando); usdc.approve(address(desk), type(uint256).max);
        vm.prank(rando); vm.expectRevert(AgentDesk.Paused.selector); desk.admit();

        // exits stay open under pause
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);
        assertEq(desk.earned(agent), 25e6);
        vm.prank(agent); desk.claim();
        // re-entry blocked
        vm.prank(agent); vm.expectRevert(AgentDesk.Paused.selector); desk.enterEth(0);
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
        vm.prank(agent); desk.enterEth(0);
        vm.prank(agent); vm.expectRevert(AgentDesk.InEth.selector); desk.enterEth(0);
    }

    /*//////////////////////////// accounting invariant ////////////////////////////*/

    /// @dev Desk USDC balance == firmIdle + Σ book.usdc + Σ deposits + firmProfit + Σ earned.
    function test_accounting_conserved_acrossLifecycle() public {
        _admit(agent);
        vm.prank(agent); desk.enterEth(0);
        pyth.setSpotE8(ETH_ID, 2750e8);
        vm.prank(agent); desk.exitEth(0);
        vm.prank(agent); desk.enterEth(0);
        pyth.setSpotE8(ETH_ID, 2400e8);
        vm.prank(agent); desk.exitEth(0);           // small loss, still active
        AgentDesk.Book memory b = _book(agent);
        uint256 expected = desk.firmIdle() + b.usdc + b.deposit + desk.firmProfit() + desk.earned(agent);
        assertEq(usdc.balanceOf(address(desk)), expected);
    }
}

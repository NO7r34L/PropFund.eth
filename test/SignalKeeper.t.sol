// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignalKeeper, IAgentDeskMin} from "../src/SignalKeeper.sol";
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

/// @notice The fully-on-chain systematic agent: verifies the recursive indicator math behaves,
///         the warm-up gate holds, the trend filter blocks longs below TWAP, and a real long
///         setup auto-opens a bracketed position on the keeper's own AgentDesk book — then the
///         desk's on-chain bracket closes it. No LLM anywhere in the loop.
contract SignalKeeperTest is Test {
    bytes32 constant ETH_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    MockUSDC usdc; MockWETH weth; MockPyth pyth; MockSwap venue; MockLens lens;
    AgentDesk desk; SignalKeeper keeper;

    address firm = makeAddr("firm");
    address owner = makeAddr("keeperOwner");
    address rando = makeAddr("rando");     // pokes; has no privilege

    function setUp() public {
        usdc = new MockUSDC(); weth = new MockWETH(); pyth = new MockPyth(); lens = new MockLens();
        venue = new MockSwap(IERC20(address(usdc)), IERC20(address(weth)), IPyth(address(pyth)), ETH_ID, 0);
        usdc.mint(address(venue), 10_000_000e6); weth.mint(address(venue), 10_000e18);
        pyth.setSpotE8(ETH_ID, 2500e8);

        desk = new AgentDesk(AgentDesk.Config({
            owner: firm, usdc: IERC20(address(usdc)), weth: IERC20(address(weth)), pyth: IPyth(address(pyth)),
            ethPriceId: ETH_ID, lens: IPropFundLens(address(lens)), venue: ISwapVenue(address(venue)),
            baseAllocation: 500e6, agentDeposit: 50e6, maxDrawdownBps: 1000, agentSplitBps: 4000,
            minCumPnl: 0, minTrades: 0, minProfitFactorBps: 0, staleAfter: 1 hours,
            maxStopBps: 300, maxTargetBps: 1000, maxHold: 24 hours, flashFeeBps: 5,
            scaleT2Bps: 2000, scaleT4Bps: 5000, scaleT8Bps: 12_000, maxAllocationMult: 8,
            scaleMinTrades: 20, scalePfT2Bps: 13_000, scalePfT4Bps: 15_000, scalePfT8Bps: 18_000, alphaMarginBps: 0
        }));
        usdc.mint(firm, 100_000e6);
        vm.startPrank(firm); usdc.approve(address(desk), type(uint256).max); desk.fund(10_000e6);
        desk.setPreapproved(address(0), false); vm.stopPrank();

        keeper = new SignalKeeper(SignalKeeper.Config({
            owner: owner, pyth: IPyth(address(pyth)), ethPriceId: ETH_ID, desk: IAgentDeskMin(address(desk)),
            usdc: IERC20(address(usdc)), sampleInterval: 60, staleAfter: 1 hours, orbWindow: 3600,
            tpBps: 600, slBps: 150, rsiLongMaxE2: 6000, minConfirmations: 2
        }));
        // firm preapproves the keeper as a systematic agent; owner funds its deposit + admits it
        vm.prank(firm); desk.setPreapproved(address(keeper), true);
        usdc.mint(owner, 1_000e6);
        vm.startPrank(owner); usdc.approve(address(keeper), type(uint256).max); keeper.fund(100e6); keeper.admitToDesk(); vm.stopPrank();
    }

    bytes[] EMPTY;
    function _poke(int256 priceE8) internal { pyth.setSpotE8(ETH_ID, priceE8); vm.warp(block.timestamp + 61); vm.prank(rando); keeper.poke(EMPTY); }
    function _book() internal view returns (AgentDesk.Book memory) { return desk.getBook(address(keeper)); }

    /*//////////////////////////// indicator math ////////////////////////////*/

    function test_indicators_riseTogether_onUptrend() public {
        for (uint256 i = 0; i < 30; i++) _poke(int256((2500 + i * 5) * 1e8));  // steady climb
        assertGt(keeper.emaFast(), keeper.emaSlow());      // fast EMA leads on the way up
        assertGt(keeper.macdHist(), 0);                    // MACD histogram positive
        assertGt(keeper.rsiE2(), 6000);                    // RSI high (mostly gains)
        assertGt(int256(uint256(keeper.prevPrice())), keeper.twapEma());  // price above TWAP
        assertEq(keeper.samples(), 30);
    }

    function test_indicators_crash_rsiLow_macdNegative() public {
        for (uint256 i = 0; i < 30; i++) _poke(int256((2500 - i * 5) * 1e8));  // steady fall
        assertLt(keeper.emaFast(), keeper.emaSlow());
        assertLt(keeper.macdHist(), 0);
        assertLt(keeper.rsiE2(), 4000);
        (bool go,) = keeper.longSetup();
        assertFalse(go);                                   // never long into a downtrend
    }

    function test_rsi_boundsAndFlat() public {
        for (uint256 i = 0; i < 20; i++) _poke(2500e8);    // flat -> RSI 50
        int256 r = keeper.rsiE2();
        assertGe(r, 0); assertLe(r, 10000);
        assertApproxEqAbs(r, 5000, 1);
    }

    /*//////////////////////////// warm-up + trend filter ////////////////////////////*/

    function test_warmup_noSetupBeforeThreshold() public {
        for (uint256 i = 0; i < 20; i++) _poke(int256((2500 + i * 10) * 1e8));  // strong uptrend
        assertLt(keeper.samples(), 26);
        (bool go,) = keeper.longSetup();
        assertFalse(go);                                   // warm-up gate: no entry yet
        assertEq(_book().eth, 0);
    }

    function test_belowTwap_neverEnters() public {
        for (uint256 i = 0; i < 40; i++) _poke(int256((3000 - i * 20) * 1e8));  // long downtrend, past warmup
        assertEq(_book().eth, 0);                          // trend filter held the whole way
        assertTrue(_book().active);
    }

    /*//////////////////////////// the whole point: auto-entry ////////////////////////////*/

    function test_autoEnter_onLongSetup_thenBracketExit() public {
        // warm up + climb so that after WARMUP the setup fires (aboveTwap + macdBull >= 2 confirmations)
        for (uint256 i = 0; i < 40; i++) _poke(int256((2500 + i * 8) * 1e8));
        AgentDesk.Book memory b = _book();
        assertGt(b.eth, 0);                                // the keeper opened a real ETH position
        assertEq(b.usdc, 0);
        (uint64 ep, uint64 tp, uint64 sl) = desk.brackets(address(keeper));
        assertGt(tp, ep); assertLt(sl, ep);                // a real bracket was set on entry
        assertLe(uint256(tp - ep) * 10_000 / ep, 600);     // within TP_BPS
        assertEq(desk.exitReason(address(keeper)), 0);     // not yet exitable

        // price runs to the take-profit -> anyone executes the on-chain bracket, no LLM
        uint256 markTp = uint256(tp) + 1e8;
        pyth.setSpotE8(ETH_ID, int256(markTp));
        assertEq(desk.exitReason(address(keeper)), 1);     // take-profit
        vm.prank(rando); desk.executeExit(address(keeper));
        AgentDesk.Book memory b2 = _book();
        assertEq(b2.eth, 0);                               // closed
        assertGt(b2.cumPnl, 0);                            // realized a win, fully on-chain
        assertEq(b2.trades, 1);
    }

    function test_noReentry_whileInEth() public {
        for (uint256 i = 0; i < 40; i++) _poke(int256((2500 + i * 8) * 1e8));
        assertGt(_book().eth, 0);
        uint256 ethBefore = _book().eth;
        _poke(int256((2500 + 41 * 8) * 1e8));              // poke again while in ETH
        assertEq(_book().eth, ethBefore);                  // did not re-enter / double up
    }

    /*//////////////////////////// access + safety ////////////////////////////*/

    function test_poke_isPermissionless() public {
        pyth.setSpotE8(ETH_ID, 2500e8); vm.warp(block.timestamp + 61);
        vm.prank(rando); keeper.poke(EMPTY);               // no revert; rando has no privilege
        assertEq(keeper.samples(), 1);
    }

    function test_poke_staleOracleReverts() public {
        vm.warp(block.timestamp + 2 hours);                // last set price now stale
        vm.prank(rando); vm.expectRevert(SignalKeeper.StaleOracle.selector); keeper.poke(EMPTY);
    }

    function test_onlyOwner_guards() public {
        vm.startPrank(rando);
        vm.expectRevert(SignalKeeper.NotOwner.selector); keeper.fund(1e6);
        vm.expectRevert(SignalKeeper.NotOwner.selector); keeper.sweep(1e6);
        vm.expectRevert(SignalKeeper.NotOwner.selector); keeper.admitToDesk();
        vm.stopPrank();
    }

    function test_admitTwice_reverts() public {
        vm.prank(owner); vm.expectRevert(SignalKeeper.AlreadyAdmitted.selector); keeper.admitToDesk();
    }

    function test_sampleInterval_throttles() public {
        pyth.setSpotE8(ETH_ID, 2500e8); vm.warp(block.timestamp + 61);
        vm.prank(rando); keeper.poke(EMPTY);
        uint256 n = keeper.samples();
        vm.prank(rando); keeper.poke(EMPTY);               // same block-ish, < interval
        assertEq(keeper.samples(), n);                     // no extra sample
    }
}

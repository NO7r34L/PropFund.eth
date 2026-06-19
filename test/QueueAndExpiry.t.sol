// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PropFund} from "../src/PropFund.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice Coverage for the funding queue, fair partition, and position max-duration paths.
contract QueueAndExpiryTest is Test {
    PropFund fund;
    MockUSDC usdc;
    MockPyth pyth;
    bytes32 constant ETH_ID = bytes32(uint256(1));

    address lp = address(0x1111);
    address treasury = address(0xDE5);
    address trader1 = address(0xA11CE);
    address trader2 = address(0xB0B);
    address trader3 = address(0xCAFE);
    address keeper = address(0xCAFF);

    uint256 constant EVAL_FEE = 10e6;
    uint256 constant ALLOCATION = 1_000e6;
    uint256 constant EVAL_DURATION = 50_400;
    uint256 constant TRADER_DEPOSIT = 100e6;

    function setUp() public {
        usdc = new MockUSDC();
        pyth = new MockPyth();
        pyth.setSpotE8(ETH_ID, 4000e8);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 1 hours;

        // maxFundedTraders = 1 → easy to fill capacity for queue tests.
        fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: treasury,
            evalFee: EVAL_FEE,
            fundedAllocation: ALLOCATION,
            evalDuration: EVAL_DURATION,
            traderDeposit: TRADER_DEPOSIT,
            maxFundedTraders: 1,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));

        usdc.mint(lp, 1_000_000e6);
        vm.prank(lp); usdc.approve(address(fund), type(uint256).max);
        vm.prank(lp); fund.deposit(50_000e6);

        for (uint256 i = 0; i < 3; i++) {
            address t = [trader1, trader2, trader3][i];
            usdc.mint(t, 10_000e6);
            vm.prank(t); usdc.approve(address(fund), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       FUNDING QUEUE
    //////////////////////////////////////////////////////////////*/

    function test_Queue_FillsAfterCapacityHit() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        assertEq(fund.fundedTraderCount(), 1);
        assertEq(fund.queueLength(), 0);

        _passEval(trader2);
        uint256 t2BalBefore = usdc.balanceOf(trader2);
        vm.prank(trader2); fund.claimFunding();
        // Queued — not funded yet
        assertEq(fund.fundedTraderCount(), 1);
        assertEq(fund.queueLength(), 1);
        assertEq(fund.queuePosition(trader2), 1);
        assertEq(fund.queuedDeposits(), TRADER_DEPOSIT);
        // Deposit was escrowed
        assertEq(t2BalBefore - usdc.balanceOf(trader2), TRADER_DEPOSIT);

        _passEval(trader3);
        vm.prank(trader3); fund.claimFunding();
        assertEq(fund.queueLength(), 2);
        assertEq(fund.queuePosition(trader3), 2);
        assertEq(fund.queuedDeposits(), TRADER_DEPOSIT * 2);
    }

    function test_Queue_DoubleClaimReverts() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();

        _passEval(trader2);
        vm.prank(trader2); fund.claimFunding();
        // Already queued — second call must revert
        vm.prank(trader2);
        vm.expectRevert(PropFund.AlreadyQueued.selector);
        fund.claimFunding();
    }

    function test_Queue_ProcessDrainsAfterResign() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _passEval(trader2);
        vm.prank(trader2); fund.claimFunding();
        _passEval(trader3);
        vm.prank(trader3); fund.claimFunding();
        assertEq(fund.queueLength(), 2);

        // trader1 resigns → capacity opens for one queued trader.
        vm.prank(trader1); fund.resignFunding();
        assertEq(fund.fundedTraderCount(), 0);

        // Anyone (a keeper) drains the queue.
        vm.prank(keeper); fund.processFundingQueue(10);

        assertEq(fund.fundedTraderCount(), 1);
        assertEq(fund.queueLength(), 1);
        // FIFO: trader2 advanced, trader3 still queued at position 1.
        (bool t2Active,,,) = fund.funded(trader2);
        assertTrue(t2Active);
        assertEq(fund.queuePosition(trader3), 1);
        assertEq(fund.queuedDeposits(), TRADER_DEPOSIT);
    }

    function test_Queue_LeaveRefundsDeposit() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _passEval(trader2);
        vm.prank(trader2); fund.claimFunding();

        uint256 before = usdc.balanceOf(trader2);
        vm.prank(trader2); fund.leaveFundingQueue();
        assertEq(usdc.balanceOf(trader2) - before, TRADER_DEPOSIT);
        assertEq(fund.queuePosition(trader2), 0);
        assertEq(fund.queuedDeposits(), 0);
    }

    function test_Queue_LeaveWhenNotQueuedReverts() public {
        vm.prank(trader1);
        vm.expectRevert(PropFund.NotQueued.selector);
        fund.leaveFundingQueue();
    }

    function test_Queue_LeaveFromMiddlePreservesOrder() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _passEval(trader2);
        vm.prank(trader2); fund.claimFunding();
        _passEval(trader3);
        vm.prank(trader3); fund.claimFunding();

        // trader2 (position 1) leaves → trader3 should advance to position 1.
        vm.prank(trader2); fund.leaveFundingQueue();
        assertEq(fund.queuePosition(trader3), 1);
        assertEq(fund.queueLength(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                       FAIR PARTITION
    //////////////////////////////////////////////////////////////*/

    function test_EffectiveCap_BoundedByPoolShare() public {
        // Tight pool. Two funded traders share 1_000 USDC pool.
        PropFund tight = _deployFund({maxTraders: 5, lpAmount: 1_000e6});
        _passEvalOn(tight, trader1);
        vm.prank(trader1); tight.claimFunding();
        _grantMaxLevel(address(tight), trader1);
        _passEvalOn(tight, trader2);
        vm.prank(trader2); tight.claimFunding();
        _grantMaxLevel(address(tight), trader2);

        // Per-trader cap = (100/2) * 10 = 500. Fair share = 1000 / 2 = 500. min = 500.
        assertEq(tight.effectiveCap(trader1), 500e6);

        // Shrink pool further: an LP doesn't exist here but a trade-open consumes pool.
        // After trader1 opens a 400 USDC notional, pool drops to 600 → fair share = 300.
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); tight.openTrade(0, 8_000, false, 8000e8, 2000e8, 8);  // 50/2 * 0.8 * 8 = 200... wait
        // sizeBps 8000 of maxMargin 50 = 40 margin × 8 leverage = 320 notional
        // pool was 1000, drops to 680 → fair share = 340
        assertLt(tight.effectiveCap(trader2), 500e6);
    }

    function test_OpenTrade_BlockedByFairCap() public {
        // Tight pool: 200 USDC pool, 2 funded traders → fair share = 100 each.
        PropFund tight = _deployFund({maxTraders: 5, lpAmount: 200e6});
        _passEvalOn(tight, trader1);
        vm.prank(trader1); tight.claimFunding();
        _grantMaxLevel(address(tight), trader1);
        _passEvalOn(tight, trader2);
        vm.prank(trader2); tight.claimFunding();
        _grantMaxLevel(address(tight), trader2);

        // Per-trader cap = 500, fair share = 100. trader1 trying for 200 should fail.
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1);
        vm.expectRevert(PropFund.InsufficientPool.selector);
        tight.openTrade(0, 10_000, false, 8000e8, 2000e8, 4);  // 50 × 4 = 200 notional > 100 cap
    }

    /*//////////////////////////////////////////////////////////////
                       POSITION MAX-DURATION
    //////////////////////////////////////////////////////////////*/

    function test_ForceClose_BeforeExpiryReverts() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _grantMaxLevel(address(fund), trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 5_000, false, 8000e8, 2000e8, 3);

        vm.prank(keeper);
        vm.expectRevert(PropFund.PositionNotExpired.selector);
        fund.forceClose(trader1);
    }

    function test_ForceClose_AfterExpirySettles() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _grantMaxLevel(address(fund), trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(trader1); fund.openTrade(0, 5_000, false, 8000e8, 2000e8, 3);

        // Roll past MAX_POSITION_BLOCKS (604_800 — ~14 days at 2s blocks on Base).
        vm.roll(block.number + 604_801);
        pyth.setSpotE8(ETH_ID, 4200e8);  // refresh to keep oracle fresh
        // Also bump timestamp because oracle staleness is timestamp-based and roll doesn't move it
        vm.warp(block.timestamp + 2 * 604_801);
        pyth.setSpotE8(ETH_ID, 4200e8);  // re-set after warp so updatedAt is current

        assertTrue(fund.positionExpired(trader1));
        vm.prank(keeper); fund.forceClose(trader1);

        (,,,,,,bool active,,) = fund.positions(trader1);
        assertFalse(active);
    }

    function test_PositionAge_TracksBlocks() public {
        _passEval(trader1);
        vm.prank(trader1); fund.claimFunding();
        _grantMaxLevel(address(fund), trader1);
        pyth.setSpotE8(ETH_ID, 4000e8);
        uint256 openAt = block.number;
        vm.prank(trader1); fund.openTrade(0, 5_000, false, 8000e8, 2000e8, 3);

        vm.roll(block.number + 50);
        assertEq(fund.positionAge(trader1), 50);
        assertFalse(fund.positionExpired(trader1));
        assertEq(block.number - openAt, 50);
    }

    /*//////////////////////////////////////////////////////////////
                       HELPERS
    //////////////////////////////////////////////////////////////*/

    function _passEval(address trader) internal {
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

    /// Hot-patch funded[trader].lastLevel = MAX_LEVERAGE so tests can use leverage 3+ at day 1.
    function _grantMaxLevel(address fundAddr, address trader) internal {
        bytes32 baseSlot = keccak256(abi.encode(trader, uint256(11))); // 11 = `funded` slot
        vm.store(fundAddr, bytes32(uint256(baseSlot) + 3), bytes32(uint256(10)));
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

    function _deployFund(uint256 maxTraders, uint256 lpAmount) internal returns (PropFund f) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 1 hours;
        f = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: treasury,
            evalFee: EVAL_FEE,
            fundedAllocation: ALLOCATION,
            evalDuration: EVAL_DURATION,
            traderDeposit: TRADER_DEPOSIT,
            maxFundedTraders: maxTraders,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));
        vm.prank(lp); usdc.approve(address(f), type(uint256).max);
        vm.prank(lp); f.deposit(lpAmount);
    }
}

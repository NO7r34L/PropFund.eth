// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PropFund} from "../src/PropFund.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

/// @notice An authorized agent runs the full trader lifecycle on behalf of a principal.
/// All USDC inflows (eval fee, deposit) come from the principal; all outflows (refund,
/// profit, deposit return) go back to the principal. The agent never holds value.
contract DelegationTest is Test {
    PropFund fund;
    MockUSDC usdc;
    MockPyth pyth;
    bytes32 constant ETH_ID = bytes32(uint256(1));

    address lp = address(0x1111);
    address treasury = address(0xDE5);
    address principal = address(0xA11CE);   // human / institution
    address agent     = address(0xA9E47);   // delegated controller's EOA
    address other     = address(0xBEEF);    // unrelated address — should be blocked

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

        fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: treasury,
            evalFee: EVAL_FEE,
            fundedAllocation: ALLOCATION,
            evalDuration: EVAL_DURATION,
            traderDeposit: TRADER_DEPOSIT,
            maxFundedTraders: 5,
            pyth: IPyth(address(pyth)),
            priceIds: ids,
            staleAfter: staleAfter
        }));

        usdc.mint(lp, 1_000_000e6);
        vm.prank(lp); usdc.approve(address(fund), type(uint256).max);
        vm.prank(lp); fund.deposit(50_000e6);

        // Principal funds + approves contract for the agent's budget.
        usdc.mint(principal, 10_000e6);
        vm.prank(principal); usdc.approve(address(fund), type(uint256).max);

        // Authorize the agent for the next year, max notional 1000 USDC per trade.
        vm.prank(principal);
        fund.setController(agent, 1_000e6, uint64(block.timestamp + 365 days));
    }

    /*//////////////////////////////////////////////////////////////
                          AUTH
    //////////////////////////////////////////////////////////////*/

    function test_setController_StoresAuth() public {
        (address a, uint128 maxN, uint64 exp) = fund.controllers(principal);
        assertEq(a, agent);
        assertEq(maxN, 1_000e6);
        assertGt(exp, block.timestamp);
    }

    function test_revokeController_KillsAuthority() public {
        vm.prank(principal); fund.revokeController();
        vm.prank(agent);
        vm.expectRevert(PropFund.NotAuthorized.selector);
        fund.startEvalFor(principal);
    }

    function test_setController_RejectsZeroAgent() public {
        vm.prank(principal);
        vm.expectRevert(PropFund.InvalidAuthorization.selector);
        fund.setController(address(0), 1_000e6, uint64(block.timestamp + 1 days));
    }

    function test_setController_RejectsPastExpiry() public {
        vm.prank(principal);
        vm.expectRevert(PropFund.InvalidAuthorization.selector);
        fund.setController(agent, 1_000e6, uint64(block.timestamp));
    }

    function test_NonAgentBlocked() public {
        vm.prank(other);
        vm.expectRevert(PropFund.NotAuthorized.selector);
        fund.startEvalFor(principal);
    }

    function test_ExpiryEnforced() public {
        // Set a tight 1-day window
        vm.prank(principal);
        fund.setController(agent, 1_000e6, uint64(block.timestamp + 1 days));

        skip(1 days + 1);
        vm.prank(agent);
        vm.expectRevert(PropFund.AuthorizationExpired.selector);
        fund.startEvalFor(principal);
    }

    /*//////////////////////////////////////////////////////////////
                          FULL LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_Agent_RunsFullLifecycleAsPrincipal() public {
        uint256 principalBefore = usdc.balanceOf(principal);

        // 1. Agent starts eval as principal — eval fee is pulled from principal.
        vm.prank(agent); fund.startEvalFor(principal);
        assertEq(principalBefore - usdc.balanceOf(principal), EVAL_FEE);

        // 2. Agent runs three winning eval trades.
        uint256[3] memory prices = [uint256(4120e8), 4243e8, 4370e8];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agent); fund.openEvalTradeFor(principal, 0);
            pyth.setSpotE8(ETH_ID, int256(prices[i]));
            vm.roll(block.number + 10);
            vm.prank(agent); fund.closeEvalTradeFor(principal);
        }
        (,,,,,,, bool passed,) = fund.evals(principal);
        assertTrue(passed);

        // 3. Agent claims funding — deposit from principal.
        pyth.setSpotE8(ETH_ID, 4000e8);
        uint256 principalBeforeClaim = usdc.balanceOf(principal);
        vm.prank(agent); fund.claimFundingFor(principal);
        _grantMaxLevel();
        assertEq(principalBeforeClaim - usdc.balanceOf(principal), TRADER_DEPOSIT);
        (bool active,,,) = fund.funded(principal);
        assertTrue(active);

        // 4. Agent opens a long for principal.
        vm.prank(agent);
        fund.openTradeFor(principal, 0, 10_000, false, 8000e8, 2000e8, 5);
        (,,,,,,bool posActive,,) = fund.positions(principal);
        assertTrue(posActive);

        // 5. Price moves up; agent closes for profit.
        pyth.setSpotE8(ETH_ID, 4200e8);
        vm.prank(agent); fund.closeTradeFor(principal, 10_000);
        (, int256 cumPnl,,) = fund.funded(principal);
        assertGt(cumPnl, 0);

        // 6. Cashing out is principal-only by design — the agent operates the position,
        // the principal pulls profit when satisfied.
        uint256 agentBalanceBefore = usdc.balanceOf(agent);
        uint256 principalBeforeWithdraw = usdc.balanceOf(principal);
        vm.prank(principal); fund.withdrawProfit(5e6);
        assertGt(usdc.balanceOf(principal), principalBeforeWithdraw);
        assertEq(usdc.balanceOf(agent), agentBalanceBefore, "agent must never receive funds");

        // 7. Principal ends the funded relationship — deposit returns to principal.
        vm.prank(principal); fund.resignFunding();
        (bool stillActive,,,) = fund.funded(principal);
        assertFalse(stillActive);
        assertEq(usdc.balanceOf(agent), agentBalanceBefore, "agent still holds nothing after resign");
    }

    /*//////////////////////////////////////////////////////////////
                          CAP ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_OpenTradeFor_RejectsOversizedNotional() public {
        // Lower the per-trade cap so principal's per-trader cap (500) > agent cap (200).
        vm.prank(principal);
        fund.setController(agent, 200e6, uint64(block.timestamp + 365 days));

        // Get the principal funded.
        _passEvalForPrincipal();
        pyth.setSpotE8(ETH_ID, 4000e8);
        vm.prank(agent); fund.claimFundingFor(principal);
        _grantMaxLevel();

        // 50 margin × 10 leverage = 500 notional > agent's 200 cap → revert.
        vm.prank(agent);
        vm.expectRevert(PropFund.MaxNotionalExceeded.selector);
        fund.openTradeFor(principal, 0, 10_000, false, 8000e8, 2000e8, 10);

        // Within the cap (50 × 4 = 200) should work.
        vm.prank(agent);
        fund.openTradeFor(principal, 0, 10_000, false, 8000e8, 2000e8, 4);
    }

    /*//////////////////////////////////////////////////////////////
                          PRINCIPAL STILL ACTS
    //////////////////////////////////////////////////////////////*/

    function test_PrincipalCanActInParallelWithAgent() public {
        _passEvalForPrincipal();
        pyth.setSpotE8(ETH_ID, 4000e8);

        // Principal claims funding directly (not via agent).
        vm.prank(principal); fund.claimFunding();
        _grantMaxLevel();

        // Then the agent opens a trade for the principal.
        vm.prank(agent); fund.openTradeFor(principal, 0, 5_000, false, 8000e8, 2000e8, 3);

        // Principal closes it themselves.
        pyth.setSpotE8(ETH_ID, 4100e8);
        vm.prank(principal); fund.closeTrade(10_000);
        (,,,,,,bool stillOpen,,) = fund.positions(principal);
        assertFalse(stillOpen);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPERS
    //////////////////////////////////////////////////////////////*/

    function _passEvalForPrincipal() internal {
        vm.prank(agent); fund.startEvalFor(principal);
        uint256[3] memory prices = [uint256(4120e8), 4243e8, 4370e8];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agent); fund.openEvalTradeFor(principal, 0);
            pyth.setSpotE8(ETH_ID, int256(prices[i]));
            vm.roll(block.number + 10);
            vm.prank(agent); fund.closeEvalTradeFor(principal);
        }
    }

    /// Hot-patch funded[principal].lastLevel = MAX_LEVERAGE so existing leverage-3+ tests
    /// pass without simulating long PnL grinds. The level gate itself is verified in the
    /// dedicated unit test (test_OpenTrade_LeverageGatedByLastLevel).
    function _grantMaxLevel() internal {
        bytes32 baseSlot = keccak256(abi.encode(principal, uint256(11)));
        vm.store(address(fund), bytes32(uint256(baseSlot) + 3), bytes32(uint256(10)));
    }
}

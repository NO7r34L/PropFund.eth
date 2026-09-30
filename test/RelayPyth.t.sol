// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PropFund} from "../src/PropFund.sol";
import {RelayPyth} from "../src/RelayPyth.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract RelayPythTest is Test {
    RelayPyth relay;
    PropFund fund;
    MockUSDC usdc;
    bytes32 constant ETH_ID = bytes32(uint256(1));
    address relayer = address(0xBEEF);
    address trader = address(0xA11CE);

    function setUp() public {
        relay = new RelayPyth(relayer);
        vm.prank(relayer); relay.setSpotE8(ETH_ID, 2000e8);   // PropFund's constructor needs a live feed
        usdc = new MockUSDC();
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint256[] memory staleAfter = new uint256[](1);
        staleAfter[0] = 5 minutes;
        fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            treasury: address(0xDE5),
            guardian: address(0xDEA),
            evalFee: 1,
            fundedAllocation: 1_000e6,
            evalDuration: 50_400,
            traderDeposit: 100e6,
            maxFundedTraders: 50,
            pyth: IPyth(address(relay)),
            priceIds: ids,
            staleAfter: staleAfter
        }));
        usdc.mint(trader, 1_000e6);
        vm.prank(trader); usdc.approve(address(fund), type(uint256).max);
    }

    function test_RelayerSetsPrice() public {
        vm.warp(1_000_000);
        vm.prank(relayer); relay.setSpotE8(ETH_ID, 2500e8);
        IPyth.Price memory p = relay.getPriceUnsafe(ETH_ID);
        assertEq(p.price, 2500e8);
        assertEq(p.expo, -8);
        assertEq(p.conf, 0);
        assertEq(p.publishTime, 1_000_000);
    }

    function test_OnlyRelayer() public {
        vm.expectRevert(RelayPyth.NotRelayer.selector);
        relay.setSpotE8(ETH_ID, 2500e8);
        vm.expectRevert(RelayPyth.NotRelayer.selector);
        relay.setRelayer(address(this));
    }

    function test_RejectsNonPositiveAndOverflow() public {
        vm.startPrank(relayer);
        vm.expectRevert(RelayPyth.BadPrice.selector);
        relay.setSpotE8(ETH_ID, 0);
        vm.expectRevert(RelayPyth.BadPrice.selector);
        relay.setSpotE8(ETH_ID, -1);
        vm.expectRevert(RelayPyth.BadPrice.selector);
        relay.setSpotE8(ETH_ID, int256(type(int64).max) + 1);
        vm.stopPrank();
    }

    function test_ZeroRelayerRejected() public {
        vm.expectRevert(RelayPyth.ZeroAddress.selector);
        new RelayPyth(address(0));
        vm.expectRevert(RelayPyth.ZeroAddress.selector);
        vm.prank(relayer); relay.setRelayer(address(0));
    }

    function test_RelayerHandoff() public {
        vm.prank(relayer); relay.setRelayer(address(0xCAFE));
        vm.prank(address(0xCAFE)); relay.setSpotE8(ETH_ID, 1e8);
        vm.expectRevert(RelayPyth.NotRelayer.selector);
        vm.prank(relayer); relay.setSpotE8(ETH_ID, 1e8);
    }

    function test_SignedUpdatesRejected_EmptyPushOk() public {
        bytes[] memory none = new bytes[](0);
        fund.pushPyth(none);   // empty, zero-value: no-op
        bytes[] memory vaa = new bytes[](1);
        vaa[0] = hex"504e4155";
        vm.expectRevert(RelayPyth.UpdatesNotSupported.selector);
        fund.pushPyth(vaa);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(RelayPyth.UpdatesNotSupported.selector);
        fund.pushPyth{value: 1}(none);
        assertEq(relay.getUpdateFee(vaa), 0);
    }

    /// PropFund trades end-to-end on relayed prices, and its own staleAfter guard still bites.
    function test_EvalTradeOnRelayedPrice_AndStaleGuard() public {
        vm.warp(1_000_000);
        vm.prank(relayer); relay.setSpotE8(ETH_ID, 2000e8);
        vm.prank(trader); fund.startEval();
        vm.prank(trader); fund.openEvalTrade(0);

        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 20);
        vm.prank(relayer); relay.setSpotE8(ETH_ID, 2100e8);   // +5%
        vm.prank(trader); fund.closeEvalTrade();

        // Relay goes quiet past the 5-min window -> PropFund refuses to open.
        vm.warp(block.timestamp + 6 minutes);
        vm.expectRevert(PropFund.StaleOracle.selector);
        vm.prank(trader); fund.openEvalTrade(0);
    }
}

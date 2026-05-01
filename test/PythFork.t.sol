// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

/// @notice Fork test against the real Pyth contract on Base Sepolia. Verifies the
/// assumptions baked into PropFund:
///   1. Every wired feed reports at expo = -8 (the value we lock at install time).
///   2. The 8 listed assets are live (positive price, non-zero publishTime).
///   3. The conf interval is reasonable (< 1% on majors during normal market).
///
/// Skipped automatically when `BASE_SEPOLIA_RPC` is not set so this doesn't break CI.
/// To run locally:
///   BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract PythFork
contract PythForkTest is Test {
    address constant PYTH_BASE_SEPOLIA = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;

    bytes32 constant ETH_USD  = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant BTC_USD  = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant SOL_USD  = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    bytes32 constant AVAX_USD = 0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7;
    bytes32 constant LINK_USD = 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221;
    bytes32 constant AAVE_USD = 0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445;
    bytes32 constant DOGE_USD = 0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c;
    bytes32 constant ARB_USD  = 0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5;

    function setUp() public {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory rpc) {
            vm.createSelectFork(rpc);
        } catch {
            // Skip cleanly when env var missing — keeps CI green without a forced fork.
            vm.skip(true);
        }
    }

    function test_AllListedFeedsAreExpoMinus8() public view {
        IPyth pyth = IPyth(PYTH_BASE_SEPOLIA);
        bytes32[8] memory ids = [ETH_USD, BTC_USD, SOL_USD, AVAX_USD, LINK_USD, AAVE_USD, DOGE_USD, ARB_USD];
        for (uint256 i = 0; i < ids.length; i++) {
            IPyth.Price memory p = pyth.getPriceUnsafe(ids[i]);
            assertEq(p.expo, int32(-8), "all listed feeds must be expo -8");
            assertGt(p.price, 0, "feed must have positive price");
            assertGt(p.publishTime, 0, "feed must have non-zero publishTime");
        }
    }

    /// Sanity-check our MAX_CONF_BPS gate against real-world conf values. During normal
    /// market conditions, majors should report < 0.5% conf. If this test starts failing
    /// during a market crisis, it's signal — the contract is correctly refusing trades.
    function test_MajorsHaveReasonableConfDuringNormalMarket() public view {
        IPyth pyth = IPyth(PYTH_BASE_SEPOLIA);
        bytes32[3] memory majors = [ETH_USD, BTC_USD, SOL_USD];
        for (uint256 i = 0; i < majors.length; i++) {
            IPyth.Price memory p = pyth.getPriceUnsafe(majors[i]);
            uint256 price = uint256(uint64(p.price));
            uint256 conf = uint256(p.conf);
            // conf should be < 1% of price during normal conditions (we reject at 0.5%).
            assertLt(conf * 100, price, "major asset conf too wide for normal market");
        }
    }
}

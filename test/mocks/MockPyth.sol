// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IPyth} from "../../src/interfaces/IPyth.sol";

/// @notice In-memory Pyth mock for tests. Holds prices keyed by feed ID. updatePriceFeeds is
/// a no-op (tests set prices directly). getUpdateFee returns 1 wei to mirror live Pyth on L2s.
contract MockPyth is IPyth {
    mapping(bytes32 => Price) internal _prices;

    /// @notice Test helper — set the cached price for a feed.
    function setPrice(bytes32 id, int64 price, int32 expo, uint256 publishTime) external {
        _prices[id] = Price({ price: price, conf: 0, expo: expo, publishTime: publishTime });
    }

    /// @notice Convenience for tests: int256 input, expo -8, publishTime = block.timestamp.
    function setSpotE8(bytes32 id, int256 priceE8) external {
        _prices[id] = Price({ price: int64(priceE8), conf: 0, expo: -8, publishTime: block.timestamp });
    }

    /// @notice Like setSpotE8 but with a custom confidence interval (also expo-8).
    /// Used by audit tests to verify the conf-rejection guard (M-1).
    function setSpotE8WithConf(bytes32 id, int256 priceE8, uint64 confE8) external {
        _prices[id] = Price({ price: int64(priceE8), conf: confE8, expo: -8, publishTime: block.timestamp });
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        return _prices[id];
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {
        // no-op in tests; setPrice / setSpotE8 set state directly
    }

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 1;
    }
}

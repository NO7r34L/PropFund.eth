// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice The subset of PropFundLens the desk reads for admission. The struct MUST match
///         PropFundLens.TraderStats field-for-field so the ABI decodes against the live lens.
/// @dev PropFund is untouched; the desk only reads its probation record through this view.
interface IPropFundLens {
    struct TraderStats {
        bool active;
        uint256 level;
        uint256 deposit;
        int256 cumulativePnl;
        uint256 maxDeploy;
        bool inPosition;
        bool isShort;
        uint8 assetId;
        uint256 deployedAmount;
        uint64 entryPrice;
        uint64 tpPrice;
        uint64 slPrice;
        uint32 wins;
        uint32 losses;
        uint256 totalProfit;
        uint256 totalLoss;
    }

    function getTraderStats(address trader) external view returns (TraderStats memory);
}

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @notice Minimal subset of Pyth Network's IPyth interface used by PropFund.
/// @dev Source: https://github.com/pyth-network/pyth-sdk-solidity
interface IPyth {
    struct Price {
        int64 price;          // The price (scaled by 10^expo)
        uint64 conf;          // Confidence interval (one stddev)
        int32  expo;          // Decimal exponent (e.g. -8 → price * 10^-8)
        uint256 publishTime;  // Unix timestamp when this price was attested
    }

    /// @notice Read the latest cached price for a feed without freshness enforcement.
    /// @dev Call updatePriceFeeds first if you need a fresh price; this returns whatever the
    /// contract last accepted (could be from any block).
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Apply signed price updates to the on-chain Pyth state. Must be called with
    /// msg.value >= getUpdateFee(updateData).
    /// @param updateData Signed VAA(s) fetched from Hermes.
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice Compute the ETH fee required to apply a given batch of update VAAs.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
}

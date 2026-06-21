// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IPyth} from "./interfaces/IPyth.sol";

/// @notice The subset of PropFund's delegated trade entrypoints this router drives.
interface IPropFundTrades {
    function openEvalTradeFor(address principal, uint8 assetId) external;
    function closeEvalTradeFor(address principal) external;
    function openTradeFor(
        address principal,
        uint8 assetId,
        uint256 sizeBps,
        bool isShort,
        uint64 tp,
        uint64 sl,
        uint8 leverage
    ) external;
    function closeTradeFor(address principal, uint256 closeBps) external;
}

/// @title PropFundRouter
/// @notice Atomic "update Pyth, then trade" periphery for PropFund. Folds the on-chain price
///         update into the trade so a price-sensitive entry/exit is a SINGLE transaction instead
///         of a separate pushPyth followed by the trade.
///
///         Trust model: the router is stateless and custody-free. It never holds a position,
///         deposit, or balance between calls — PropFund settles every value flow to the
///         principal, and any unused msg.value is refunded to the caller in the same tx. PropFund
///         stays immutable and untouched; this is opt-in periphery.
///
///         Usage: a principal authorizes this router once via
///         `PropFund.setController(router, maxNotionalPerTrade, expiry)`; thereafter it calls the
///         router and the router drives the principal's `*For` actions. `updateData` is the signed
///         Pyth VAA bundle (from Hermes); pass an empty array to skip the update when the on-chain
///         price is already fresh, making the action a plain single-tx trade.
contract PropFundRouter {
    IPyth public immutable PYTH;
    IPropFundTrades public immutable FUND;

    /// @notice Refund of unused msg.value to the caller failed.
    error RefundFailed();

    constructor(IPyth pyth, IPropFundTrades fund) {
        PYTH = pyth;
        FUND = fund;
    }

    /// @dev Apply the signed Pyth update (if any), paying exactly the quoted fee from msg.value.
    function _update(bytes[] calldata updateData) internal {
        if (updateData.length != 0) {
            uint256 fee = PYTH.getUpdateFee(updateData);
            PYTH.updatePriceFeeds{value: fee}(updateData);
        }
    }

    /// @dev Return any leftover msg.value (sent to cover the Pyth fee) to the caller. Last action,
    ///      after the trade has fully settled in PropFund (which is itself nonReentrant).
    function _refund() internal {
        uint256 bal = address(this).balance;
        if (bal != 0) {
            (bool ok, ) = msg.sender.call{value: bal}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice Update price, then open the caller's eval trade. Single tx.
    function openEvalTrade(bytes[] calldata updateData, uint8 assetId) external payable {
        _update(updateData);
        FUND.openEvalTradeFor(msg.sender, assetId);
        _refund();
    }

    /// @notice Update price, then close the caller's eval trade. Single tx.
    function closeEvalTrade(bytes[] calldata updateData) external payable {
        _update(updateData);
        FUND.closeEvalTradeFor(msg.sender);
        _refund();
    }

    /// @notice Update price, then open the caller's funded position. Single tx.
    function openTrade(
        bytes[] calldata updateData,
        uint8 assetId,
        uint256 sizeBps,
        bool isShort,
        uint64 tp,
        uint64 sl,
        uint8 leverage
    ) external payable {
        _update(updateData);
        FUND.openTradeFor(msg.sender, assetId, sizeBps, isShort, tp, sl, leverage);
        _refund();
    }

    /// @notice Update price, then close the caller's funded position. Single tx.
    function closeTrade(bytes[] calldata updateData, uint256 closeBps) external payable {
        _update(updateData);
        FUND.closeTradeFor(msg.sender, closeBps);
        _refund();
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IPyth} from "./interfaces/IPyth.sol";

/// @title RelayPyth — testnet-only, IPyth-compatible price relay
/// @notice Pyth's API became paid-only in 2026-09 and nobody pushes Pyth feeds on Base Sepolia, so a
///         public testnet deploy has no free source of signed updates. This contract stands in for
///         Pyth at the same interface: one RELAYER key writes spot prices (the heartbeat relays
///         Coinbase public spot), and PropFund / AgentDesk / SignalKeeper read it through
///         getPriceUnsafe exactly as they read Pyth, with their own staleAfter guards unchanged.
/// @dev    TRUST: whoever holds RELAYER sets every price. That is acceptable for a testnet with mock
///         USDC and never for real funds — mainnet deploys point at the real Pyth contract.
///         Signed updates are not supported: updatePriceFeeds with data reverts, so a caller still
///         bundling Hermes VAAs fails loudly instead of silently trading on the relayed price.
contract RelayPyth is IPyth {
    address public relayer;
    mapping(bytes32 => Price) internal _prices;

    error NotRelayer();
    error BadPrice();
    error UpdatesNotSupported();
    error ZeroAddress();

    event PriceRelayed(bytes32 indexed id, int64 price, uint256 publishTime);
    event RelayerChanged(address indexed relayer);

    constructor(address relayer_) {
        if (relayer_ == address(0)) revert ZeroAddress();
        relayer = relayer_;
        emit RelayerChanged(relayer_);
    }

    /// @notice Write a spot price (expo -8, conf 0, publishTime = block.timestamp).
    function setSpotE8(bytes32 id, int256 priceE8) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (priceE8 <= 0 || priceE8 > type(int64).max) revert BadPrice();
        _prices[id] = Price({ price: int64(priceE8), conf: 0, expo: -8, publishTime: block.timestamp });
        emit PriceRelayed(id, int64(priceE8), block.timestamp);
    }

    /// @notice Batch form of setSpotE8 — the heartbeat writes every moved feed in one tx.
    function setSpotsE8(bytes32[] calldata ids, int256[] calldata pricesE8) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (ids.length != pricesE8.length) revert BadPrice();
        for (uint256 i = 0; i < ids.length; i++) {
            int256 px = pricesE8[i];
            if (px <= 0 || px > type(int64).max) revert BadPrice();
            _prices[ids[i]] = Price({ price: int64(px), conf: 0, expo: -8, publishTime: block.timestamp });
            emit PriceRelayed(ids[i], int64(px), block.timestamp);
        }
    }

    /// @notice Hand the relayer role to a new key (e.g. after a rotation). Only the current relayer.
    function setRelayer(address next) external {
        if (msg.sender != relayer) revert NotRelayer();
        if (next == address(0)) revert ZeroAddress();
        relayer = next;
        emit RelayerChanged(next);
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        return _prices[id];
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable override {
        if (updateData.length != 0 || msg.value != 0) revert UpdatesNotSupported();
    }

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 0;
    }
}

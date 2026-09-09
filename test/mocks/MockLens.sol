// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IPropFundLens} from "../../src/interfaces/IPropFundLens.sol";

/// @notice Configurable PropFund lens for desk admission tests.
contract MockLens is IPropFundLens {
    mapping(address => TraderStats) internal _stats;

    /// @notice Set the probation record the desk will read for `trader`.
    function setRecord(address trader, int256 cumulativePnl, uint32 wins, uint32 losses) external {
        TraderStats storage s = _stats[trader];
        s.active = true;
        s.cumulativePnl = cumulativePnl;
        s.wins = wins;
        s.losses = losses;
        // default: winners twice the size of losers (profit factor 2.0)
        if (cumulativePnl > 0) { s.totalProfit = uint256(cumulativePnl) * 2; s.totalLoss = uint256(cumulativePnl); }
        else { s.totalProfit = 0; s.totalLoss = uint256(-cumulativePnl); }
    }

    /// @notice Set the gross profit / gross loss the desk's profit-factor bar reads.
    function setGross(address trader, uint256 totalProfit, uint256 totalLoss) external {
        _stats[trader].totalProfit = totalProfit;
        _stats[trader].totalLoss = totalLoss;
    }

    function getTraderStats(address trader) external view returns (TraderStats memory) {
        return _stats[trader];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal view of PropFund — only the public getters the lens needs.
interface IPropFundView {
    function funded(address) external view returns (bool active, int256 cumulativePnl, uint256 deposit, uint8 lastLevel);
    function positions(address)
        external
        view
        returns (
            uint256 usdcDeployed,
            uint64 entryPrice,
            uint64 tpPrice,
            uint64 slPrice,
            uint64 margin,
            uint8 assetId,
            bool active,
            bool isShort,
            uint32 openBlock
        );
    function records(address) external view returns (uint32 wins, uint32 losses, uint256 totalProfit, uint256 totalLoss);
    function evals(address)
        external
        view
        returns (
            uint256 virtualBalance,
            uint256 highWaterMark,
            uint64 entryPrice,
            uint32 startBlock,
            uint32 tradeOpenBlock,
            uint16 tradeCount,
            bool active,
            bool passed,
            uint8 assetId
        );
    function EVAL_DURATION() external view returns (uint256);
}

/// @title  PropFundLens
/// @notice Stateless view layer for PropFund. Composite reads (`getTraderStats`, `getEvalStatus`) live
///         here instead of in the core contract so PropFund stays under the EIP-170 size limit. The
///         return shapes are byte-identical to the originals, so existing ABI consumers only need to
///         repoint these two calls at the lens address. Reads only PropFund public state — no privileges.
contract PropFundLens {
    IPropFundView public immutable FUND;

    // Mirrors of PropFund constants (single source of truth is PropFund; these are compile-time fixed).
    uint8 internal constant MAX_LEVERAGE = 10; // mirrors PropFund.MAX_LEVERAGE
    uint256 internal constant EVAL_PROFIT_BPS = 800;
    uint256 internal constant EVAL_DRAWDOWN_BPS = 500;
    uint256 internal constant MIN_EVAL_TRADES = 3;

    constructor(address fund) {
        FUND = IPropFundView(fund);
    }

    /// @notice Funded-trader leverage tier from cumulative PnL — mirrors PropFund._leverageLevel.
    function _leverageLevel(int256 cumPnl) internal pure returns (uint256) {
        if (cumPnl >= 1000e6) return 10;
        if (cumPnl >= 400e6) return 8;
        if (cumPnl >= 150e6) return 5;
        if (cumPnl >= 50e6) return 3;
        return 2;
    }

    /// @notice Composite funded-trader stats. Identical shape to the former PropFund.getTraderStats.
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

    function getTraderStats(address trader) external view returns (TraderStats memory s) {
        // Block-scoped reads so each getter's tuple locals are freed before the next (avoids stack-too-deep).
        {
            (bool fActive, int256 cumPnl, uint256 dep,) = FUND.funded(trader);
            s.active = fActive;
            s.level = fActive ? _leverageLevel(cumPnl) : 0;
            s.deposit = dep;
            s.cumulativePnl = cumPnl;
            if (fActive) s.maxDeploy = (dep * MAX_LEVERAGE) / 2;
        }
        {
            (uint256 usdcDeployed, uint64 pEntry, uint64 tp, uint64 sl,, uint8 pAsset, bool pActive, bool pShort,) =
                FUND.positions(trader);
            s.inPosition = pActive;
            s.isShort = pShort;
            s.assetId = pAsset;
            s.deployedAmount = usdcDeployed;
            s.entryPrice = pEntry;
            s.tpPrice = tp;
            s.slPrice = sl;
        }
        {
            (uint32 wins, uint32 losses, uint256 totalProfit, uint256 totalLoss) = FUND.records(trader);
            s.wins = wins;
            s.losses = losses;
            s.totalProfit = totalProfit;
            s.totalLoss = totalLoss;
        }
    }

    /// @notice Eval progress. Identical shape to the former PropFund.getEvalStatus.
    struct EvalStatus {
        bool active;
        bool passed;
        uint256 returnBps;
        uint256 targetBps;
        uint256 drawdownBps;
        uint256 maxDrawdownBps;
        uint16 tradeCount;
        uint16 tradesNeeded;
        uint256 blocksLeft;
        bool inTrade;
    }

    function getEvalStatus(address trader) external view returns (EvalStatus memory s) {
        (uint256 vbal, uint256 hwm, uint64 eEntry, uint32 startBlock,, uint16 tradeCount, bool eActive, bool ePassed,) =
            FUND.evals(trader);

        s.active = eActive;
        s.passed = ePassed;
        s.targetBps = EVAL_PROFIT_BPS;
        s.maxDrawdownBps = EVAL_DRAWDOWN_BPS;
        s.tradeCount = tradeCount;
        s.tradesNeeded = uint16(MIN_EVAL_TRADES);
        s.inTrade = eEntry != 0;

        if (vbal >= 1e18) s.returnBps = ((vbal - 1e18) * 10_000) / 1e18;
        if (hwm > 0 && vbal < hwm) s.drawdownBps = ((hwm - vbal) * 10_000) / hwm;
        if (eActive) {
            uint256 deadline = startBlock + FUND.EVAL_DURATION();
            s.blocksLeft = block.number < deadline ? deadline - block.number : 0;
        }
    }
}

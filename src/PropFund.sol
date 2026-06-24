// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";
import {EvalCert} from "./EvalCert.sol";

/// @title  PropFund — Decentralized Prop Trading Fund
/// @author PropFund
/// @notice Oracle-settled multi-asset prop trading. Scriptable end-to-end — the full
///         lifecycle (eval → fund → trade → withdraw) is exposed as plain function calls
///         and a delegation primitive lets one EOA drive another's account under a
///         per-trade notional cap and an expiry. The LP pool holds USDC and acts as
///         counterparty to every trade: traders profit → pool pays; traders lose → pool
///         receives. No DEX, no AMM, no MEV surface.
///
///         Lifecycle:
///           (1) Trader pays an eval fee → opens virtual long-only trades on any listed
///               asset → must hit +EVAL_PROFIT_BPS cumulative across ≥ MIN_EVAL_TRADES
///               with peak-to-trough drawdown ≤ EVAL_DRAWDOWN_BPS.
///           (2) Pass triggers an EVAL_PASS NFT, then trader pays TRADER_DEPOSIT to claim
///               funded status. Funded traders get long+short across all listed assets,
///               leverage up to MAX_LEVERAGE, and crossing PnL milestones mints LEVEL_UP
///               NFTs that gate higher leverage tiers.
///           (3) Funded trades require explicit TP and SL on every open. Liquidation is the
///               deeper failsafe (triggers when unrealized loss eats position margin).
///
///         Pricing: Pyth Network. Every wired feed is locked at expo == -8. Any single
///         trade's PnL is capped by CIRCUIT_BREAKER_BPS to bound counterparty risk.
///
///         Delegation: principals authorize an agent EOA via setController(...) — the
///         agent gets bounded write authority (per-trade notional cap + expiry timestamp).
///
///         Keeper surface (permissionless): liquidate, executeExit (TP/SL settlement),
///         forceClose (positions older than MAX_POSITION_BLOCKS), expireEval, and
///         processFundingQueue all callable by anyone, gated by on-chain re-checks.
contract PropFund {
    using SafeTransferLib for IERC20;

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    // Generic input / size errors
    /// @notice An amount or size argument was zero where a positive value is required.
    error ZeroAmount();
    /// @notice An address argument was zero in a context that disallows it.
    error ZeroAddress();
    /// @notice Generic out-of-range size (sizeBps, leverage, array length, etc.).
    error InvalidSize();

    // LP errors
    /// @notice withdraw() called for more shares than the caller owns.
    error NoShares();
    /// @notice Trade or withdrawal cannot be settled because pool USDC is insufficient.
    error InsufficientPool();

    // Eval lifecycle errors
    /// @notice Caller already has an active eval — cancel or expire it before starting another.
    error AlreadyInEval();
    /// @notice Action requires an active eval; caller has none.
    error NotInEval();
    /// @notice Action is no longer allowed because the eval's deadline (EVAL_DURATION) has passed.
    error EvalExpired();
    /// @notice expireEval() called before EVAL_DURATION has elapsed.
    error EvalNotExpired();
    /// @notice Caller already has a virtual position open — close it first.
    error EvalPositionOpen();
    /// @notice closeEvalTrade() called with no active virtual position.
    error EvalNoPosition();
    /// @notice claimFunding() called before eval is marked passed.
    error EvalNotPassed();
    /// @notice startEval() called while a previous eval-passed flag is still pending claim.
    error EvalPassPending();
    /// @notice closeEvalTrade() called before MIN_TRADE_BLOCKS have elapsed since open.
    error TradeTooShort();
    /// @notice cancelEval() called within EVAL_CANCEL_COOLDOWN of the previous cancel.
    error CancelCooldown();

    // Funded-trader errors
    /// @notice Caller is already a funded trader.
    error AlreadyFunded();
    /// @notice Action requires funded status; caller is not funded.
    error NotFunded();
    /// @notice Caller already has an open real position — close it first.
    error TraderPositionOpen();
    /// @notice Action requires an open position; caller has none.
    error NoTraderPosition();
    /// @notice liquidate() called when unrealized loss has not yet consumed the position margin.
    error NotLiquidatable();
    /// @notice forceClose() called before MAX_POSITION_BLOCKS have elapsed since open.
    error PositionNotExpired();
    /// @notice executeExit() called when neither TP nor SL has been crossed.
    error ExitNotTriggered();
    /// @notice withdrawProfit() called when current deposit is at or below TRADER_DEPOSIT.
    error NoProfitToWithdraw();
    /// @notice openTrade() / updateExit() called with TP/SL of zero or on the wrong side of entry.
    error InvalidExit();

    // Funding queue errors
    /// @notice Caller is already in the funding queue.
    error AlreadyQueued();
    /// @notice leaveFundingQueue() called by an address not in the queue.
    error NotQueued();

    // Asset / oracle errors
    /// @notice Asset id outside [0..assetCount). Either the index is invalid or the feed wasn't installed.
    error InvalidAsset();
    /// @notice Pyth feed returned a non-positive price — feed is misbehaving.
    error NegativePrice();
    /// @notice Pyth feed is stale (publishTime too old) or its conf is wider than MAX_CONF_BPS.
    error StaleOracle();
    /// @notice More feeds installed than uint8 can index (assetCount overflow).
    error TooManyFeeds();

    // Access / lifecycle errors
    /// @notice Action restricted to the treasury address.
    error NotTreasury();
    /// @notice Action restricted to the guardian address (emergency pause only).
    error NotGuardian();
    /// @notice Reentrancy attempt detected (transient nonReentrant guard).
    error Reentrancy();
    /// @notice Action blocked while the contract is paused (audit Phase 3).
    error Paused();

    // Delegation errors
    /// @notice Caller is not the agent authorised by the principal in `controllers`.
    error NotAuthorized();
    /// @notice Authorization timestamp has passed.
    error AuthorizationExpired();
    /// @notice Agent attempted a trade whose notional exceeds maxNotionalPerTrade.
    error MaxNotionalExceeded();
    /// @notice setController() called with zero agent or expiry already in the past.
    error InvalidAuthorization();

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice LP deposited USDC and received shares.
    event Deposited(address indexed lp, uint256 usdc, uint256 shares);
    /// @notice LP burned shares and withdrew USDC.
    event Withdrawn(address indexed lp, uint256 usdc, uint256 shares);

    /// @notice Trader paid eval fee and started a new evaluation.
    event EvalStarted(address indexed trader);
    /// @notice Virtual long opened during eval. Asset is on the EvalAccount struct.
    event EvalTradeOpened(address indexed trader, uint256 entryPrice);
    /// @notice Virtual long closed. returnBps = trade %, cumulativeBps = cumulative since eval start.
    event EvalTradeClosed(address indexed trader, int256 returnBps, int256 cumulativeBps);
    /// @notice Eval pass criteria met (≥ +EVAL_PROFIT_BPS over ≥ MIN_EVAL_TRADES, drawdown < EVAL_DRAWDOWN_BPS).
    event EvalPassed(address indexed trader);
    /// @notice Eval failed — drawdown breach, expiry, or voluntary cancel.
    event EvalFailedEvent(address indexed trader, int256 cumulativeBps);

    /// @notice Trader claimed funded status (or queue advance ran). FUNDED_ALLOCATION emitted as context.
    event FundingClaimed(address indexed trader, uint256 allocation);
    /// @notice Funded status was revoked (resign, deposit drained, or final loss < MIN_DEPOSIT).
    event FundingRevoked(address indexed trader, int256 cumulativePnl);
    /// @notice Trader added to the FIFO funding queue (pool capacity exhausted).
    event FundingQueued(address indexed trader, uint256 position);
    /// @notice Trader called leaveFundingQueue and was refunded their escrowed deposit.
    event FundingQueueLeft(address indexed trader);

    /// @notice Real position opened. usdcDeployed = margin × leverage; entryPrice in 1e8 scale.
    event TradeOpened(address indexed trader, uint8 assetId, bool isShort, uint256 usdcDeployed, uint256 entryPrice);
    /// @notice Real position settled. pnl > 0 = trader profit, pnl < 0 = pool gain.
    event TradeClosed(address indexed trader, uint256 usdcSettled, int256 pnl);
    /// @notice 5% treasury fee accrued on a profitable settlement (pull-pattern; the treasury
    ///         address claims via withdrawTreasury). Funds protocol operations + maintenance.
    event TreasuryFeeAccrued(address indexed trader, uint256 amount);
    /// @notice Trader's 80% profit share compounded into deposit.
    event ProfitCompounded(address indexed trader, uint256 amount, uint256 newDeposit);
    /// @notice Trader pulled USDC profit above their initial TRADER_DEPOSIT.
    event ProfitWithdrawn(address indexed trader, uint256 amount);
    /// @notice Trader-deposit refund issued (resign, queue leave, or revoke).
    event DepositReturned(address indexed trader, uint256 amount);

    /// @notice Position liquidated by `liquidator` because unrealized loss ≥ position margin.
    event Liquidated(address indexed trader, address indexed liquidator);
    /// @notice Position closed by `caller` because it exceeded MAX_POSITION_BLOCKS.
    event PositionForceClosed(address indexed trader, address indexed caller);
    /// @notice TP or SL triggered and `executor` settled the position. `tpHit` distinguishes which side fired.
    event ExitExecuted(address indexed trader, address indexed executor, bool tpHit);

    /// @notice Funded trader crossed a leverage tier (3/5/8/10). EvalCert mints a LEVEL_UP NFT.
    event LevelUp(address indexed trader, uint8 newLevel);
    /// @notice Cert mint failed inside settlement (try/catch); trader still earned the milestone.
    ///         Indexers can use this to flag a missed cert for off-chain recovery.
    event CertMintFailed(address indexed trader, uint8 certType, uint256 value, uint8 level);

    /// @notice Principal authorised an agent to act on their behalf with a per-trade notional cap.
    event ControllerSet(address indexed principal, address indexed agent, uint256 maxNotionalPerTrade, uint256 expiry);
    /// @notice Principal revoked their controller. Open positions and funded status are unaffected.
    event ControllerRevoked(address indexed principal);

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The settlement asset. All deposits, fees, payouts, and PnL are denominated in this token.
    IERC20 public immutable USDC;
    /// @notice Treasury address — receives the protocol fee (5% of trader profits) and is the
    ///         caller authorized for `addFeeds` and `withdrawTreasury`. The money / governance key.
    ///         Funds operations, maintenance, and version support. Strongly recommended to be
    ///         a multisig (or DAO treasury) in production.
    address public immutable TREASURY;
    /// @notice Guardian address — the emergency circuit-breaker, authorized for `setPaused` ONLY.
    ///         Deliberately split from TREASURY so the key that can halt the protocol is not the key
    ///         that holds fees. Recommended to be a separate (fast) ops multisig, distinct from
    ///         TREASURY and from any operational keeper EOA.
    address public immutable GUARDIAN;
    /// @notice Emergency stop. When true, blocks new evals, deposits, claims, and trade-opens.
    ///         Withdrawals, closes, cancels, and keeper sweeps remain callable so users can always exit.
    bool public paused;

    /// @notice Flat USDC fee paid to start an evaluation (non-refundable). Goes to the LP pool.
    uint256 public immutable EVAL_FEE;
    /// @notice Reference notional for funded-trader UX. Real cap is computed dynamically by `effectiveCap`.
    uint256 public immutable FUNDED_ALLOCATION;
    /// @notice Number of blocks an eval lasts before `expireEval` is callable. Set to map ~30 days at 2s blocks.
    uint256 public immutable EVAL_DURATION;
    /// @notice USDC required to claim funded status after passing eval. Becomes the trader's starting deposit.
    uint256 public immutable TRADER_DEPOSIT;
    /// @notice Hard cap on simultaneous funded traders. Excess claimers go to the FIFO queue.
    uint256 public immutable MAX_FUNDED_TRADERS;

    /// @notice Eval pass target — virtualBalance must reach 1e18 + EVAL_PROFIT_BPS bps to pass (8% by default).
    uint256 internal constant EVAL_PROFIT_BPS = 800;
    /// @notice Max peak-to-trough drawdown allowed during eval before failure (5% by default).
    uint256 internal constant EVAL_DRAWDOWN_BPS = 500;
    /// @notice Trader's share of profit on a funded settlement (80%). Compounds into deposit.
    uint256 internal constant TRADER_PROFIT_BPS = 8000;
    /// @notice Treasury's share of profit on a funded settlement (5%). Accrued to
    ///         `treasuryBalance`; pulled by the TREASURY address via `withdrawTreasury`.
    uint256 internal constant TREASURY_FEE_BPS = 500;
    // Remaining 15% (10000 - TRADER_PROFIT_BPS - TREASURY_FEE_BPS) implicitly goes to the LP pool.

    /// @notice Hard upper bound on any per-feed staleness window. Even a slow feed shouldn't
    ///         sit older than this before we treat it as unusable for normal trades.
    uint256 internal constant ORACLE_MAX_STALE = 48 hours;
    /// @notice Minimum heartbeat we accept at install — any feed declared with a heartbeat
    ///         shorter than this is treated as misconfiguration.
    uint256 internal constant ORACLE_MIN_STALE = 5 minutes;
    /// @notice Target decimal scale for prices used in PnL math (1e8). Every wired feed must
    ///         report at this exact expo — pinning here keeps _tryReadSpot branch-free.
    int32   internal constant TARGET_PRICE_EXPO = -8;
    /// @notice Reject oracle reads where Pyth's confidence interval is wider than 0.5% of price.
    ///         Wide conf usually means publishers disagree (illiquidity, news event) — opening
    ///         or closing positions during these windows lets the trader pick a side of the spread.
    uint256 internal constant MAX_CONF_BPS = 50;

    /// @notice Minimum LP deposit (1 USDC) — prevents dust-share griefing.
    uint256 internal constant MIN_DEPOSIT = 1e6;
    /// @notice Minimum number of closed trades required for an eval to pass.
    uint256 internal constant MIN_EVAL_TRADES = 3;
    /// @notice Minimum blocks an eval virtual position must remain open before close (10 blocks ≈ 20s).
    uint256 internal constant MIN_TRADE_BLOCKS = 10;
    /// @notice Minimum blocks between successful eval cancels (audit I-6). Caps the rate at which
    ///         a compromised agent key can drain a principal's USDC via cancel-restart loops.
    uint256 internal constant EVAL_CANCEL_COOLDOWN = 100;
    /// @notice First-deposit shares burned to address(0) — prevents inflation attacks on the share price.
    uint256 internal constant DEAD_SHARES = 1000;
    /// @notice Cap on per-trade price move used in PnL calculation (50%). Bounds counterparty risk
    ///         in a single black-swan settlement.
    uint256 internal constant CIRCUIT_BREAKER_BPS = 5000;
    /// @notice Hard cap on leverage for any single trade. Higher tiers are level-gated.
    uint8   internal constant MAX_LEVERAGE = 10;
    /// @notice Hard cap on how long a position can stay open. After this, anyone can call
    ///         forceClose to settle the position at current spot. Stops zombie positions from
    ///         sitting open indefinitely against the pool's deployed capital. ~14 days at 2s
    ///         blocks (Base deployment target).
    uint256 internal constant MAX_POSITION_BLOCKS = 604_800;

    /// @notice Transient-storage slot for the nonReentrant guard (Cancun TLOAD/TSTORE).
    bytes32 internal constant REENTRANCY_SLOT = keccak256("propfund.reentrancy");

    /*//////////////////////////////////////////////////////////////
                          MULTI-ASSET ORACLES (Pyth)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pyth Network contract that aggregates signed price updates.
    IPyth public immutable PYTH;

    /// @notice Per-asset Pyth price feed IDs. assetId -> bytes32 price ID.
    mapping(uint8 => bytes32) public priceIds;
    /// @notice Per-asset staleness ceiling in seconds. _tryReadSpot rejects updates older than this.
    mapping(uint8 => uint256) public oracleStaleAfter;
    /// @notice Number of feeds installed. assetIds run 0..assetCount-1.
    uint8 public assetCount;

    /// @notice Push fresh signed Pyth price updates on-chain. Anyone can call. Forwards
    ///         msg.value to Pyth for the per-feed update fee. Caller should size msg.value
    ///         via PYTH.getUpdateFee(updateData) — excess is kept by Pyth.
    /// @param updateData Hermes-signed VAA bundle (one binary blob, multiple price feeds).
    function pushPyth(bytes[] calldata updateData) external payable {
        PYTH.updatePriceFeeds{value: msg.value}(updateData);
    }

    /// @notice Register Pyth price feeds. Only TREASURY. Batch. Append-only.
    /// @param ids Pyth bytes32 price IDs.
    /// @param staleAfter Per-feed staleness ceiling in seconds.
    function addFeeds(bytes32[] calldata ids, uint256[] calldata staleAfter) external {
        if (msg.sender != TREASURY) revert NotTreasury();
        if (ids.length != staleAfter.length) revert InvalidSize();
        if (uint256(assetCount) + ids.length > type(uint8).max) revert TooManyFeeds();
        for (uint256 i = 0; i < ids.length; i++) {
            _installFeed(ids[i], staleAfter[i]);
        }
    }

    /// @notice Emitted whenever the pause flag flips.
    event PauseSet(bool paused);

    /// @notice Emergency pause / unpause. Guardian-gated (separate from the fee/treasury key).
    ///         Doesn't block exits — users can always withdraw, close trades, cancel evals, and run
    ///         the keeper even while paused.
    /// @param p True to pause, false to unpause.
    function setPaused(bool p) external {
        if (msg.sender != GUARDIAN) revert NotGuardian();
        paused = p;
        emit PauseSet(p);
    }

    /// @notice Pull all accrued treasury fees in one shot. TREASURY-only. CEI-clean
    ///         (treasuryBalance zeroed before transfer); no nonReentrant needed since
    ///         TREASURY is trusted and a re-entrant second call would see treasuryBalance == 0
    ///         and revert. Reverts ZeroAmount if empty.
    function withdrawTreasury() external {
        if (msg.sender != TREASURY) revert NotTreasury();
        uint256 amount = treasuryBalance;
        if (amount == 0) revert ZeroAmount();
        treasuryBalance = 0;
        USDC.safeTransfer(TREASURY, amount);
    }


    function _installFeed(bytes32 priceId, uint256 staleAfter) internal {
        if (priceId == bytes32(0)) revert ZeroAddress();
        if (staleAfter < ORACLE_MIN_STALE || staleAfter > ORACLE_MAX_STALE) revert InvalidSize();

        // Validate live: feed must exist, must report at the canonical -8 expo PropFund uses for
        // all PnL math, and must already have a positive published price. Pinning to one expo
        // means _tryReadSpot doesn't need branching normalization — saves contract size.
        IPyth.Price memory p = PYTH.getPriceUnsafe(priceId);
        if (p.expo != TARGET_PRICE_EXPO) revert InvalidAsset();
        if (p.publishTime == 0) revert StaleOracle();
        if (p.price <= 0) revert NegativePrice();

        priceIds[assetCount] = priceId;
        oracleStaleAfter[assetCount] = staleAfter;
        unchecked { assetCount += 1; }
    }

    /*//////////////////////////////////////////////////////////////
                          LP STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Total LP shares outstanding (DEAD_SHARES + sum of `shares[lp]`).
    uint256 public totalShares;
    /// @notice LP share balance per address.
    mapping(address => uint256) public shares;
    /// @notice Idle USDC held by the pool (not currently deployed in trades, not escrowed for queue).
    uint256 public poolBalance;
    /// @notice Sum of `usdcDeployed` across all open funded positions.
    uint256 public totalDeployed;
    /// @notice Treasury fees accrued from settlements, pending TREASURY pull. Pull-pattern
    ///         (audit M-3 applied to the treasury-fee path) — keeps profitable settlement
    ///         paths from reverting if TREASURY's USDC transfer ever fails (blacklist, a
    ///         contract receiver that reverts, etc).
    uint256 public treasuryBalance;

    /*//////////////////////////////////////////////////////////////
                          EVAL STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-trader evaluation state. Drives the eval state machine.
    /// @param virtualBalance Compounded P&L since eval start (1e18 = breakeven; 1.08e18 = pass at 8%).
    /// @param highWaterMark Peak virtualBalance ever observed — used to compute drawdown from peak.
    /// @param entryPrice Pyth 1e8-scale entry of the open virtual long; 0 when no trade is open.
    /// @param startBlock block.number at startEval.
    /// @param tradeOpenBlock block.number at the most recent openEvalTrade.
    /// @param tradeCount Closed-trade count (used for the MIN_EVAL_TRADES pass criterion).
    /// @param active True between startEval and pass/fail/cancel/expire.
    /// @param passed True after pass criteria met; cleared on claimFunding.
    /// @param assetId Asset id of the currently-open virtual trade. Picked per-trade.
    struct EvalAccount {
        uint256 virtualBalance;
        uint256 highWaterMark;
        uint64 entryPrice;
        uint32 startBlock;
        uint32 tradeOpenBlock;
        uint16 tradeCount;
        bool active;
        bool passed;
        uint8 assetId;
    }
    /// @notice Eval state per trader.
    mapping(address => EvalAccount) public evals;
    /// @notice Last block at which `actor` cancelled an eval. Backs EVAL_CANCEL_COOLDOWN.
    mapping(address => uint32) internal lastEvalCancelBlock;

    /*//////////////////////////////////////////////////////////////
                        FUNDED STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-trader funded state.
    /// @param active        True between claimFunding and resign/revoke.
    /// @param cumulativePnl Lifetime PnL across all closed trades (drives leverage tier).
    /// @param deposit       Current USDC deposit (compounds with profits, decreases on losses).
    /// @param lastLevel     Highest leverage tier ever reached — used to gate LEVEL_UP NFT mints.
    struct FundedAccount {
        bool active;
        int256 cumulativePnl;
        uint256 deposit;
        uint8 lastLevel;
    }
    /// @notice Funded state per trader.
    mapping(address => FundedAccount) public funded;

    /// @notice Per-trader open position. At most one position per trader.
    /// @param usdcDeployed Notional (= margin × leverage). PnL is computed against this.
    /// @param entryPrice   Pyth 1e8-scale entry. Used for PnL.
    /// @param tpPrice      Take-profit price (1e8). Mandatory at open. executeExit triggers when crossed.
    /// @param slPrice      Stop-loss price (1e8). Mandatory at open. executeExit triggers when crossed.
    /// @param margin       At-risk capital for this trade. Loss is capped here — remaining
    ///                     (deposit - margin) survives any single blowup.
    /// @param assetId      Asset traded (0..assetCount-1).
    /// @param active       True while the position is open.
    /// @param isShort      Direction: true = short, false = long.
    /// @param openBlock    block.number at openTrade — drives MAX_POSITION_BLOCKS expiry / forceClose.
    struct TraderPosition {
        uint256 usdcDeployed;
        uint64 entryPrice;
        uint64 tpPrice;
        uint64 slPrice;
        uint64 margin;
        uint8 assetId;
        bool active;
        bool isShort;
        uint32 openBlock;
    }
    /// @notice Open positions per trader.
    mapping(address => TraderPosition) public positions;

    /// @notice Lifetime trade record per trader. Populated on every closed funded trade.
    struct TraderRecord {
        uint32 wins;
        uint32 losses;
        uint256 totalProfit;
        uint256 totalLoss;
    }
    /// @notice Lifetime stats per trader.
    mapping(address => TraderRecord) public records;

    /// @notice Highest leverage tier a trader has EVER reached — gates LEVEL_UP NFT mints so a
    ///         demote-then-re-promote (bidirectional `lastLevel`) doesn't re-mint a cert already earned.
    ///         Monotonic; never decreases.
    mapping(address => uint8) public maxLevelMinted;

    /// @notice Active funded traders. Length capped at MAX_FUNDED_TRADERS. Indexed via fundedTraderIdx.
    address[] public fundedTraders;
    /// @dev 1-indexed; 0 = not in fundedTraders. Used for O(1) removal during resign/revoke.
    mapping(address => uint256) internal fundedTraderIdx;

    /// @notice Cert NFT contract. Minted on EVAL_PASS and LEVEL_UP. Fully on-chain SVG art.
    EvalCert public immutable CERT;

    /*//////////////////////////////////////////////////////////////
                       FUNDING QUEUE STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice FIFO queue of traders who passed eval but were waiting for capacity at claim time.
    /// Each queued trader has their TRADER_DEPOSIT escrowed until either funded by
    /// processFundingQueue or refunded via leaveFundingQueue. Append-only with a moving head
    /// (fundingQueueHead): dequeue and leave are O(1) — vacated slots are zeroed in place
    /// (lazy tombstones) and skipped on drain, never front-shifted.
    address[] public fundingQueue;
    /// @notice Index of the queue front in `fundingQueue`. Live queue is the non-zero entries
    /// in fundingQueue[fundingQueueHead..length).
    uint256 public fundingQueueHead;
    /// @dev Absolute 1-based index into fundingQueue (array index + 1); 0 = not in queue.
    mapping(address => uint256) internal queueIdx;
    /// @notice Sum of escrowed TRADER_DEPOSITs awaiting funding. Tracked separately from
    /// poolBalance so LP accounting isn't polluted by transient escrow.
    uint256 public queuedDeposits;

    /*//////////////////////////////////////////////////////////////
                    AGENT DELEGATION (CONTROLLERS)
    //////////////////////////////////////////////////////////////*/

    /// @notice A principal can authorize an agent address to act on their behalf for the full
    /// trader lifecycle (eval, funding, trades, withdraws). Funds flow to/from the principal —
    /// the agent never holds value. Budget is enforced via the principal's USDC allowance to
    /// the contract. Per-trade notional is bounded explicitly.
    struct Authorization {
        address agent;
        uint128 maxNotionalPerTrade;
        uint64 expiry;  // unix timestamp; agent loses authority when block.timestamp >= expiry
    }
    mapping(address => Authorization) public controllers;

    /// @notice Authorize an agent to drive the caller's full trader lifecycle.
    /// @param agent The address that will act on the principal's behalf.
    /// @param maxNotionalPerTrade Hard upper bound on each openTrade the agent submits.
    /// @param expiry Unix timestamp after which the authorization is dead.
    function setController(address agent, uint128 maxNotionalPerTrade, uint64 expiry) external {
        if (agent == address(0) || expiry <= block.timestamp) revert InvalidAuthorization();
        controllers[msg.sender] = Authorization({
            agent: agent,
            maxNotionalPerTrade: maxNotionalPerTrade,
            expiry: expiry
        });
        emit ControllerSet(msg.sender, agent, maxNotionalPerTrade, expiry);
    }

    /// @notice Revoke any authorization. Open positions and funded status are unaffected —
    /// the principal can still act on themselves; only the agent's authority is killed.
    function revokeController() external {
        delete controllers[msg.sender];
        emit ControllerRevoked(msg.sender);
    }

    /// @dev Verifies msg.sender is the active agent for `principal`.
    function _checkController(address principal) internal view {
        Authorization memory a = controllers[principal];
        if (a.agent == address(0) || a.agent != msg.sender) revert NotAuthorized();
        if (block.timestamp >= a.expiry) revert AuthorizationExpired();
    }

    /*//////////////////////////////////////////////////////////////
                            REENTRANCY
    //////////////////////////////////////////////////////////////*/

    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        uint256 v;
        assembly { v := tload(slot) }
        if (v != 0) revert Reentrancy();
        assembly { tstore(slot, 1) }
        _;
        assembly { tstore(slot, 0) }
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    struct Config {
        IERC20 usdc;
        IPyth pyth;             // Pyth Network contract on the deployed chain.
        address treasury;       // fee recipient + addFeeds + cert owner (money / governance key).
        address guardian;       // emergency pause only — must differ from treasury in production.
        uint256 evalFee;
        uint256 fundedAllocation;
        uint256 evalDuration;
        uint256 traderDeposit;
        uint256 maxFundedTraders;
        bytes32[] priceIds;     // Pyth price feed IDs. Index 0 = eval asset.
        uint256[] staleAfter;   // Parallel array — max staleness in seconds per feed.
    }

    constructor(Config memory c) {
        if (address(c.usdc) == address(0)) revert ZeroAddress();
        if (address(c.pyth) == address(0)) revert ZeroAddress();
        if (c.treasury == address(0)) revert ZeroAddress();
        if (c.guardian == address(0)) revert ZeroAddress();
        if (c.evalFee == 0 || c.fundedAllocation == 0) revert ZeroAmount();
        if (c.evalDuration == 0 || c.traderDeposit == 0 || c.maxFundedTraders == 0) revert ZeroAmount();
        if (c.priceIds.length == 0) revert ZeroAmount();
        if (c.priceIds.length > type(uint8).max) revert TooManyFeeds();
        if (c.priceIds.length != c.staleAfter.length) revert InvalidSize();

        USDC = c.usdc;
        PYTH = c.pyth;
        TREASURY = c.treasury;
        GUARDIAN = c.guardian;
        EVAL_FEE = c.evalFee;
        FUNDED_ALLOCATION = c.fundedAllocation;
        EVAL_DURATION = c.evalDuration;
        TRADER_DEPOSIT = c.traderDeposit;
        MAX_FUNDED_TRADERS = c.maxFundedTraders;

        // Same _installFeed validation as addFeeds — every wired feed must exist + have sane expo.
        for (uint256 i = 0; i < c.priceIds.length; i++) {
            _installFeed(c.priceIds[i], c.staleAfter[i]);
        }

        // Cert NFT — admin = treasury so the renderer can be hot-swapped without redeploying
        // PropFund.
        CERT = new EvalCert(c.treasury);
    }

    /*//////////////////////////////////////////////////////////////
                        LP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit USDC into the LP pool, receiving shares prorata.
    /// @param amount USDC to deposit (>= MIN_DEPOSIT, 6 decimals).
    function deposit(uint256 amount) external nonReentrant {
        if (paused) revert Paused();
        if (amount < MIN_DEPOSIT) revert ZeroAmount();

        USDC.safeTransferFrom(msg.sender, address(this), amount);

        uint256 sharesToMint;
        if (totalShares == 0) {
            sharesToMint = amount - DEAD_SHARES;
            totalShares = DEAD_SHARES;
        } else {
            sharesToMint = (amount * totalShares) / poolValue();
        }

        unchecked {
            totalShares += sharesToMint;
            poolBalance += amount;
        }
        shares[msg.sender] += sharesToMint;

        emit Deposited(msg.sender, amount, sharesToMint);
    }

    /// @notice Burn LP shares and withdraw the prorata pool value in USDC.
    /// @param shareAmount Number of shares to burn.
    function withdraw(uint256 shareAmount) external nonReentrant {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[msg.sender] < shareAmount) revert NoShares();

        uint256 payout = (shareAmount * poolValue()) / totalShares;
        if (payout == 0) revert ZeroAmount();
        if (payout > poolBalance) revert InsufficientPool();

        unchecked {
            shares[msg.sender] -= shareAmount;
            totalShares -= shareAmount;
            poolBalance -= payout;
        }

        USDC.safeTransfer(msg.sender, payout);
        emit Withdrawn(msg.sender, payout, shareAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        EVALUATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay EVAL_FEE in USDC and begin a new evaluation. Caller must have approved
    ///         this contract for at least EVAL_FEE. Eval starts with virtualBalance = 1e18
    ///         and runs for EVAL_DURATION blocks. Asset is picked per-trade via openEvalTrade.
    /// @dev Reverts with AlreadyInEval if the caller is mid-eval, EvalPassPending if their
    ///      previous eval passed but they haven't claimed funding yet, or Paused.
    function startEval() external nonReentrant {
        _startEval(msg.sender);
    }

    /// @notice Delegated variant of startEval — called by an authorized agent on behalf of
    ///         the principal. The principal pays the eval fee from their wallet.
    /// @param principal The address whose eval is being started.
    /// @dev Reverts with NotAuthorized if msg.sender isn't the principal's controller, or
    ///      AuthorizationExpired if the controller's expiry has passed.
    function startEvalFor(address principal) external nonReentrant {
        _checkController(principal);
        _startEval(principal);
    }

    function _startEval(address actor) internal {
        if (paused) revert Paused();
        EvalAccount storage e = evals[actor];
        if (e.active) revert AlreadyInEval();
        if (e.passed) revert EvalPassPending();

        USDC.safeTransferFrom(actor, address(this), EVAL_FEE);
        unchecked { poolBalance += EVAL_FEE; }

        evals[actor] = EvalAccount({
            virtualBalance: 1e18,
            highWaterMark: 1e18,
            entryPrice: 0,
            startBlock: uint32(block.number),
            tradeOpenBlock: 0,
            tradeCount: 0,
            active: true,
            passed: false,
            assetId: 0
        });

        emit EvalStarted(actor);
    }

    /// @notice Open a virtual long position on the chosen asset at current spot.
    /// @param assetId Index into priceIds (0..assetCount-1). The asset is locked for this
    ///        single trade and used at close for accounting; next trade can rotate.
    /// @dev Eval is long-only by protocol — no isShort arg. PnL is multiplicative on
    ///      virtualBalance, never compounds beyond the EVAL_DRAWDOWN_BPS floor.
    ///      Reverts: NotInEval, EvalPositionOpen (already in trade), InvalidSize (bad
    ///      assetId), EvalExpired, Paused.
    function openEvalTrade(uint8 assetId) external nonReentrant {
        _openEvalTrade(msg.sender, assetId);
    }

    /// @notice Delegated variant of openEvalTrade — the agent opens on principal's behalf.
    /// @param principal The eval owner.
    /// @param assetId Listed asset index for this trade.
    function openEvalTradeFor(address principal, uint8 assetId) external nonReentrant {
        _checkController(principal);
        _openEvalTrade(principal, assetId);
    }

    function _openEvalTrade(address actor, uint8 assetId) internal {
        if (paused) revert Paused();
        EvalAccount storage e = evals[actor];
        if (!e.active) revert NotInEval();
        if (e.entryPrice != 0) revert EvalPositionOpen();
        if (assetId >= assetCount) revert InvalidSize();
        // Inclusive: at exact deadline, expireEval is already callable. Don't open new trades.
        if (block.number >= e.startBlock + EVAL_DURATION) revert EvalExpired();

        uint256 spot = _readSpot(assetId);
        e.entryPrice = uint64(spot);
        e.tradeOpenBlock = uint32(block.number);
        e.assetId = assetId;

        emit EvalTradeOpened(actor, spot);
    }

    /// @notice Settle the virtual position. Updates virtualBalance multiplicatively
    ///         (close/entry), updates highWaterMark on a new high, and checks pass/fail
    ///         conditions. If virtualBalance ≥ 1e18 + EVAL_PROFIT_BPS AND tradeCount ≥
    ///         MIN_EVAL_TRADES → eval passed and an EVAL_PASS NFT is minted. If drawdown
    ///         from peak ≥ EVAL_DRAWDOWN_BPS → eval failed.
    /// @dev Trade must have been open ≥ MIN_TRADE_BLOCKS unless eval has expired.
    ///      Reverts: NotInEval, EvalNoPosition, TradeTooShort, StaleOracle.
    function closeEvalTrade() external nonReentrant {
        _closeEvalTrade(msg.sender);
    }

    /// @notice Delegated variant of closeEvalTrade.
    /// @param principal The eval owner.
    function closeEvalTradeFor(address principal) external nonReentrant {
        _checkController(principal);
        _closeEvalTrade(principal);
    }

    function _closeEvalTrade(address actor) internal {
        EvalAccount storage e = evals[actor];
        if (!e.active) revert NotInEval();
        if (e.entryPrice == 0) revert EvalNoPosition();

        bool expired = block.number > e.startBlock + EVAL_DURATION;
        if (!expired && block.number < e.tradeOpenBlock + MIN_TRADE_BLOCKS) revert TradeTooShort();

        uint256 spot = _readSpot(e.assetId);
        uint256 entry = uint256(e.entryPrice);

        e.virtualBalance = (e.virtualBalance * spot) / entry;
        e.entryPrice = 0;
        unchecked { e.tradeCount += 1; }

        if (e.virtualBalance > e.highWaterMark) {
            e.highWaterMark = e.virtualBalance;
        }

        int256 returnBps = (int256(spot) - int256(entry)) * 10_000 / int256(entry);
        int256 cumulativeBps = (int256(e.virtualBalance) - 1e18) * 10_000 / 1e18;

        if (e.virtualBalance * 10_000 <= e.highWaterMark * (10_000 - EVAL_DRAWDOWN_BPS)) {
            e.active = false;
            emit EvalFailedEvent(actor, cumulativeBps);
            emit EvalTradeClosed(actor, returnBps, cumulativeBps);
            return;
        }

        if (e.virtualBalance * 10_000 >= 1e18 * (10_000 + EVAL_PROFIT_BPS)
            && e.tradeCount >= MIN_EVAL_TRADES) {
            e.passed = true;
            e.active = false;
            try CERT.mint(actor, e.virtualBalance, EvalCert.CertType.EVAL_PASS, 0) {}
            catch { emit CertMintFailed(actor, uint8(EvalCert.CertType.EVAL_PASS), e.virtualBalance, 0); }
            emit EvalPassed(actor);
            emit EvalTradeClosed(actor, returnBps, cumulativeBps);
            return;
        }

        if (expired) {
            e.active = false;
            emit EvalFailedEvent(actor, cumulativeBps);
            emit EvalTradeClosed(actor, returnBps, cumulativeBps);
            return;
        }

        emit EvalTradeClosed(actor, returnBps, cumulativeBps);
    }

    /// @notice Voluntarily abandon an active evaluation. The EVAL_FEE is non-refundable.
    /// @dev Reverts CancelCooldown if called within EVAL_CANCEL_COOLDOWN blocks of the
    ///      previous cancel — caps rate at which a compromised agent can drain principal
    ///      USDC via cancel-restart loops (audit I-6). First cancel ever is always allowed.
    function cancelEval() external nonReentrant {
        _cancelEval(msg.sender);
    }

    // cancelEvalFor not exposed: principal can cancel themselves; eval expires naturally too.

    function _cancelEval(address actor) internal {
        EvalAccount storage e = evals[actor];
        if (!e.active) revert NotInEval();
        // Throttle rapid cancel-restart loops (audit I-6). First cancel always passes; subsequent
        // cancels must wait EVAL_CANCEL_COOLDOWN blocks. Caps the rate at which a compromised
        // agent key can drain a principal's USDC.
        uint32 lastCancel = lastEvalCancelBlock[actor];
        if (lastCancel != 0 && block.number < uint256(lastCancel) + EVAL_CANCEL_COOLDOWN) revert CancelCooldown();
        lastEvalCancelBlock[actor] = uint32(block.number);

        int256 cumulativeBps = (int256(e.virtualBalance) - 1e18) * 10_000 / 1e18;
        e.active = false;
        e.entryPrice = 0;
        emit EvalFailedEvent(actor, cumulativeBps);
    }

    /// @notice Permissionless: expire an eval whose deadline has passed.
    /// @param trader The eval owner to expire.
    function expireEval(address trader) external nonReentrant {
        EvalAccount storage e = evals[trader];
        if (!e.active) revert NotInEval();
        // Use strict-or-equal here so the boundary between "blocks left = 0" (UI) and
        // "expirable" (state machine) match exactly.
        if (block.number < e.startBlock + EVAL_DURATION) revert EvalNotExpired();
        int256 cumulativeBps = (int256(e.virtualBalance) - 1e18) * 10_000 / 1e18;
        e.active = false;
        e.entryPrice = 0;
        emit EvalFailedEvent(trader, cumulativeBps);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNDED TRADING
    //////////////////////////////////////////////////////////////*/

    /// @notice After passing eval, pay TRADER_DEPOSIT and become a funded trader. If pool
    ///         capacity (poolBalance ≥ 2× TRADER_DEPOSIT) or the funded-trader cap (
    ///         MAX_FUNDED_TRADERS) is exhausted, the deposit is escrowed and the caller is
    ///         queued FIFO. Anyone can call processFundingQueue() to drain the queue when
    ///         capacity opens.
    /// @dev Reverts: AlreadyFunded, AlreadyQueued, EvalNotPassed, Paused.
    function claimFunding() external nonReentrant {
        _claimFunding(msg.sender);
    }

    /// @notice Delegated variant of claimFunding.
    /// @param principal The eval-passer claiming funded status.
    function claimFundingFor(address principal) external nonReentrant {
        _checkController(principal);
        _claimFunding(principal);
    }

    function _claimFunding(address actor) internal {
        if (paused) revert Paused();
        FundedAccount storage f = funded[actor];
        // Check active funded status first so already-funded users get a clear error rather
        // than the confusing "EvalNotPassed" they'd see after their eval flag was consumed.
        if (f.active) revert AlreadyFunded();
        if (queueIdx[actor] != 0) revert AlreadyQueued();

        EvalAccount storage e = evals[actor];
        if (!e.passed) revert EvalNotPassed();

        bool hasCapacity = poolBalance >= TRADER_DEPOSIT * 2 && fundedTraders.length < MAX_FUNDED_TRADERS;
        if (hasCapacity) {
            e.passed = false;
            USDC.safeTransferFrom(actor, address(this), TRADER_DEPOSIT);
            _markFunded(actor);
            emit FundingClaimed(actor, FUNDED_ALLOCATION);
        } else {
            // Queue is unbounded; spam is gated by the eval fee + escrowed deposit. processFundingQueue
            // is bounded per-call by its `max` parameter so a long queue can't brick advancement.
            USDC.safeTransferFrom(actor, address(this), TRADER_DEPOSIT);
            unchecked { queuedDeposits += TRADER_DEPOSIT; }
            fundingQueue.push(actor);
            queueIdx[actor] = fundingQueue.length; // absolute 1-based slot
            emit FundingQueued(actor, fundingQueue.length);
        }
    }

    function _markFunded(address trader) internal {
        // Initial lastLevel = 2 matches _leverageLevel(0) — the implicit baseline tier for
        // any funded trader. This prevents a spurious "level-up to 2" NFT on the trader's
        // first profit, and (critically) ensures every levelChanged event has newLevel ≥ 3,
        // which requires cumulativePnl ≥ 50e6. That makes the int256→uint256 cast on the
        // cert's `value` field safe — without this, a trader who loses first then recovers
        // slightly (cumPnl still negative) would mint a LEVEL_UP cert with a garbage value.
        funded[trader] = FundedAccount({
            active: true,
            cumulativePnl: 0,
            deposit: TRADER_DEPOSIT,
            lastLevel: 2
        });
        // Baseline NFT high-water = 2, matching lastLevel — so the first profit at the baseline tier
        // doesn't mint a spurious "level-up to 2" cert. Only genuine ≥3 crossings mint.
        if (maxLevelMinted[trader] < 2) maxLevelMinted[trader] = 2;
        fundedTraders.push(trader);
        fundedTraderIdx[trader] = fundedTraders.length;
    }

    /// @notice Drain the funding queue while the pool has capacity. Anyone can call.
    /// @param max Maximum queue slots to process this call (gas guard). Bounds both funded
    ///        advances and skips of vacated (left) slots, so one call is always gas-bounded.
    /// @dev O(1) per slot: the front pointer (fundingQueueHead) advances and vacated slots are
    ///      skipped — no array front-shift. Liveness holds across calls because the head pointer
    ///      is persisted, so a later call resumes exactly where this one stopped.
    function processFundingQueue(uint256 max) external nonReentrant {
        uint256 head = fundingQueueHead;
        uint256 len = fundingQueue.length;
        for (uint256 steps; steps < max && head < len; steps++) {
            address h = fundingQueue[head];
            if (h == address(0)) {
                // Slot vacated by leaveFundingQueue — skip it (costs one step).
                unchecked { head++; }
                continue;
            }
            if (poolBalance < TRADER_DEPOSIT * 2) break;
            if (fundedTraders.length >= MAX_FUNDED_TRADERS) break;

            delete fundingQueue[head];
            delete queueIdx[h];
            unchecked { head++; queuedDeposits -= TRADER_DEPOSIT; }

            evals[h].passed = false;
            _markFunded(h);
            emit FundingClaimed(h, FUNDED_ALLOCATION);
        }
        fundingQueueHead = head;
    }

    /// @notice Refund the escrowed TRADER_DEPOSIT and remove the caller from the funding queue.
    /// @dev Reverts NotInQueue if the caller isn't queued. The trader's eval-passed flag is
    ///      preserved — they can rejoin via claimFunding() later.
    function leaveFundingQueue() external nonReentrant {
        _leaveFundingQueue(msg.sender);
    }

    // leaveFundingQueueFor not exposed: principal can leave themselves.

    function _leaveFundingQueue(address actor) internal {
        uint256 idx = queueIdx[actor];
        if (idx == 0) revert NotQueued();

        // O(1) tombstone: zero the leaver's slot in place. Drain (processFundingQueue) and the
        // queuePosition view skip zeroed slots, so order is preserved without front-shifting.
        delete fundingQueue[idx - 1];
        delete queueIdx[actor];

        unchecked { queuedDeposits -= TRADER_DEPOSIT; }
        emit FundingQueueLeft(actor);

        // INTERACTION last — refund. Safe because state is fully updated. Refund goes to actor
        // (the principal); agent never holds value.
        USDC.safeTransfer(actor, TRADER_DEPOSIT);
    }

    /// @notice Open a funded position with explicit margin sizing, leverage, and mandatory
    ///         take-profit + stop-loss exits.
    /// @dev Margin model: a trade can post up to 50% of deposit as at-risk capital. Loss on
    ///      the trade is capped at this margin, so the other 50% always survives a single
    ///      blowup. Notional = margin * leverage; PnL computed on notional and capped at
    ///      ±CIRCUIT_BREAKER_BPS to bound counterparty risk per settlement. Reverts:
    ///      NotFunded, TraderPositionOpen, InvalidSize (sizeBps/leverage), InsufficientPool
    ///      (notional > effectiveCap), InvalidExit (tp or sl missing or wrong-sided),
    ///      StaleOracle (Pyth conf too wide or stale), Paused.
    /// @param assetId  Index into priceIds (0..assetCount-1).
    /// @param sizeBps  Margin as basis points of (deposit/2). 10000 = full 50% of deposit.
    /// @param isShort  True for short, false for long.
    /// @param tp       Take-profit price (Pyth 1e8 scale). MANDATORY. Long: tp > entry. Short: tp < entry.
    /// @param sl       Stop-loss price (Pyth 1e8 scale). MANDATORY. Must be on the loss side of tp.
    ///                 SL is allowed past entry (trailing/breakeven stop).
    /// @param leverage Integer 1..MAX_LEVERAGE. Higher tiers gated by trader level.
    function openTrade(uint8 assetId, uint256 sizeBps, bool isShort, uint64 tp, uint64 sl, uint8 leverage) external nonReentrant {
        _openTrade(msg.sender, assetId, sizeBps, isShort, tp, sl, leverage);
    }

    /// @notice Delegated variant of openTrade. Authorized agent opens for principal and is
    ///         additionally bounded by controllers[principal].maxNotionalPerTrade.
    /// @param principal The position owner.
    /// @dev Reverts MaxNotionalExceeded if computed notional would exceed the agent's cap.
    function openTradeFor(
        address principal,
        uint8 assetId,
        uint256 sizeBps,
        bool isShort,
        uint64 tp,
        uint64 sl,
        uint8 leverage
    ) external nonReentrant {
        _checkController(principal);
        // Pre-compute the resulting notional so we can enforce the agent's per-trade cap before
        // mutating any state. _openTrade re-validates with the live deposit/cap math.
        FundedAccount storage f = funded[principal];
        if (f.active) {
            // Multiply before dividing — preserves precision when deposit is small.
            uint256 marginUsed = (f.deposit * sizeBps) / 20_000;
            uint256 notional = marginUsed * uint256(leverage);
            if (notional > uint256(controllers[principal].maxNotionalPerTrade)) revert MaxNotionalExceeded();
        }
        _openTrade(principal, assetId, sizeBps, isShort, tp, sl, leverage);
    }

    function _openTrade(address actor, uint8 assetId, uint256 sizeBps, bool isShort, uint64 tp, uint64 sl, uint8 leverage) internal {
        if (paused) revert Paused();
        if (assetId >= assetCount) revert InvalidAsset();

        FundedAccount storage f = funded[actor];
        if (!f.active) revert NotFunded();
        if (positions[actor].active) revert TraderPositionOpen();
        if (sizeBps == 0 || sizeBps > 10_000) revert InvalidSize();
        // Level gate (bidirectional): leverage is capped at the trader's current tier `lastLevel`.
        // lastLevel ratchets UP as cumulative PnL crosses milestones (+$50 → 3, +$150 → 5, +$400 → 8,
        // +$1000 → 10) AND resyncs DOWN to the live tier after a losing close (see _closeTrade) — so a
        // trader who draws their cumPnl back below a threshold is demoted. _leverageLevel is clamped at
        // MAX_LEVERAGE = 10, so this also enforces the hard cap.
        if (leverage == 0 || leverage > f.lastLevel) revert InvalidSize();

        // 50% margin rule: max margin per trade is half the deposit. The other half is always
        // preserved — even at max leverage and a circuit-breaker move, the trader walks away
        // with at least deposit/2.
        // Multiply before dividing — preserves precision when deposit is small.
        uint256 marginUsed = (f.deposit * sizeBps) / 20_000;
        if (marginUsed == 0) revert ZeroAmount();

        uint256 notional = marginUsed * uint256(leverage);
        // Fair partition: each funded trader's max notional is min(per-trader cap, pool/N).
        // Keeps any single trader from soaking up the whole pool and starving the rest.
        if (notional > _effectiveCapInternal(f.deposit)) revert InsufficientPool();

        uint256 entryPrice = _readSpot(assetId);
        _validateExit(uint64(entryPrice), tp, sl, isShort);

        unchecked {
            poolBalance -= notional;
            totalDeployed += notional;
        }

        positions[actor] = TraderPosition({
            usdcDeployed: notional,
            entryPrice: uint64(entryPrice),
            tpPrice: tp,
            slPrice: sl,
            margin: uint64(marginUsed),
            assetId: assetId,
            active: true,
            isShort: isShort,
            openBlock: uint32(block.number)
        });

        emit TradeOpened(actor, assetId, isShort, notional, entryPrice);
    }

    /// @notice Settle the position at the current Pyth price. Trader gets 80% of profit
    ///         (compounded into deposit), LP pool gets 15%, treasury accrues 5%.
    ///         Loss is absorbed by the position margin first, then the pool.
    /// @param closeBps Portion to close in basis points (10000 = full close, partials valid).
    /// @dev Reverts NoTraderPosition, ZeroAmount (dust round-down), InvalidSize, StaleOracle.
    function closeTrade(uint256 closeBps) external nonReentrant {
        if (closeBps == 0 || closeBps > 10_000) revert InvalidSize();
        _closeTrade(msg.sender, closeBps, false);
    }

    /// @notice Delegated variant of closeTrade.
    /// @param principal The position owner.
    /// @param closeBps Portion to close in basis points (10000 = full close).
    function closeTradeFor(address principal, uint256 closeBps) external nonReentrant {
        _checkController(principal);
        if (closeBps == 0 || closeBps > 10_000) revert InvalidSize();
        _closeTrade(principal, closeBps, false);
    }

    /// @notice Force-close the caller's full position even if Pyth is reporting stale data.
    ///         Last-known cached price is used. Lets a trader exit during oracle outages
    ///         instead of being trapped.
    /// @dev Always closes 10000 bps. Skips fresh-price guard. Same payout/loss waterfall.
    function emergencyClose() external nonReentrant {
        _closeTrade(msg.sender, 10_000, true);
    }

    // emergencyCloseFor not exposed: rare path, principal can call.

    /// @notice Modify the take-profit and stop-loss on the caller's open position. Useful
    ///         for trailing stops — after a position moves into profit, tighten SL toward
    ///         entry (or beyond, for breakeven lock).
    /// @param tp New take-profit price (Pyth 1e8 scale). MANDATORY (non-zero).
    /// @param sl New stop-loss price (Pyth 1e8 scale). MANDATORY (non-zero).
    /// @dev Validation matches openTrade: tp on profit side of entry; sl not inverted past tp.
    ///      Reverts NoTraderPosition, InvalidExit.
    function updateExit(uint64 tp, uint64 sl) external nonReentrant {
        _updateExit(msg.sender, tp, sl);
    }

    /// @notice Delegated variant of updateExit.
    /// @param principal The position owner.
    /// @param tp New take-profit price (Pyth 1e8 scale). Mandatory non-zero.
    /// @param sl New stop-loss price (Pyth 1e8 scale). Mandatory non-zero.
    function updateExitFor(address principal, uint64 tp, uint64 sl) external nonReentrant {
        _checkController(principal);
        _updateExit(principal, tp, sl);
    }

    function _updateExit(address actor, uint64 tp, uint64 sl) internal {
        TraderPosition storage pos = positions[actor];
        if (!pos.active) revert NoTraderPosition();
        _validateExit(pos.entryPrice, tp, sl, pos.isShort);
        pos.tpPrice = tp;
        pos.slPrice = sl;
    }

    /// @dev Sanity-check TP and SL when both are set. Single-sided exits (only TP or only SL)
    /// are unconstrained — the trader may want a trailing stop above entry on a long, or a
    /// breakeven SL after riding a position into profit. We only forbid the inverted case
    /// (TP and SL crossed), which would never make sense.
    /// @notice Both TP and SL mandatory on every funded trade. TP must be on the profit side
    /// of entry; SL must be on the loss side of TP (so they're not inverted). SL is allowed
    /// to drift toward entry (or past it) so traders can move stops to breakeven once a
    /// position is in profit. Liquidation remains the deeper failsafe.
    function _validateExit(uint64 entry, uint64 tp, uint64 sl, bool isShort) internal pure {
        if (tp == 0 || sl == 0) revert InvalidExit();
        if (!isShort) {
            // Long: tp above entry; sl below tp (sl can be ≥ entry — trailing/breakeven stop).
            if (tp <= entry || sl >= tp) revert InvalidExit();
        } else {
            // Short: tp below entry; sl above tp.
            if (tp >= entry || sl <= tp) revert InvalidExit();
        }
    }

    function _closeTrade(address trader, uint256 closeBps, bool emergency) internal {
        TraderPosition storage pos = positions[trader];
        if (!pos.active) revert NoTraderPosition();

        uint256 deployedPortion = (pos.usdcDeployed * closeBps) / 10_000;
        // Margin scales with the same fraction so partial closes free a proportional amount.
        uint256 marginPortion = (uint256(pos.margin) * closeBps) / 10_000;
        // Guard against dust closes that round to 0 — would silently spend gas with no settlement.
        if (deployedPortion == 0) revert ZeroAmount();

        // Oracle-settle: calculate PnL from price change
        uint256 spot;
        if (emergency) {
            (spot,) = _tryReadSpot(pos.assetId);
        } else {
            spot = _readSpot(pos.assetId);
        }

        int256 pnl = _calcPnl(deployedPortion, uint256(pos.entryPrice), spot, pos.isShort);

        FundedAccount storage f = funded[trader];
        f.cumulativePnl += pnl;

        unchecked {
            totalDeployed -= deployedPortion;
            pos.usdcDeployed -= deployedPortion;
            pos.margin -= uint64(marginPortion);
        }

        TraderRecord storage rec = records[trader];

        // CEI: zero out the position state BEFORE any external calls in _handleProfit.
        // No re-entrant view can see a half-settled position.
        if (closeBps == 10_000) {
            delete positions[trader];
        }

        if (pnl > 0) {
            // Trader won, pool pays. Pool gets back deployed - profit.
            uint256 profit = uint256(pnl);
            if (profit > deployedPortion) profit = deployedPortion; // cap at deployed
            unchecked { rec.wins += 1; rec.totalProfit += profit; }
            _handleProfit(trader, f, profit, deployedPortion);
        } else if (pnl < 0) {
            // Trader lost, pool receives. Loss is capped at the position's margin —
            // anything beyond is the pool's cost as counterparty.
            uint256 loss = uint256(-pnl);
            unchecked { rec.losses += 1; rec.totalLoss += loss; }
            _handleLoss(f, loss, deployedPortion, marginPortion);
            // Bidirectional scaling: a loss can drop cumulative PnL below a tier threshold, so resync
            // the leverage tier DOWN to the live level. (Profit ratchets it up in _handleProfit.)
            f.lastLevel = uint8(_leverageLevel(f.cumulativePnl));
        } else {
            unchecked { poolBalance += deployedPortion; }
        }

        emit TradeClosed(trader, deployedPortion, pnl);

        if (f.deposit < MIN_DEPOSIT) {
            if (pos.active && closeBps < 10_000) {
                _closeTrade(trader, 10_000, true);
                return;
            }
            _revokeFunding(trader, f);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT / LOSS (pool = counterparty)
    //////////////////////////////////////////////////////////////*/

    function _handleProfit(address trader, FundedAccount storage f, uint256 profit, uint256 deployed) internal {
        uint256 traderCut = (profit * TRADER_PROFIT_BPS) / 10_000;
        uint256 treasuryCut = (profit * TREASURY_FEE_BPS) / 10_000;
        uint256 lpCut = profit - traderCut - treasuryCut;

        // EFFECTS: write all state first. Profits compound into the deposit — traders pull via
        // withdrawProfit() when they want USDC. Pull-pattern eliminates DoS risk from receivers
        // that revert on transfer (audit M-3).
        f.deposit += traderCut;
        unchecked { poolBalance += deployed - profit + lpCut; }
        emit ProfitCompounded(trader, traderCut, f.deposit);
        uint8 newLevel = uint8(_leverageLevel(f.cumulativePnl));
        // Gate ratchet: lastLevel tracks the current tier (it resyncs down on losses in _closeTrade).
        if (newLevel > f.lastLevel) f.lastLevel = newLevel;
        // NFT gate: mint a LEVEL_UP cert only when reaching a NEW all-time-high tier, so a
        // demote-then-re-promote doesn't re-mint a cert already earned.
        bool levelChanged = newLevel > maxLevelMinted[trader];
        if (levelChanged) maxLevelMinted[trader] = newLevel;

        // Accrue treasury fee — pulled by TREASURY via withdrawTreasury(). Keeps profitable
        // settlement from reverting if TREASURY gets USDC-blacklisted or otherwise rejects
        // the transfer (audit M-3 pattern, applied to the treasury-fee path).
        unchecked { treasuryBalance += treasuryCut; }
        emit TreasuryFeeAccrued(trader, treasuryCut);

        // INTERACTIONS: cert mint last.
        if (levelChanged) {
            try CERT.mint(trader, uint256(f.cumulativePnl), EvalCert.CertType.LEVEL_UP, newLevel) {}
            catch { emit CertMintFailed(trader, uint8(EvalCert.CertType.LEVEL_UP), uint256(f.cumulativePnl), newLevel); }
            emit LevelUp(trader, newLevel);
        }
    }

    function _handleLoss(FundedAccount storage f, uint256 loss, uint256 deployed, uint256 margin) internal {
        // 50% margin rule: loss on this trade can never consume more than the position's
        // margin. The remaining (deposit - margin) is preserved no matter how badly this
        // trade goes. Anything beyond `margin` is the pool's cost as counterparty.
        uint256 absorbed = loss > margin ? margin : loss;
        unchecked {
            f.deposit -= absorbed;
            poolBalance += deployed + absorbed;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION / EXIT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless liquidation of a position whose unrealized loss has consumed
    ///         the position's margin. Last-line failsafe — the trader's explicit SL should
    ///         normally fire first; liquidation only catches gap moves where price skipped
    ///         the SL. Anyone can call (keepers compete on gas).
    /// @param trader The position owner to liquidate.
    /// @dev Re-checks isLiquidatable on-chain. Settles via emergency close (uses cached spot
    ///      if Pyth is stale). Reverts: NotFunded, NoTraderPosition, NotLiquidatable.
    function liquidate(address trader) external nonReentrant {
        FundedAccount storage f = funded[trader];
        if (!f.active) revert NotFunded();

        TraderPosition memory pos = positions[trader];
        if (!pos.active) revert NoTraderPosition();

        (uint256 spot,) = _tryReadSpot(pos.assetId);
        int256 pnl = _calcPnl(pos.usdcDeployed, uint256(pos.entryPrice), spot, pos.isShort);
        int256 unrealizedLoss = pnl < 0 ? -pnl : int256(0);

        // Liquidatable when the loss has eaten the position's margin. The remaining deposit
        // is protected by the 50% rule, but the trade itself is now insolvent on its own bookings.
        if (uint256(unrealizedLoss) < uint256(pos.margin)) revert NotLiquidatable();

        _closeTrade(trader, 10_000, true);
        emit Liquidated(trader, msg.sender);
    }

    /// @notice Permissionless: close a position older than MAX_POSITION_BLOCKS (~14 days at
    ///         2s blocks). Stops zombie positions from sitting open forever against the
    ///         pool's deployed capital.
    /// @param trader The position owner.
    /// @dev Settles at last-known spot (emergency close path). Reverts NoTraderPosition or
    ///      PositionNotExpired if the position is younger than the cap.
    function forceClose(address trader) external nonReentrant {
        TraderPosition memory pos = positions[trader];
        if (!pos.active) revert NoTraderPosition();
        if (block.number < uint256(pos.openBlock) + MAX_POSITION_BLOCKS) revert PositionNotExpired();

        _closeTrade(trader, 10_000, true);
        emit PositionForceClosed(trader, msg.sender);
    }

    /// @notice Permissionless: close a position whose TP or SL has been hit at current spot.
    ///         Keepers call this after pushing fresh Pyth state. Settlement uses cached
    ///         price (no fresh-stale revert) so a TP/SL that crossed during a brief Pyth
    ///         outage still settles cleanly.
    /// @param trader The position owner.
    /// @dev Long: tp hit when spot ≥ tp; sl hit when spot ≤ sl. Short flips both.
    ///      Reverts: NoTraderPosition, ExitNotTriggered (neither TP nor SL crossed).
    function executeExit(address trader) external nonReentrant {
        TraderPosition memory pos = positions[trader];
        if (!pos.active) revert NoTraderPosition();

        // tpPrice and slPrice are guaranteed non-zero on any active position — _validateExit
        // enforces this on openTrade and updateExit. Skip the redundant != 0 checks.
        (uint256 spot,) = _tryReadSpot(pos.assetId);
        bool tpHit;
        bool slHit;
        if (pos.isShort) {
            tpHit = spot <= uint256(pos.tpPrice);
            slHit = spot >= uint256(pos.slPrice);
        } else {
            tpHit = spot >= uint256(pos.tpPrice);
            slHit = spot <= uint256(pos.slPrice);
        }
        if (!tpHit && !slHit) revert ExitNotTriggered();

        _closeTrade(trader, 10_000, true);
        emit ExitExecuted(trader, msg.sender, tpHit);
    }

    /// @notice Withdraw profit accrued above the trader's initial TRADER_DEPOSIT.
    /// @param amount USDC to withdraw. Must leave remaining deposit ≥ TRADER_DEPOSIT.
    /// @dev Reverts NotFunded, ZeroAmount, InsufficientProfit (deposit - amount < TRADER_DEPOSIT).
    function withdrawProfit(uint256 amount) external nonReentrant {
        _withdrawProfit(msg.sender, amount);
    }

    // withdrawProfitFor not exposed: cashing out is principal-only by design. Agent operates
    // the position; principal pulls profit when satisfied.

    function _withdrawProfit(address actor, uint256 amount) internal {
        FundedAccount storage f = funded[actor];
        if (!f.active) revert NotFunded();
        if (positions[actor].active) revert TraderPositionOpen();
        if (f.deposit <= TRADER_DEPOSIT) revert NoProfitToWithdraw();

        uint256 available = f.deposit - TRADER_DEPOSIT;
        if (amount > available) amount = available;

        unchecked { f.deposit -= amount; }
        // Profit always flows to the principal — even when an agent calls this on their behalf.
        USDC.safeTransfer(actor, amount);
        emit ProfitWithdrawn(actor, amount);
    }

    /// @notice Voluntarily exit funded status. Caller's full deposit (including any
    ///         compounded profits) is returned in USDC. To re-enter, the trader must pay
    ///         the eval fee and pass eval again.
    /// @dev Reverts NotFunded or TraderPositionOpen — close any open position first.
    function resignFunding() external nonReentrant {
        FundedAccount storage f = funded[msg.sender];
        if (!f.active) revert NotFunded();
        if (positions[msg.sender].active) revert TraderPositionOpen();
        _revokeFunding(msg.sender, f);
    }

    // resignFundingFor not exposed: ending the funded relationship is principal-only.

    function _revokeFunding(address trader, FundedAccount storage f) internal {
        uint256 depositReturn = f.deposit;

        // EFFECTS: zero the funded account and crediting poolBalance for the deposit happens
        // pessimistically up-front. If the transfer succeeds the pool's actual USDC balance
        // also drops, so poolBalance stays a true upper bound on contract holdings (invariant 7).
        f.active = false;
        f.deposit = 0;
        if (depositReturn > 0) {
            unchecked { poolBalance += depositReturn; }
        }

        uint256 idx = fundedTraderIdx[trader];
        uint256 last = fundedTraders.length;
        if (idx != last) {
            address tail = fundedTraders[last - 1];
            fundedTraders[idx - 1] = tail;
            fundedTraderIdx[tail] = idx;
        }
        fundedTraders.pop();
        delete fundedTraderIdx[trader];

        emit FundingRevoked(trader, f.cumulativePnl);

        // INTERACTIONS: tryTransfer last. _tryTransfer returns false on revert (e.g., USDC
        // blacklist) instead of bubbling — that's intentional so a malicious/blacklisted
        // receiver can't block liquidation. On success we debit poolBalance back; on failure
        // the pool keeps the credit and the deposit stays recoverable from contract balance.
        if (depositReturn > 0 && _tryTransfer(address(USDC), trader, depositReturn)) {
            unchecked { poolBalance -= depositReturn; }
            emit DepositReturned(trader, depositReturn);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readSpot(uint8 assetId) internal view returns (uint256) {
        (uint256 price, bool fresh) = _tryReadSpot(assetId);
        if (!fresh) revert StaleOracle();
        return price;
    }

    function _tryReadSpot(uint8 assetId) internal view returns (uint256 price, bool fresh) {
        IPyth.Price memory p = PYTH.getPriceUnsafe(priceIds[assetId]);
        // Non-positive answer signals a misbehaving feed. Don't revert — return (0, false) so
        // emergency-close + liquidate can still finish using cached entry price.
        if (p.price <= 0) return (0, false);

        // All wired feeds were pinned at install to expo == -8. Single-path conversion.
        price = uint256(uint64(p.price));

        uint256 staleAfter = oracleStaleAfter[assetId];
        if (p.publishTime == 0 || p.publishTime > block.timestamp || block.timestamp - p.publishTime > staleAfter) {
            return (price, false);
        }
        // Confidence-interval guard (audit M-1): reject wide spreads.
        if (uint256(p.conf) * 10_000 > price * MAX_CONF_BPS) {
            return (price, false);
        }
        return (price, true);
    }

    function _calcPnl(uint256 deployed, uint256 entry, uint256 exit, bool isShort) internal pure returns (int256) {
        // Circuit breaker: cap price move at 50% from entry
        uint256 maxMove = (entry * CIRCUIT_BREAKER_BPS) / 10_000;
        uint256 cappedExit = exit;
        if (exit > entry + maxMove) cappedExit = entry + maxMove;
        if (exit < entry && entry - exit > maxMove) cappedExit = entry - maxMove;

        int256 pnl;
        if (isShort) {
            pnl = cappedExit < entry
                ? int256((deployed * (entry - cappedExit)) / entry)
                : -int256((deployed * (cappedExit - entry)) / entry);
        } else {
            pnl = cappedExit > entry
                ? int256((deployed * (cappedExit - entry)) / entry)
                : -int256((deployed * (entry - cappedExit)) / entry);
        }
        // Cap loss at deployed
        if (pnl < -int256(deployed)) pnl = -int256(deployed);
        return pnl;
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _leverageLevel(int256 cumPnl) internal pure returns (uint256) {
        if (cumPnl >= 1000e6) return 10;
        if (cumPnl >= 400e6)  return 8;
        if (cumPnl >= 150e6)  return 5;
        if (cumPnl >= 50e6)   return 3;
        return 2;
    }

    // (Level-up handling is inlined in _handleProfit after the CEI refactor.)

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total economic value the LP pool controls = idle USDC + deployed-into-trades.
    /// @return Total pool value in 6-decimal USDC units.
    function poolValue() public view returns (uint256) {
        return poolBalance + totalDeployed;
    }

    /// @notice Per-share USDC backing. Multiply by your `shares(addr)` to get LP claim.
    /// @return USDC per share, integer-divided. Returns 0 before first deposit.
    function shareValue() external view returns (uint256) {
        if (totalShares == 0) return 0;
        return poolValue() / totalShares;
    }

    // lpValue(addr) removed for size — composable as `shares(addr) * shareValue()`.

    /// @notice Number of currently-active funded traders. Capped at MAX_FUNDED_TRADERS.
    /// @return Count of active funded traders.
    function fundedTraderCount() external view returns (uint256) {
        return fundedTraders.length;
    }

    /// @notice True if a queued or eligible trader can be funded right now (pool has 2×
    ///         TRADER_DEPOSIT headroom AND funded count < MAX_FUNDED_TRADERS).
    /// @return True if claimFunding would advance immediately rather than queue.
    function canFund() external view returns (bool) {
        return poolBalance >= TRADER_DEPOSIT * 2 && fundedTraders.length < MAX_FUNDED_TRADERS;
    }

    /*//////////////////////////////////////////////////////////////
                       QUEUE + EXPIRY VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total traders waiting in the FIFO funding queue.
    /// @return Number of live queued traders (excludes vacated slots).
    function queueLength() external view returns (uint256) {
        // Each live entry escrows exactly one TRADER_DEPOSIT, so the live count is exact and O(1).
        return queuedDeposits / TRADER_DEPOSIT;
    }

    /// @notice 1-indexed live position of `trader` in the queue. 0 = not queued.
    /// @param trader Address to look up.
    /// @return 1-based place in line (next-to-fund = 1), or 0 if not queued.
    /// @dev View-only O(n) over the queue tail: counts live (non-tombstoned) entries from the
    ///      head up to the trader's slot. State mutations stay O(1); this cost is off-chain only.
    function queuePosition(address trader) external view returns (uint256) {
        uint256 abs = queueIdx[trader];
        if (abs == 0) return 0;
        uint256 pos;
        for (uint256 i = fundingQueueHead; i < abs; i++) {
            if (fundingQueue[i] != address(0)) pos++;
        }
        return pos;
    }

    function _effectiveCapInternal(uint256 traderDeposit) internal view returns (uint256) {
        uint256 perTraderCap = (traderDeposit * uint256(MAX_LEVERAGE)) / 2;
        uint256 n = fundedTraders.length;
        if (n == 0) return perTraderCap > poolBalance ? poolBalance : perTraderCap;
        uint256 fairShare = poolBalance / n;
        return perTraderCap < fairShare ? perTraderCap : fairShare;
    }

    /// @notice Max notional this trader can open right now, capped by both their deposit-based
    /// per-trader limit and their fair share of the current pool.
    /// @param trader Funded trader to query.
    /// @return Max notional in USDC this trader can open.
    function effectiveCap(address trader) external view returns (uint256) {
        FundedAccount memory f = funded[trader];
        if (!f.active) return 0;
        return _effectiveCapInternal(f.deposit);
    }

    /// @notice Blocks elapsed since the position was opened. 0 if no active position.
    /// @param trader Position owner to query.
    /// @return Number of blocks since the position opened.
    function positionAge(address trader) external view returns (uint256) {
        TraderPosition memory pos = positions[trader];
        if (!pos.active) return 0;
        return block.number - uint256(pos.openBlock);
    }

    /// @notice True if forceClose can be called for this trader right now.
    /// @param trader Position owner to query.
    /// @return True if the position is past `MAX_POSITION_BLOCKS` and can be force-closed.
    function positionExpired(address trader) external view returns (bool) {
        TraderPosition memory pos = positions[trader];
        if (!pos.active) return false;
        return block.number >= uint256(pos.openBlock) + MAX_POSITION_BLOCKS;
    }

    // traderLevel / traderMaxDeploy / traderProfit / traderDrawdownLimit removed for size —
    // all composable from getTraderStats(addr) or funded(addr).

    /// @notice True if `trader`'s position can be liquidated right now (unrealized loss has
    ///         consumed the position margin). Keeper bots use this to decide whether to call
    ///         liquidate(). Same predicate is re-checked on-chain at liquidation time.
    /// @param trader Position owner to check.
    /// @return True if the position is liquidatable at the current spot price.
    function isLiquidatable(address trader) external view returns (bool) {
        FundedAccount memory f = funded[trader];
        if (!f.active) return false;
        TraderPosition memory pos = positions[trader];
        if (!pos.active) return false;
        (uint256 spot,) = _tryReadSpot(pos.assetId);
        int256 pnl = _calcPnl(pos.usdcDeployed, uint256(pos.entryPrice), spot, pos.isShort);
        return pnl < 0 && uint256(-pnl) >= uint256(pos.margin);
    }

    // evalBlocksLeft removed for size — composable from evals(addr).startBlock + EVAL_DURATION.
    // getTraderStats / getEvalStatus moved to PropFundLens (view layer) to stay under EIP-170.
    // Same return shapes — ABI consumers just repoint those two calls at the lens address.

    /// @notice One row per registered asset: id, current Pyth spot (Pyth 1e8 scale), and a
    ///         freshness flag (true if price is non-stale AND conf within MAX_CONF_BPS).
    struct AssetInfo {
        uint8 id;
        uint256 price;
        bool fresh;
    }

    /// @notice List all supported assets with current prices and freshness flags.
    /// @return result Array indexed 0..assetCount-1. Stale or wide-conf prices have fresh=false.
    function getAssets() external view returns (AssetInfo[] memory result) {
        result = new AssetInfo[](assetCount);
        for (uint8 i = 0; i < assetCount; i++) {
            (uint256 p, bool f) = _tryReadSpot(i);
            result[i] = AssetInfo(i, p, f);
        }
    }

    // getPoolRisk / getLeaderboard / getPoolStats removed for size — agents compose them off-chain
    // by walking fundedTraders[] and calling positions() / funded() / records() per address.
    // poolBalance / totalDeployed / poolValue() / totalShares / fundedTraderCount() / assetCount
    // are all individually exposed.
}

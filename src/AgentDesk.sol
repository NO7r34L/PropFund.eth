// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {ISwapVenue} from "./interfaces/ISwapVenue.sol";
import {IPropFundLens} from "./interfaces/IPropFundLens.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";

/// @title AgentDesk — a real prop desk for agents, funded by the firm's own capital.
/// @notice The simplest real prop firm, on-chain:
///           - The FIRM (owner) funds the desk with its own USDC. No stakers, no LPs, nothing sold.
///           - PropFund (unchanged) is the screen: eval + virtual probation build an immutable
///             on-chain record. An agent whose record clears the bar admits itself — a rule, read
///             from the lens, not a human.
///           - An admitted agent gets a book of USDC and exactly one skill to exercise: timing.
///             Its only actions are enterEth (all-in to WETH) and exitEth (all-out to USDC) through
///             one deep spot pool. 1x, long-only. No leverage means no liquidation engine, no
///             funding, no margin — the only risk is ETH price, bounded by the drawdown rule.
///           - EVERY ENTRY IS A BRACKET ORDER. enterEth takes a take-profit and a stop-loss at the
///             same moment, both within a bounded distance of the entry price (MAX_TARGET_BPS /
///             MAX_STOP_BPS), and the position has a hard maximum age (MAX_HOLD). Anyone can
///             executeExit a book whose bracket or clock has hit — the agent cannot "just hold".
///             The bracket may only be tightened afterwards (trailing), never widened.
///           - Realized profit above the allocation splits agent/firm and is swept, so the
///             book stays at its allocation. Losses shrink the book; breach the drawdown floor and
///             the book is closed, the agent's deposit forfeited. Anyone can liquidate an open
///             ETH position that has breached (keepers compete on gas).
///
///         What makes it a FIRM rather than a lottery — capital concentrates in proven edge:
///           - ALLOCATION SCALES with realized desk PnL (1x → 2x → 4x → 8x of the base book), and
///             scales back down on losses. A flat allocation caps the right tail at one book; the
///             whole prop-firm thesis is riding the winners, so the book must be able to grow.
///           - ...but only on a WIN RATIO, not a lucky trade. Each tier needs a minimum profit
///             factor (gross wins / gross losses — win rate weighted by size, so it can't be gamed
///             with a tiny take-profit and a wide stop) over a small sample of closed desk trades.
///             Agents trade many times a day; a raw trade-count gate only delays proven winners
///             (analysis/desk_sim.py), and the firm's real protection at scale is the collateral rule.
///           - ...but ONLY FOR ALPHA OVER HOLDING. Long-only timing in a bull market "profits" by
///             beta — the firm could have earned that by holding ETH. To scale, an agent's realized
///             desk PnL must exceed what a base-sized buy-and-hold of ETH made since its admission
///             (a hurdle that is zero when ETH is down, so beating the market by staying out counts).
///           - ...and the firm STAYS COLLATERALIZED at every tier. The deposit must always cover
///             the firm's maximum loss on the book (allocation x drawdown). Scaling up draws the
///             shortfall from the agent's own unclaimed winnings; if those can't cover it, the
///             scale-up is capped. A blow-up at any tier makes the firm whole.
///         The firm's economics are the firm's own risk-managed bet — exactly what founding a
///         prop firm is — not a promise to third parties.
/// @dev PropFund is read-only from here. Cancun transient storage for reentrancy.
contract AgentDesk {
    using SafeTransferLib for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error ZeroAmount();
    error ZeroAddress();
    error BadConfig();
    error Paused();
    error Reentrancy();
    error AlreadyActive();
    error NotActive();
    error NotQualified();
    error InsufficientIdle();
    /// @notice Action requires the book to be in USDC (no open ETH).
    error InEth();
    /// @notice Action requires the book to be in ETH.
    error InUsdc();
    error NotLiquidatable();
    error StaleOracle();
    error NothingToClaim();
    /// @notice Bracket missing, inverted, or outside MAX_STOP_BPS / MAX_TARGET_BPS of entry.
    error BadBracket();
    /// @notice Bracket update may only tighten (raise the stop, lower the target).
    error BracketWidened();
    /// @notice executeExit: neither take-profit, stop-loss nor max-hold has hit.
    error NotExecutable();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Funded(uint256 amount, uint256 firmIdle);
    event IdleWithdrawn(uint256 amount, uint256 firmIdle);
    event FirmProfitWithdrawn(uint256 amount);
    event PauseSet(bool paused);
    event Preapproved(address indexed agent, bool approved);
    event Admitted(address indexed agent, uint256 allocation, uint256 deposit, bool viaLens, uint256 benchPrice);
    event Entered(address indexed agent, uint256 usdcIn, uint256 ethOut, uint64 entryPrice, uint64 tpPrice, uint64 slPrice);
    event BracketUpdated(address indexed agent, uint64 tpPrice, uint64 slPrice);
    /// @notice A keeper (or the agent) closed the book on its bracket: 1 = take-profit, 2 = stop-loss, 3 = max hold.
    event BracketExecuted(address indexed agent, address indexed executor, uint8 reason, uint256 mark);
    event Exited(address indexed agent, uint256 ethIn, uint256 usdcOut, int256 pnl, uint256 agentCut, uint256 firmCut, int256 cumPnl);
    /// @notice Allocation changed. `hurdle` is the buy-and-hold profit the agent had to beat.
    event Scaled(address indexed agent, uint256 oldAllocation, uint256 newAllocation, uint256 mult, int256 cumPnl, int256 hurdle);
    event Liquidated(address indexed agent, address indexed liquidator, uint256 markValue, uint256 usdcOut);
    event Revoked(address indexed agent, uint256 bookReturned, uint256 deposit, bool forfeited);
    event Resigned(address indexed agent);
    event Claimed(address indexed agent, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONFIG (IMMUTABLE)
    //////////////////////////////////////////////////////////////*/

    /// @notice The firm. Funds the desk, pulls firm profit, can pause opens, can preapprove.
    address public immutable OWNER;
    IERC20 public immutable USDC;
    IERC20 public immutable WETH;
    IPyth public immutable PYTH;
    bytes32 public immutable ETH_PRICE_ID;
    IPropFundLens public immutable LENS;
    ISwapVenue public immutable VENUE;

    /// @notice USDC book each admitted agent starts with (6dp). Tier 1.
    uint256 public immutable BASE_ALLOCATION;
    /// @notice Agent's skin-in-the-game, escrowed on admission (6dp). Must cover the base tier's
    ///         maximum loss (BASE_ALLOCATION x MAX_DRAWDOWN_BPS). Forfeited on a drawdown breach.
    uint256 public immutable AGENT_DEPOSIT;
    /// @notice Book value at or below allocation × (1 − this) closes the book. bps.
    uint256 public immutable MAX_DRAWDOWN_BPS;
    /// @notice Share of realized profit the agent keeps. bps. The rest is the firm's.
    uint256 public immutable AGENT_SPLIT_BPS;
    /// @notice Admission bar read from the PropFund lens (virtual probation record).
    int256  public immutable MIN_CUM_PNL;
    uint256 public immutable MIN_TRADES;
    /// @notice Admission: totalProfit / totalLoss must be at least this (bps; 0 = disabled).
    ///         A cheap regime-robustness add — a lucky long-only pass in a bull market still has to
    ///         have kept its losers small relative to its winners.
    uint256 public immutable MIN_PROFIT_FACTOR_BPS;
    /// @notice Pyth freshness window for marking an open ETH book.
    uint256 public immutable STALE_AFTER;
    /// @notice Bracket bounds: the stop may sit at most this far below entry, the target at most
    ///         this far above (bps of entry price). A stop farther than the drawdown floor is pointless.
    uint256 public immutable MAX_STOP_BPS;
    uint256 public immutable MAX_TARGET_BPS;
    /// @notice Hard maximum age of an ETH position (seconds). Past it, anyone can executeExit.
    uint256 public immutable MAX_HOLD;

    /// @notice Allocation ladder: realized desk PnL (as bps of BASE_ALLOCATION) that unlocks 2x/4x/8x.
    uint256 public immutable SCALE_T2_BPS;
    uint256 public immutable SCALE_T4_BPS;
    uint256 public immutable SCALE_T8_BPS;
    /// @notice Hard cap on the allocation multiplier (≤ 8).
    uint256 public immutable MAX_ALLOCATION_MULT;
    /// @notice Sample floor: closed desk trades before any tier can unlock (same for every tier).
    uint256 public immutable SCALE_MIN_TRADES;
    /// @notice Profit factor (gross wins / gross losses, bps) required for 2x / 4x / 8x.
    uint256 public immutable SCALE_PF_T2_BPS;
    uint256 public immutable SCALE_PF_T4_BPS;
    uint256 public immutable SCALE_PF_T8_BPS;
    /// @notice To scale, realized PnL must beat a base-sized buy-and-hold of ETH by this margin (bps).
    uint256 public immutable ALPHA_MARGIN_BPS;

    /// @notice Reject Pyth reads whose conf exceeds 0.5% of price (mirrors PropFund).
    uint256 internal constant MAX_CONF_BPS = 50;
    /// @notice Liquidation minOut = mark × (1 − this): stops a griefing liquidation at a bad fill.
    uint256 internal constant LIQ_SLIPPAGE_BPS = 200;
    /// @dev eth(1e18) × price(1e8) / 1e20 = usdc(1e6).
    uint256 internal constant ETH_PRICE_TO_USDC = 1e20;
    bytes32 internal constant REENTRANCY_SLOT = keccak256("AgentDesk.reentrancy");

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    struct Book {
        bool active;
        uint256 allocation;   // the USDC the agent is trusted with; profits above it are swept
        uint256 usdc;         // book currently held as USDC (0 while in ETH)
        uint256 eth;          // book currently held as WETH (0 while in USDC)
        uint256 deposit;      // agent's escrowed skin-in-the-game (always ≥ allocation × drawdown)
        int256  cumPnl;       // cumulative REALIZED desk PnL — drives the allocation ladder
        uint256 entryUsdc;    // USDC that went into the current ETH position (exact PnL basis)
        uint256 benchPrice;   // ETH spot (1e8) at admission — the buy-and-hold benchmark start
        uint64  trades;       // closed desk trades (exits + liquidations)
        uint64  entryTime;    // block.timestamp of the current ETH entry (0 while in USDC)
        uint64  wins;         // closed trades with pnl > 0
        uint64  losses;       // closed trades with pnl <= 0
        uint256 grossProfit;  // Σ positive pnl — with grossLoss, the win ratio the ladder reads
        uint256 grossLoss;    // Σ |negative pnl|
    }

    /// @notice The mandatory bracket on an open ETH book (zeroed while in USDC).
    struct Bracket {
        uint64 entryPrice;    // Pyth ETH/USD (1e8) at entry — the bracket's reference
        uint64 tpPrice;       // take-profit: executeExit when mark >= this
        uint64 slPrice;       // stop-loss:   executeExit when mark <= this
    }

    /// @notice Firm USDC not allocated to any book.
    uint256 public firmIdle;
    /// @notice Firm's earned share of realized profits (+ forfeited deposits). Owner pulls.
    uint256 public firmProfit;
    bool public paused;

    mapping(address => Book) public books;
    mapping(address => Bracket) public brackets;
    /// @notice Agent's withdrawable profit share (pull-pattern). Also the source of extra
    ///         collateral when a book scales up.
    mapping(address => uint256) public earned;
    /// @notice Firm discretion: admit an agent regardless of the lens bar (bootstrap / judgment).
    mapping(address => bool) public preapproved;
    address[] public agents;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

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
        address owner;
        IERC20 usdc;
        IERC20 weth;
        IPyth pyth;
        bytes32 ethPriceId;
        IPropFundLens lens;
        ISwapVenue venue;
        uint256 baseAllocation;
        uint256 agentDeposit;
        uint256 maxDrawdownBps;
        uint256 agentSplitBps;
        int256  minCumPnl;
        uint256 minTrades;
        uint256 minProfitFactorBps;
        uint256 staleAfter;
        uint256 maxStopBps;
        uint256 maxTargetBps;
        uint256 maxHold;
        uint256 scaleT2Bps;
        uint256 scaleT4Bps;
        uint256 scaleT8Bps;
        uint256 maxAllocationMult;
        uint256 scaleMinTrades;
        uint256 scalePfT2Bps;
        uint256 scalePfT4Bps;
        uint256 scalePfT8Bps;
        uint256 alphaMarginBps;
    }

    constructor(Config memory c) {
        if (c.owner == address(0) || address(c.usdc) == address(0) || address(c.weth) == address(0)
            || address(c.pyth) == address(0) || address(c.lens) == address(0) || address(c.venue) == address(0)) {
            revert ZeroAddress();
        }
        if (c.baseAllocation == 0 || c.maxDrawdownBps == 0 || c.maxDrawdownBps >= 10_000
            || c.agentSplitBps > 10_000 || c.staleAfter == 0) revert ZeroAmount();
        // The base tier must be fully collateralized: a blow-up at 1x makes the firm whole.
        if (c.agentDeposit < c.baseAllocation * c.maxDrawdownBps / 10_000) revert BadConfig();
        if (c.maxAllocationMult == 0 || c.maxAllocationMult > 8) revert BadConfig();
        if (c.maxStopBps == 0 || c.maxStopBps > c.maxDrawdownBps || c.maxTargetBps == 0 || c.maxHold == 0) revert BadConfig();
        if (!(c.scaleT2Bps < c.scaleT4Bps && c.scaleT4Bps < c.scaleT8Bps)) revert BadConfig();
        if (!(c.scalePfT2Bps <= c.scalePfT4Bps && c.scalePfT4Bps <= c.scalePfT8Bps)) revert BadConfig();
        OWNER = c.owner;
        USDC = c.usdc;
        WETH = c.weth;
        PYTH = c.pyth;
        ETH_PRICE_ID = c.ethPriceId;
        LENS = c.lens;
        VENUE = c.venue;
        BASE_ALLOCATION = c.baseAllocation;
        AGENT_DEPOSIT = c.agentDeposit;
        MAX_DRAWDOWN_BPS = c.maxDrawdownBps;
        AGENT_SPLIT_BPS = c.agentSplitBps;
        MIN_CUM_PNL = c.minCumPnl;
        MIN_TRADES = c.minTrades;
        MIN_PROFIT_FACTOR_BPS = c.minProfitFactorBps;
        STALE_AFTER = c.staleAfter;
        MAX_STOP_BPS = c.maxStopBps;
        MAX_TARGET_BPS = c.maxTargetBps;
        MAX_HOLD = c.maxHold;
        SCALE_T2_BPS = c.scaleT2Bps;
        SCALE_T4_BPS = c.scaleT4Bps;
        SCALE_T8_BPS = c.scaleT8Bps;
        MAX_ALLOCATION_MULT = c.maxAllocationMult;
        SCALE_MIN_TRADES = c.scaleMinTrades;
        SCALE_PF_T2_BPS = c.scalePfT2Bps;
        SCALE_PF_T4_BPS = c.scalePfT4Bps;
        SCALE_PF_T8_BPS = c.scalePfT8Bps;
        ALPHA_MARGIN_BPS = c.alphaMarginBps;
    }

    /*//////////////////////////////////////////////////////////////
                              FIRM (OWNER)
    //////////////////////////////////////////////////////////////*/

    /// @notice Firm deposits its own USDC as allocatable capital.
    function fund(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        firmIdle += amount;
        emit Funded(amount, firmIdle);
    }

    /// @notice Firm pulls unallocated capital back.
    function withdrawIdle(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > firmIdle) revert InsufficientIdle();
        firmIdle -= amount;
        USDC.safeTransfer(msg.sender, amount);
        emit IdleWithdrawn(amount, firmIdle);
    }

    /// @notice Firm pulls its earned profit share.
    function withdrawFirmProfit() external onlyOwner nonReentrant {
        uint256 amount = firmProfit;
        if (amount == 0) revert NothingToClaim();
        firmProfit = 0;
        USDC.safeTransfer(msg.sender, amount);
        emit FirmProfitWithdrawn(amount);
    }

    /// @notice Emergency stop: blocks admissions and new ETH entries. Exits, liquidations,
    ///         resignations and claims always stay open — the firm can never trap an agent.
    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PauseSet(p);
    }

    /// @notice Firm discretion: let `agent` admit itself without meeting the lens bar.
    function setPreapproved(address agent, bool approved) external onlyOwner {
        preapproved[agent] = approved;
        emit Preapproved(agent, approved);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMISSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Does `agent`'s PropFund probation record clear the bar (or is it preapproved)?
    function qualifies(address agent) public view returns (bool) {
        if (preapproved[agent]) return true;
        IPropFundLens.TraderStats memory s = LENS.getTraderStats(agent);
        uint256 trades = uint256(s.wins) + uint256(s.losses);
        if (s.cumulativePnl < MIN_CUM_PNL || trades < MIN_TRADES) return false;
        if (MIN_PROFIT_FACTOR_BPS > 0) {
            if (s.totalLoss == 0) return s.totalProfit > 0;
            if (s.totalProfit * 10_000 / s.totalLoss < MIN_PROFIT_FACTOR_BPS) return false;
        }
        return true;
    }

    /// @notice Admit yourself. Requires a qualifying record (or preapproval), the agent deposit,
    ///         enough idle firm capital for one base allocation, and a fresh ETH mark (it becomes
    ///         your buy-and-hold benchmark). Permissionless — a rule.
    function admit() external nonReentrant {
        if (paused) revert Paused();
        Book storage b = books[msg.sender];
        if (b.active) revert AlreadyActive();
        bool viaLens = !preapproved[msg.sender];
        if (!qualifies(msg.sender)) revert NotQualified();
        if (firmIdle < BASE_ALLOCATION) revert InsufficientIdle();
        (uint256 spot, bool fresh) = _ethSpot();
        if (!fresh) revert StaleOracle();

        // EFFECTS
        firmIdle -= BASE_ALLOCATION;
        b.active = true;
        b.allocation = BASE_ALLOCATION;
        b.usdc = BASE_ALLOCATION;
        b.eth = 0;
        b.deposit = AGENT_DEPOSIT;
        b.cumPnl = 0;
        b.entryUsdc = 0;
        b.benchPrice = spot;
        b.trades = 0;
        b.entryTime = 0;
        b.wins = 0;
        b.losses = 0;
        b.grossProfit = 0;
        b.grossLoss = 0;
        agents.push(msg.sender);

        // INTERACTIONS
        if (AGENT_DEPOSIT > 0) USDC.safeTransferFrom(msg.sender, address(this), AGENT_DEPOSIT);
        emit Admitted(msg.sender, BASE_ALLOCATION, AGENT_DEPOSIT, viaLens, spot);
    }

    /*//////////////////////////////////////////////////////////////
                                 TRADING
    //////////////////////////////////////////////////////////////*/

    /// @notice All-in: swap the whole USDC book to WETH, with a MANDATORY bracket set at the same
    ///         moment. `tpPrice`/`slPrice` are Pyth-scale (1e8) ETH/USD prices; the entry reference
    ///         is the fresh Pyth spot at this call. Bounds: slPrice ≥ spot × (1 − MAX_STOP_BPS),
    ///         tpPrice ≤ spot × (1 + MAX_TARGET_BPS), slPrice < spot < tpPrice.
    function enterEth(uint256 minOut, uint64 tpPrice, uint64 slPrice) external nonReentrant {
        if (paused) revert Paused();
        Book storage b = books[msg.sender];
        if (!b.active) revert NotActive();
        if (b.eth != 0) revert InEth();
        uint256 amountIn = b.usdc;
        if (amountIn == 0) revert ZeroAmount();
        (uint256 spot, bool fresh) = _ethSpot();
        if (!fresh) revert StaleOracle();
        _checkBracket(spot, tpPrice, slPrice);

        b.usdc = 0;  // effects before the external swap
        b.entryUsdc = amountIn;
        b.entryTime = uint64(block.timestamp);
        brackets[msg.sender] = Bracket({ entryPrice: uint64(spot), tpPrice: tpPrice, slPrice: slPrice });
        USDC.approve(address(VENUE), amountIn);
        uint256 out = VENUE.swapExactIn(address(USDC), address(WETH), amountIn, minOut, address(this));
        b.eth = out;
        emit Entered(msg.sender, amountIn, out, uint64(spot), tpPrice, slPrice);
    }

    /// @notice Tighten the bracket on an open book: raise the stop and/or lower the target
    ///         (a trailing stop). Widening is impossible — the risk you entered with is the most
    ///         risk you can ever hold.
    function updateBracket(uint64 tpPrice, uint64 slPrice) external {
        Book storage b = books[msg.sender];
        if (!b.active) revert NotActive();
        if (b.eth == 0) revert InUsdc();
        Bracket storage k = brackets[msg.sender];
        if (tpPrice > k.tpPrice || slPrice < k.slPrice) revert BracketWidened();
        if (slPrice >= tpPrice) revert BadBracket();
        k.tpPrice = tpPrice;
        k.slPrice = slPrice;
        emit BracketUpdated(msg.sender, tpPrice, slPrice);
    }

    /// @notice Permissionless: close an open book whose take-profit or stop-loss has been hit at
    ///         the fresh Pyth mark, or whose position is older than MAX_HOLD. Settles exactly like
    ///         the agent's own exit (split / loss / ladder) — this is the bracket doing its job,
    ///         not a penalty. Fill bounded to within 2% of the mark.
    function executeExit(address agent) external nonReentrant {
        Book storage b = books[agent];
        if (!b.active) revert NotActive();
        if (b.eth == 0) revert InUsdc();
        (uint8 reason, uint256 spot) = _exitReason(b, brackets[agent]);
        if (reason == 0) revert NotExecutable();
        uint256 ethIn = b.eth;
        uint256 mark = ethIn * spot / ETH_PRICE_TO_USDC;
        b.eth = 0;
        uint256 minOut = mark * (10_000 - LIQ_SLIPPAGE_BPS) / 10_000;
        WETH.approve(address(VENUE), ethIn);
        uint256 out = VENUE.swapExactIn(address(WETH), address(USDC), ethIn, minOut, address(this));
        emit BracketExecuted(agent, msg.sender, reason, mark);
        _settle(agent, b, ethIn, out);
    }

    /// @notice All-out: swap the whole WETH book back to USDC and settle. Profit above the
    ///         allocation is split agent/firm and swept; a loss shrinks the book; a drawdown
    ///         breach closes it and forfeits the deposit. Then the allocation ladder is applied.
    function exitEth(uint256 minOut) external nonReentrant {
        Book storage b = books[msg.sender];
        if (!b.active) revert NotActive();
        if (b.eth == 0) revert InUsdc();
        uint256 ethIn = b.eth;

        b.eth = 0;
        WETH.approve(address(VENUE), ethIn);
        uint256 out = VENUE.swapExactIn(address(WETH), address(USDC), ethIn, minOut, address(this));
        _settle(msg.sender, b, ethIn, out);
    }

    /// @notice Permissionless: close an open ETH book whose marked value has breached the
    ///         drawdown floor. Marked at Pyth; the fill is bounded to within 2% of the mark so a
    ///         liquidator can't force a terrible price. Keepers compete on gas.
    function liquidate(address agent) external nonReentrant {
        Book storage b = books[agent];
        if (!b.active) revert NotActive();
        if (b.eth == 0) revert InUsdc();
        (uint256 mark, bool fresh) = _mark(b);
        if (!fresh) revert StaleOracle();
        if (mark > _floor(b)) revert NotLiquidatable();

        uint256 ethIn = b.eth;
        b.eth = 0;
        uint256 minOut = mark * (10_000 - LIQ_SLIPPAGE_BPS) / 10_000;
        WETH.approve(address(VENUE), ethIn);
        uint256 out = VENUE.swapExactIn(address(WETH), address(USDC), ethIn, minOut, address(this));
        emit Liquidated(agent, msg.sender, mark, out);
        _record(b, int256(out) - int256(b.entryUsdc));
        b.usdc = out;
        _revoke(agent, b, true);
    }

    /// @notice Leave the desk. Book must be in USDC. Deposit is returned unless the book is
    ///         at/below the drawdown floor (then it's forfeited, same as a breach).
    function resign() external nonReentrant {
        Book storage b = books[msg.sender];
        if (!b.active) revert NotActive();
        if (b.eth != 0) revert InEth();
        emit Resigned(msg.sender);
        _revoke(msg.sender, b, b.usdc <= _floor(b));
    }

    /// @notice Pull your earned profit share.
    function claim() external nonReentrant {
        uint256 amount = earned[msg.sender];
        if (amount == 0) revert NothingToClaim();
        earned[msg.sender] = 0;
        USDC.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Settle a USDC exit: realize PnL against the exact entry basis, split profit above the
    ///      allocation and sweep the book back to it, or absorb a loss; close on a drawdown
    ///      breach; otherwise apply the allocation ladder.
    function _settle(address agent, Book storage b, uint256 ethIn, uint256 usdcOut) internal {
        int256 pnl = int256(usdcOut) - int256(b.entryUsdc);
        _record(b, pnl);
        b.entryUsdc = 0;
        b.entryTime = 0;
        delete brackets[agent];
        uint256 profit; uint256 agentCut; uint256 firmCut;
        if (usdcOut > b.allocation) {
            profit = usdcOut - b.allocation;
            agentCut = profit * AGENT_SPLIT_BPS / 10_000;
            firmCut = profit - agentCut;
            earned[agent] += agentCut;
            firmProfit += firmCut;
            b.usdc = b.allocation;            // sweep: book resets to its allocation
        } else {
            b.usdc = usdcOut;                  // loss stays in the book
        }
        emit Exited(agent, ethIn, usdcOut, pnl, agentCut, firmCut, b.cumPnl);
        if (b.usdc <= _floor(b)) { _revoke(agent, b, true); return; }
        _rebalance(agent, b);
    }

    /// @dev Bracket validity against the entry reference price.
    function _checkBracket(uint256 spot, uint64 tpPrice, uint64 slPrice) internal view {
        if (slPrice == 0 || tpPrice == 0 || slPrice >= spot || tpPrice <= spot) revert BadBracket();
        if (spot - slPrice > spot * MAX_STOP_BPS / 10_000) revert BadBracket();
        if (tpPrice - spot > spot * MAX_TARGET_BPS / 10_000) revert BadBracket();
    }

    /// @dev Why an open book can be executed right now: 0 none, 1 take-profit, 2 stop-loss,
    ///      3 max hold. Price reasons need a fresh mark; the clock does not.
    function _exitReason(Book storage b, Bracket storage k) internal view returns (uint8 reason, uint256 spot) {
        bool fresh;
        (spot, fresh) = _ethSpot();
        if (fresh) {
            if (spot >= k.tpPrice) return (1, spot);
            if (spot <= k.slPrice) return (2, spot);
        }
        if (block.timestamp - b.entryTime >= MAX_HOLD) {
            if (!fresh) revert StaleOracle();   // still need a mark to bound the fill
            return (3, spot);
        }
        return (0, spot);
    }

    /// @dev Book the realized result of one closed trade into the record the ladder reads.
    function _record(Book storage b, int256 pnl) internal {
        b.cumPnl += pnl;
        b.trades += 1;
        if (pnl > 0) { b.wins += 1; b.grossProfit += uint256(pnl); }
        else { b.losses += 1; b.grossLoss += uint256(-pnl); }
    }

    /// @dev Profit factor in bps: gross wins / gross losses. No losses yet → "infinite" (max).
    function _profitFactorBps(Book storage b) internal view returns (uint256) {
        if (b.grossLoss == 0) return b.grossProfit > 0 ? type(uint256).max : 0;
        return b.grossProfit * 10_000 / b.grossLoss;
    }

    /// @dev The allocation ladder. Target multiplier from realized PnL, gated on beating a
    ///      base-sized buy-and-hold of ETH since admission. Scale-ups draw capital from firmIdle
    ///      (capped by what's available) and top up the deposit from the agent's unclaimed
    ///      winnings so the firm stays collateralized (capped by what those can cover). Scale-downs
    ///      return the excess book to the firm and release excess deposit back to the agent.
    ///      No change on a stale mark.
    function _rebalance(address agent, Book storage b) internal {
        (uint256 mult, int256 hurdle, bool fresh) = _targetMult(b);
        if (!fresh) return;
        uint256 target = BASE_ALLOCATION * mult;
        uint256 oldAlloc = b.allocation;
        if (target > oldAlloc) {
            uint256 add = target - oldAlloc;
            if (add > firmIdle) { add = firmIdle; target = oldAlloc + add; }
            // Collateral: deposit must cover target × drawdown. Shortfall comes from `earned`.
            uint256 reqDep = target * MAX_DRAWDOWN_BPS / 10_000;
            if (b.deposit < reqDep) {
                uint256 coverable = (b.deposit + earned[agent]) * 10_000 / MAX_DRAWDOWN_BPS;
                if (coverable < target) { target = coverable; add = target > oldAlloc ? target - oldAlloc : 0; reqDep = target * MAX_DRAWDOWN_BPS / 10_000; }
                if (b.deposit < reqDep) { uint256 short = reqDep - b.deposit; earned[agent] -= short; b.deposit += short; }
            }
            if (add == 0) return;
            firmIdle -= add;
            b.usdc += add;
            b.allocation = target;
            emit Scaled(agent, oldAlloc, target, mult, b.cumPnl, hurdle);
        } else if (target < oldAlloc) {
            b.allocation = target;
            if (b.usdc > target) { uint256 back = b.usdc - target; b.usdc = target; firmIdle += back; }
            uint256 reqDep = target * MAX_DRAWDOWN_BPS / 10_000;
            if (b.deposit > reqDep) { uint256 rel = b.deposit - reqDep; b.deposit = reqDep; earned[agent] += rel; }
            emit Scaled(agent, oldAlloc, target, mult, b.cumPnl, hurdle);
        }
    }

    /// @dev Multiplier the ladder targets right now, and the buy-and-hold hurdle it had to beat.
    function _targetMult(Book storage b) internal view returns (uint256 mult, int256 hurdle, bool fresh) {
        uint256 spot;
        (spot, fresh) = _ethSpot();
        if (!fresh) return (0, 0, false);
        // Beta hurdle: what a BASE-sized hold of ETH made since admission. Zero when ETH is down —
        // being flat through a drawdown beats holding, and that counts.
        if (spot > b.benchPrice && b.benchPrice > 0) {
            hurdle = int256(BASE_ALLOCATION * (spot - b.benchPrice) / b.benchPrice);
            hurdle = hurdle * int256(10_000 + ALPHA_MARGIN_BPS) / 10_000;
        }
        int256 base = int256(BASE_ALLOCATION);
        mult = 1;
        if (b.cumPnl >= hurdle && b.trades >= SCALE_MIN_TRADES) {
            uint256 pf = _profitFactorBps(b);
            if (b.cumPnl >= base * int256(SCALE_T8_BPS) / 10_000 && pf >= SCALE_PF_T8_BPS) mult = 8;
            else if (b.cumPnl >= base * int256(SCALE_T4_BPS) / 10_000 && pf >= SCALE_PF_T4_BPS) mult = 4;
            else if (b.cumPnl >= base * int256(SCALE_T2_BPS) / 10_000 && pf >= SCALE_PF_T2_BPS) mult = 2;
        }
        if (mult > MAX_ALLOCATION_MULT) mult = MAX_ALLOCATION_MULT;
    }

    /// @dev Close a book: return its USDC to the firm; forfeit or return the deposit.
    function _revoke(address agent, Book storage b, bool forfeit) internal {
        uint256 returned = b.usdc;
        uint256 dep = b.deposit;
        b.active = false;
        b.usdc = 0;
        b.eth = 0;
        b.deposit = 0;
        b.entryUsdc = 0;
        b.entryTime = 0;
        delete brackets[agent];
        firmIdle += returned;
        if (forfeit) {
            firmProfit += dep;
        } else if (dep > 0) {
            USDC.safeTransfer(agent, dep);
        }
        emit Revoked(agent, returned, dep, forfeit);
    }

    function _floor(Book storage b) internal view returns (uint256) {
        return b.allocation * (10_000 - MAX_DRAWDOWN_BPS) / 10_000;
    }

    /// @dev Fresh ETH spot (1e8) with PropFund's freshness + confidence guards.
    function _ethSpot() internal view returns (uint256 price, bool fresh) {
        IPyth.Price memory p = PYTH.getPriceUnsafe(ETH_PRICE_ID);
        if (p.price <= 0) return (0, false);
        price = uint256(uint64(p.price));
        if (p.publishTime == 0 || p.publishTime > block.timestamp || block.timestamp - p.publishTime > STALE_AFTER) {
            return (price, false);
        }
        if (uint256(p.conf) * 10_000 > price * MAX_CONF_BPS) return (price, false);
        return (price, true);
    }

    /// @dev Mark the book in USDC. In USDC it's exact; in ETH it's ETH × fresh Pyth spot.
    function _mark(Book storage b) internal view returns (uint256 value, bool fresh) {
        if (b.eth == 0) return (b.usdc, true);
        uint256 price;
        (price, fresh) = _ethSpot();
        if (!fresh) return (0, false);
        return (b.eth * price / ETH_PRICE_TO_USDC, true);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The whole book as a struct (the auto-generated `books` getter is a 10-field tuple).
    function getBook(address agent) external view returns (Book memory) {
        return books[agent];
    }

    /// @notice Current book value in USDC (marked at Pyth if in ETH) and whether the mark is fresh.
    function bookValue(address agent) external view returns (uint256 value, bool fresh) {
        return _mark(books[agent]);
    }

    /// @notice Drawdown floor for `agent`'s book.
    function drawdownFloor(address agent) external view returns (uint256) {
        return _floor(books[agent]);
    }

    /// @notice Why `agent`'s open book can be executed now (0 none, 1 TP, 2 SL, 3 max hold).
    function exitReason(address agent) external view returns (uint8) {
        Book storage b = books[agent];
        if (!b.active || b.eth == 0) return 0;
        Bracket storage k = brackets[agent];
        (uint256 spot, bool fresh) = _ethSpot();
        if (fresh && spot >= k.tpPrice) return 1;
        if (fresh && spot <= k.slPrice) return 2;
        if (block.timestamp - b.entryTime >= MAX_HOLD) return 3;
        return 0;
    }

    /// @notice True if `agent` holds an open ETH book that a keeper can liquidate right now.
    function isLiquidatable(address agent) external view returns (bool) {
        Book storage b = books[agent];
        if (!b.active || b.eth == 0) return false;
        (uint256 mark, bool fresh) = _mark(b);
        return fresh && mark <= _floor(b);
    }

    /// @notice `agent`'s desk win ratio: profit factor (bps) and win rate (bps of closed trades).
    function winRatio(address agent) external view returns (uint256 profitFactorBps, uint256 winRateBps) {
        Book storage b = books[agent];
        profitFactorBps = _profitFactorBps(b);
        winRateBps = b.trades == 0 ? 0 : uint256(b.wins) * 10_000 / b.trades;
    }

    /// @notice The multiplier the ladder would target for `agent` now, and the buy-and-hold hurdle.
    function ladder(address agent) external view returns (uint256 mult, int256 hurdle, bool fresh) {
        return _targetMult(books[agent]);
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }
}

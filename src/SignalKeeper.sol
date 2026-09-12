// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {IPyth} from "./interfaces/IPyth.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";

/// @notice The subset of AgentDesk a systematic agent uses. A contract is a valid desk agent —
///         books[msg.sender] is keyed by the caller, so this keeper trades its OWN book.
interface IAgentDeskMin {
    struct Book {
        bool active; uint256 allocation; uint256 usdc; uint256 eth; uint256 deposit;
        int256 cumPnl; uint256 entryUsdc; uint256 benchPrice; uint64 trades; uint64 entryTime;
        uint64 wins; uint64 losses; uint256 grossProfit; uint256 grossLoss;
    }
    function admit() external;
    function enterEth(uint256 minOut, uint64 tpPrice, uint64 slPrice) external;
    function getBook(address agent) external view returns (Book memory);
    function AGENT_DEPOSIT() external view returns (uint256);
    function MAX_STOP_BPS() external view returns (uint256);
    function MAX_TARGET_BPS() external view returns (uint256);
}

/// @title SignalKeeper — a FULLY ON-CHAIN systematic desk agent. No LLM, no off-chain judgment.
/// @notice The playbook (RSI / MACD / TWAP / ORB) ported from the YouHaveOptions 0DTE bot, in
///         Solidity. The trick that makes technical indicators cheap on-chain: they are all
///         RECURSIVE — each is a running value updated from the last, O(1) per sample, no candle
///         history stored. `poke()` pulls the ETH price from Pyth, advances every indicator, and
///         — when the book is flat and a long setup fires — opens a bracketed position on its OWN
///         AgentDesk book. Exits are the desk's on-chain bracket (anyone can executeExit). The
///         only off-chain thing left is the permissionless poke (Pyth is a pull oracle); all logic
///         and every trigger live here, verifiable by anyone.
/// @dev Honest limits vs the off-chain signals: Pyth is price-only, so VWAP → TWAP (an EMA of
///      price) and the volume-spike confirmation is dropped. Indicators need a warm-up (~26
///      samples) before longSetup() can be true. Fixed-point: prices are Pyth 1e8; EMA smoothing
///      factors are WAD (1e18).
contract SignalKeeper {
    using SafeTransferLib for IERC20;

    error NotOwner();
    error AlreadyAdmitted();
    error StaleOracle();
    error TooSoon();
    error Reentrancy();

    event Poked(uint256 price, bool sampled, bool entered, uint8 confirmations);
    event Sampled(uint256 price, int256 rsiE2, int256 macdHist, uint256 twap, uint256 orbHigh);
    event Entered(uint256 price, uint64 tpPrice, uint64 slPrice, uint8 confirmations);
    event Admitted();

    /*//////////////////////////////////////////////////////////////
                          CONFIG (IMMUTABLE)
    //////////////////////////////////////////////////////////////*/

    address public immutable OWNER;          // funds/withdraws; NOT needed to poke or trade
    IPyth   public immutable PYTH;
    bytes32 public immutable ETH_PRICE_ID;
    IAgentDeskMin public immutable DESK;
    IERC20  public immutable USDC;

    uint256 public immutable SAMPLE_INTERVAL; // min seconds between indicator samples (e.g. 900 = 15m)
    uint256 public immutable STALE_AFTER;     // Pyth freshness window
    uint256 public immutable ORB_WINDOW;      // opening-range length in seconds (e.g. 3600 = 1h)

    // Indicator periods
    uint256 internal constant RSI_N = 14;
    uint256 internal constant EMA_FAST = 12;
    uint256 internal constant EMA_SLOW = 26;
    uint256 internal constant MACD_SIGNAL = 9;
    uint256 internal constant TWAP_N = 20;
    uint256 internal constant WARMUP = 26;    // samples before longSetup can fire

    // Entry bracket + setup thresholds (bps)
    uint256 public immutable TP_BPS;          // take-profit distance (<= desk MAX_TARGET_BPS)
    uint256 public immutable SL_BPS;          // stop distance (<= desk MAX_STOP_BPS)
    uint256 public immutable RSI_LONG_MAX_E2; // RSI (×100) at/below which the oversold-turn counts (e.g. 4000 = 40)
    uint8   public immutable MIN_CONFIRMATIONS; // long setups required to enter (e.g. 2)
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant MAX_CONF_BPS = 50;
    uint256 internal constant WAD = 1e18;
    bytes32 internal constant REENTRANCY_SLOT = keccak256("SignalKeeper.reentrancy");

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    // All indicator state is a running value in Pyth-price units (1e8), advanced per sample.
    uint256 public samples;        // count of accepted samples (warm-up gate)
    uint256 public lastSampleTime;
    uint256 public prevPrice;      // previous sampled price (for RSI deltas)
    int256  public emaFast;        // EMA(12)
    int256  public emaSlow;        // EMA(26)
    int256  public macdSignalEma;  // EMA(9) of the MACD line
    int256  public avgGain;        // Wilder average gain (1e8)
    int256  public avgLoss;        // Wilder average loss (1e8)
    int256  public twapEma;        // EMA(20) — the price-only stand-in for VWAP
    // ORB (opening range), reset each UTC day
    uint256 public sessionStart;   // UTC-day start of the current session
    uint256 public orbHigh;
    uint256 public orbLow;

    bool public admitted;

    modifier onlyOwner() { if (msg.sender != OWNER) revert NotOwner(); _; }
    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT; uint256 v;
        assembly { v := tload(slot) }
        if (v != 0) revert Reentrancy();
        assembly { tstore(slot, 1) }
        _;
        assembly { tstore(slot, 0) }
    }

    struct Config {
        address owner; IPyth pyth; bytes32 ethPriceId; IAgentDeskMin desk; IERC20 usdc;
        uint256 sampleInterval; uint256 staleAfter; uint256 orbWindow;
        uint256 tpBps; uint256 slBps; uint256 rsiLongMaxE2; uint8 minConfirmations;
    }

    constructor(Config memory c) {
        OWNER = c.owner; PYTH = c.pyth; ETH_PRICE_ID = c.ethPriceId; DESK = c.desk; USDC = c.usdc;
        SAMPLE_INTERVAL = c.sampleInterval; STALE_AFTER = c.staleAfter; ORB_WINDOW = c.orbWindow;
        TP_BPS = c.tpBps; SL_BPS = c.slBps; RSI_LONG_MAX_E2 = c.rsiLongMaxE2; MIN_CONFIRMATIONS = c.minConfirmations;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER / SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Fund the keeper's USDC so it can post the desk deposit. Owner tops up any time.
    function fund(uint256 amount) external onlyOwner nonReentrant {
        USDC.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Owner recovers idle USDC (e.g. after the book is closed and swept back).
    function sweep(uint256 amount) external onlyOwner nonReentrant {
        USDC.safeTransfer(msg.sender, amount);
    }

    /// @notice Admit this contract to the desk as a systematic agent (posts AGENT_DEPOSIT).
    ///         Must be preapproved or qualify on the desk. One-time.
    function admitToDesk() external onlyOwner nonReentrant {
        if (admitted) revert AlreadyAdmitted();
        admitted = true;
        USDC.approve(address(DESK), DESK.AGENT_DEPOSIT());
        DESK.admit();
        emit Admitted();
    }

    /*//////////////////////////////////////////////////////////////
                            THE ONLY LOOP
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless heartbeat: apply a fresh Pyth update (caller pays the fee from
    ///         msg.value; excess refunded), advance the indicators if a sample is due, and if the
    ///         book is flat and a long setup fires, open a bracketed ETH position on our own book.
    ///         Anyone can call it; there is no privileged path.
    function poke(bytes[] calldata priceUpdate) external payable nonReentrant {
        uint256 oracleFee;
        if (priceUpdate.length != 0) {
            oracleFee = PYTH.getUpdateFee(priceUpdate);
            PYTH.updatePriceFeeds{value: oracleFee}(priceUpdate);
        }
        (uint256 price, bool fresh) = _ethSpot();
        if (!fresh) revert StaleOracle();

        bool sampled;
        if (block.timestamp - lastSampleTime >= SAMPLE_INTERVAL) {
            _advance(price);
            lastSampleTime = block.timestamp;
            sampled = true;
        }

        bool entered; uint8 conf;
        if (admitted) {
            IAgentDeskMin.Book memory b = DESK.getBook(address(this));
            if (b.active && b.eth == 0 && b.usdc > 0 && samples >= WARMUP) {
                (bool go, uint8 c) = _longSetup(price);
                conf = c;
                if (go) { _enter(price, b.usdc); entered = true; }
            }
        }
        emit Poked(price, sampled, entered, conf);

        uint256 refund = msg.value - oracleFee;
        if (refund != 0) { (bool ok,) = msg.sender.call{value: refund}(""); require(ok, "refund"); }
    }

    /*//////////////////////////////////////////////////////////////
                            INDICATOR MATH
    //////////////////////////////////////////////////////////////*/

    /// @dev Advance every running indicator by one price sample. O(1), no history.
    function _advance(uint256 priceU) internal {
        int256 price = int256(priceU);

        // ORB: reset at each UTC-day boundary; track high/low during the opening window.
        // slither-disable-next-line weak-prng (this is a calendar-day boundary, not randomness)
        uint256 day = block.timestamp - (block.timestamp % 1 days);
        if (day != sessionStart) { sessionStart = day; orbHigh = priceU; orbLow = priceU; }
        else if (block.timestamp - sessionStart <= ORB_WINDOW) {
            if (priceU > orbHigh) orbHigh = priceU;
            if (priceU < orbLow) orbLow = priceU;
        }

        if (samples == 0) {
            // seed the EMAs and averages with the first sample
            emaFast = price; emaSlow = price; twapEma = price; macdSignalEma = 0;
            avgGain = 0; avgLoss = 0;
        } else {
            emaFast = _ema(emaFast, price, EMA_FAST);
            emaSlow = _ema(emaSlow, price, EMA_SLOW);
            twapEma = _ema(twapEma, price, TWAP_N);
            int256 macd = emaFast - emaSlow;
            macdSignalEma = _ema(macdSignalEma, macd, MACD_SIGNAL);
            // Wilder RSI averages
            int256 delta = price - int256(prevPrice);
            int256 gain = delta > 0 ? delta : int256(0);
            int256 loss = delta < 0 ? -delta : int256(0);
            avgGain = (avgGain * int256(RSI_N - 1) + gain) / int256(RSI_N);
            avgLoss = (avgLoss * int256(RSI_N - 1) + loss) / int256(RSI_N);
        }
        prevPrice = priceU;
        samples += 1;
        emit Sampled(priceU, _rsiE2(), macdHist(), uint256(twapEma), orbHigh);
    }

    /// @dev EMA step in mixed precision: e + k*(x - e), k = 2/(n+1) in WAD.
    function _ema(int256 e, int256 x, uint256 n) internal pure returns (int256) {
        int256 k = int256(2 * WAD / (n + 1));
        return e + (x - e) * k / int256(WAD);
    }

    /// @dev Current MACD histogram (macd line − signal), in 1e8 units.
    function macdHist() public view returns (int256) {
        return (emaFast - emaSlow) - macdSignalEma;
    }

    /// @dev RSI ×100 (so 4123 = 41.23). 100·avgGain/(avgGain+avgLoss); 50 if flat.
    function _rsiE2() internal view returns (int256) {
        int256 denom = avgGain + avgLoss;
        if (denom == 0) return 5000;
        return int256(10000) * avgGain / denom;
    }
    function rsiE2() external view returns (int256) { return _rsiE2(); }

    /*//////////////////////////////////////////////////////////////
                              THE SETUP
    //////////////////////////////////////////////////////////////*/

    /// @dev The long-setup rule. Confirmations (YouHaveOptions long side, minus volume): price
    ///      above TWAP (trend), RSI at/below the oversold-turn line, MACD histogram positive,
    ///      price broke the opening-range high. Enter when >= MIN_CONFIRMATIONS AND above TWAP.
    function _longSetup(uint256 priceU) internal view returns (bool go, uint8 confirmations) {
        if (samples < WARMUP) return (false, 0);
        int256 price = int256(priceU);
        bool aboveTwap = price > twapEma;
        bool rsiLong = _rsiE2() <= int256(RSI_LONG_MAX_E2);
        bool macdBull = macdHist() > 0;
        bool orbBreak = block.timestamp - sessionStart > ORB_WINDOW && priceU > orbHigh;
        uint8 c;
        if (aboveTwap) c++;
        if (rsiLong) c++;
        if (macdBull) c++;
        if (orbBreak) c++;
        // Trend filter: never go long below TWAP, regardless of other confirmations.
        go = aboveTwap && c >= MIN_CONFIRMATIONS;
        confirmations = c;
    }

    /// @notice Public read of the current long setup: (fire?, confirmation count).
    function longSetup() external view returns (bool, uint8) {
        (uint256 price, bool fresh) = _ethSpot();
        if (!fresh) return (false, 0);
        return _longSetup(price);
    }

    /*//////////////////////////////////////////////////////////////
                               ENTRY
    //////////////////////////////////////////////////////////////*/

    function _enter(uint256 price, uint256 bookUsdc) internal {
        uint256 tp = price * (10_000 + _cap(TP_BPS, DESK.MAX_TARGET_BPS())) / 10_000;
        uint256 sl = price * (10_000 - _cap(SL_BPS, DESK.MAX_STOP_BPS())) / 10_000;
        // minOut floor for the desk swap (USDC→WETH): expected ETH minus slippage.
        uint256 minOut = bookUsdc * 1e20 / price * (10_000 - SLIPPAGE_BPS) / 10_000;
        uint8 c; (, c) = _longSetup(price);
        DESK.enterEth(minOut, uint64(tp), uint64(sl));
        emit Entered(price, uint64(tp), uint64(sl), c);
    }

    function _cap(uint256 v, uint256 max) internal pure returns (uint256) { return v > max ? max : v; }

    /// @dev Fresh ETH spot (1e8) with staleness + confidence guards (mirrors AgentDesk).
    function _ethSpot() internal view returns (uint256 price, bool fresh) {
        IPyth.Price memory p = PYTH.getPriceUnsafe(ETH_PRICE_ID);
        if (p.price <= 0) return (0, false);
        price = uint256(uint64(p.price));
        if (p.publishTime == 0 || p.publishTime > block.timestamp || block.timestamp - p.publishTime > STALE_AFTER) return (price, false);
        if (uint256(p.conf) * 10_000 > price * MAX_CONF_BPS) return (price, false);
        return (price, true);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @notice Minimal interface — reads enough of PropFund's eval/funded state to draw the cert.
interface IPropFundView {
    function evals(address trader) external view returns (
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
    function funded(address trader) external view returns (
        bool active,
        int256 cumulativePnl,
        uint256 deposit,
        uint8 lastLevel
    );
}

/// @notice Cert struct as stored on EvalCert. Kept as a separate interface so we don't
/// import the whole NFT into the renderer.
struct Cert {
    address trader;
    uint256 passBlock;
    uint256 value;
    uint8 certType; // 0 = EVAL_PASS, 1 = LEVEL_UP
    uint8 level;
}

/// @title  EvalCertRenderer — fully on-chain SVG generator for PropFund certs
/// @notice Reads the trader's actual stats from PropFund and renders a procedural
///         candlestick chart that's deterministic per-trader (same address always
///         renders the same art). Designed to be hot-swappable: EvalCert.setRenderer()
///         lets the cert admin ship new art without redeploying the NFT.
contract EvalCertRenderer {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;
    using LibString for uint256;

    IPropFundView public immutable PROPFUND;

    /// @dev Number of candles to render. Capped at 12 to keep the chart legible.
    uint256 internal constant MAX_CANDLES = 12;
    /// @dev Min candles so even short eval passes look like a chart, not a stick.
    uint256 internal constant MIN_CANDLES = 5;
    /// @dev Chart bounding box (relative to logo origin)
    int256 internal constant CHART_TOP = -42;
    int256 internal constant CHART_BOT = 30;
    int256 internal constant CHART_LEFT = -70;
    int256 internal constant CHART_RIGHT = 70;

    constructor(address propfund) {
        PROPFUND = IPropFundView(propfund);
    }

    function tokenURI(uint256 tokenId, Cert memory c) external view returns (string memory) {
        DynamicBufferLib.DynamicBuffer memory svg;
        _appendSvgOpen(svg, c);
        _appendChart(svg, c);
        _appendBrand(svg, c);
        _appendBottom(svg, c, tokenId);
        _appendSvgClose(svg);

        DynamicBufferLib.DynamicBuffer memory json;
        _appendJson(json, c, tokenId, svg.data);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json.data)));
    }

    /*//////////////////////////////////////////////////////////////
                           SVG ASSEMBLY
    //////////////////////////////////////////////////////////////*/

    function _appendSvgOpen(DynamicBufferLib.DynamicBuffer memory buf, Cert memory) internal pure {
        buf.p('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="500" style="background:#000">');
        buf.p('<rect x="15" y="15" width="370" height="470" rx="12" fill="none" stroke="#333" stroke-width="1"/>');
    }

    function _appendSvgClose(DynamicBufferLib.DynamicBuffer memory buf) internal pure {
        buf.p('</svg>');
    }

    /// @dev Procedural candlestick chart driven by trader address + actual stats. Each candle
    /// is a 16-bit lane in a packed uint192: [open7|close7|bull1|sign1] × 12. Heights are
    /// pre-scaled to chart range during pack so draw-time has minimal locals.
    function _appendChart(DynamicBufferLib.DynamicBuffer memory buf, Cert memory c) internal view {
        (uint256 totalBps, uint256 numCandles) = _statsFor(c);
        uint256 packed = _packCandles(c, totalBps, numCandles);
        buf.p('<g transform="translate(200,92)" stroke="#fff" stroke-width="2" stroke-linecap="square" fill="none">');
        for (uint256 i = 0; i < numCandles; i++) {
            _drawPacked(buf, packed, i, numCandles);
        }
        buf.p('</g>');
    }

    /// @dev Pack 12 candles into one uint256: each candle gets 16 bits (8 = openY, 8 = closeY).
    /// openY/closeY are pre-translated chart-space values offset by 64 (range -64..+64 → 0..128).
    function _packCandles(Cert memory c, uint256 totalBps, uint256 numCandles)
        internal pure returns (uint256 packed)
    {
        // Generate the walk + scale inline with minimal locals.
        uint256 seed = uint256(keccak256(abi.encode(c.trader, c.passBlock)));
        int256[12] memory bps;
        int256 sum = 0;
        for (uint256 i = 0; i < numCandles - 1; i++) {
            int256 avgRem = (int256(totalBps) - sum) / int256(numCandles - i);
            int256 jitter = int256(uint256((seed >> (i * 12)) & 0xfff)) - 2048;
            bps[i] = avgRem + (jitter * 150) / 2048;
            sum += bps[i];
        }
        bps[numCandles - 1] = int256(totalBps) - sum;
        packed = _packYs(bps, numCandles);
    }

    /// @dev Walk → scale → pack openY/closeY for each candle into a uint256 (16 bits each).
    function _packYs(int256[12] memory bps, uint256 numCandles) internal pure returns (uint256 packed) {
        (int256 minCum, int256 maxCum) = _walkRange(bps, numCandles);
        int256 range = maxCum - minCum;
        if (range == 0) range = 1;
        int256 cum = 0;
        for (uint256 i = 0; i < numCandles; i++) {
            uint256 openY = uint256(CHART_BOT - ((cum - minCum) * (CHART_BOT - CHART_TOP)) / range + 64);
            cum += bps[i];
            uint256 closeY = uint256(CHART_BOT - ((cum - minCum) * (CHART_BOT - CHART_TOP)) / range + 64);
            uint256 bull = bps[i] >= 0 ? 1 : 0;
            packed |= ((openY & 0xff) | ((closeY & 0xff) << 8) | (bull << 16)) << (i * 17);
        }
    }

    function _walkRange(int256[12] memory bps, uint256 numCandles)
        internal pure returns (int256 minCum, int256 maxCum)
    {
        int256 cum = 0;
        for (uint256 i = 0; i < numCandles; i++) {
            int256 prev = cum;
            cum += bps[i];
            if (prev < minCum) minCum = prev;
            if (cum < minCum) minCum = cum;
            if (prev > maxCum) maxCum = prev;
            if (cum > maxCum) maxCum = cum;
        }
    }

    /// @dev Unpack one candle and emit SVG. Few locals.
    function _drawPacked(DynamicBufferLib.DynamicBuffer memory buf, uint256 packed, uint256 i, uint256 numCandles) internal pure {
        uint256 lane = (packed >> (i * 17)) & 0x1ffff;
        int256 openY = int256(lane & 0xff) - 64;
        int256 closeY = int256((lane >> 8) & 0xff) - 64;
        bool bullish = ((lane >> 16) & 1) == 1;
        int256 stepX = (CHART_RIGHT - CHART_LEFT) / int256(numCandles + 1);
        int256 x = CHART_LEFT + stepX * int256(i + 1);
        int256 bodyW = stepX > 8 ? int256(8) : (stepX > 6 ? stepX - 2 : int256(4));
        _appendCandle(buf, x, openY, closeY, bodyW, bullish);
    }

    function _appendCandle(
        DynamicBufferLib.DynamicBuffer memory buf,
        int256 x,
        int256 openY,
        int256 closeY,
        int256 bodyW,
        bool bullish
    ) internal pure {
        int256 top = openY < closeY ? openY : closeY;
        int256 bot = openY > closeY ? openY : closeY;
        if (bot - top < 3) bot = top + 3;
        // Build the candle as one bytes blob, then push once. Keeps stack shallow.
        bytes memory candle = abi.encodePacked(
            _wick(x, top - 5, top),
            _wick(x, bot, bot + 5),
            _body(x, top, bodyW, bot - top, bullish)
        );
        buf.p(candle);
    }

    function _wick(int256 x, int256 y1, int256 y2) internal pure returns (bytes memory) {
        return abi.encodePacked('<line x1="', _i(x), '" y1="', _i(y1), '" x2="', _i(x), '" y2="', _i(y2), '"/>');
    }

    function _body(int256 x, int256 top, int256 w, int256 h, bool bullish) internal pure returns (bytes memory) {
        bytes memory dims = abi.encodePacked(
            '<rect x="', _i(x - w / 2), '" y="', _i(top), '" width="', _i(w), '" height="', _i(h)
        );
        bytes memory fill = bullish ? bytes('none') : bytes('#fff');
        return abi.encodePacked(dims, '" fill="', fill, '"/>');
    }

    function _appendBrand(DynamicBufferLib.DynamicBuffer memory buf, Cert memory c) internal pure {
        buf.p('<text x="200" y="160" text-anchor="middle" fill="#fff" font-family="monospace" font-size="22" font-weight="bold" letter-spacing="4">PROPFUND</text>');
        bytes memory subtitle = c.certType == 0 ? bytes('EVAL PASS') : bytes('LEVEL UP');
        buf.p('<text x="200" y="182" text-anchor="middle" fill="#666" font-family="monospace" font-size="11" letter-spacing="2">');
        buf.p(subtitle);
        buf.p('</text>');
        buf.p('<line x1="50" y1="200" x2="350" y2="200" stroke="#222" stroke-width="1"/>');
    }

    function _appendBottom(DynamicBufferLib.DynamicBuffer memory buf, Cert memory c, uint256 tokenId) internal pure {
        // Main result text
        bytes memory mainText;
        if (c.certType == 0) {
            uint256 bps = c.value > 1e18 ? ((c.value - 1e18) * 10000) / 1e18 : 0;
            mainText = abi.encodePacked('+', _fmtPct(bps), '%');
        } else {
            mainText = bytes(_levelName(c.level));
        }
        buf.p('<text x="200" y="252" text-anchor="middle" fill="#fff" font-family="monospace" font-size="42" font-weight="bold">');
        buf.p(mainText);
        buf.p('</text>');

        // Details
        buf.p('<text x="50" y="330" fill="#555" font-family="monospace" font-size="10">NO.</text>');
        buf.p('<text x="50" y="348" fill="#fff" font-family="monospace" font-size="13">#');
        buf.p(bytes(tokenId.toString()));
        buf.p('</text>');
        buf.p('<text x="50" y="388" fill="#555" font-family="monospace" font-size="10">TRADER</text>');
        buf.p('<text x="50" y="406" fill="#888" font-family="monospace" font-size="8">');
        buf.p(bytes(LibString.toHexString(c.trader)));
        buf.p('</text>');
        buf.p('<text x="50" y="440" fill="#555" font-family="monospace" font-size="10">BLOCK</text>');
        buf.p('<text x="50" y="458" fill="#fff" font-family="monospace" font-size="13">');
        buf.p(bytes(c.passBlock.toString()));
        buf.p('</text>');
    }

    function _appendJson(DynamicBufferLib.DynamicBuffer memory buf, Cert memory c, uint256 tokenId, bytes memory svg) internal pure {
        bytes memory typeName = c.certType == 1
            ? abi.encodePacked('Level ', uint256(c.level).toString(), ' - ', _levelName(c.level))
            : bytes('Eval Pass');
        buf.p('{"name":"PropFund #');
        buf.p(bytes(tokenId.toString()));
        buf.p(' - ');
        buf.p(typeName);
        buf.p('","description":"On-chain PropFund certificate.","image":"data:image/svg+xml;base64,');
        buf.p(bytes(Base64.encode(svg)));
        buf.p('","attributes":[{"trait_type":"Type","value":"');
        buf.p(typeName);
        buf.p('"}]}');
    }

    /*//////////////////////////////////////////////////////////////
                           STATS LOOKUP
    //////////////////////////////////////////////////////////////*/

    function _statsFor(Cert memory c) internal view returns (uint256 totalBps, uint256 numCandles) {
        if (c.certType == 0) {
            // EVAL_PASS: read trader's eval stats — actual return + actual trade count
            (, , , , , uint16 tradeCount, , ,) = PROPFUND.evals(c.trader);
            totalBps = c.value > 1e18 ? ((c.value - 1e18) * 10000) / 1e18 : 0;
            numCandles = uint256(tradeCount);
        } else {
            // LEVEL_UP: walk N candles where N scales with level. PnL → bps.
            (, int256 cumulativePnl, uint256 deposit, ) = PROPFUND.funded(c.trader);
            if (cumulativePnl > 0 && deposit > 0) {
                totalBps = (uint256(cumulativePnl) * 10000) / deposit;
            }
            numCandles = uint256(c.level) + 2;
        }
        if (numCandles < MIN_CANDLES) numCandles = MIN_CANDLES;
        if (numCandles > MAX_CANDLES) numCandles = MAX_CANDLES;
    }

    /*//////////////////////////////////////////////////////////////
                              UTILS
    //////////////////////////////////////////////////////////////*/

    function _i(int256 v) internal pure returns (bytes memory) {
        if (v < 0) return abi.encodePacked('-', uint256(-v).toString());
        return bytes(uint256(v).toString());
    }

    function _fmtPct(uint256 bps) internal pure returns (bytes memory) {
        // bps → "X.XX" string
        return abi.encodePacked((bps / 100).toString(), '.', _twoDigit(bps % 100));
    }

    function _twoDigit(uint256 n) internal pure returns (bytes memory) {
        if (n < 10) return abi.encodePacked('0', n.toString());
        return bytes(n.toString());
    }

    function _levelName(uint8 level) internal pure returns (string memory) {
        if (level == 2)  return "RECRUIT";
        if (level == 3)  return "APPRENTICE";
        if (level == 5)  return "SKILLED";
        if (level == 8)  return "EXPERT";
        if (level == 10) return "MASTER";
        return "NOVICE";
    }
}

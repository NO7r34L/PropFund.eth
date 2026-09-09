// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";
import {ISwapVenue} from "../../src/interfaces/ISwapVenue.sol";

/// @notice Spot venue that fills USDC<->WETH at the Pyth ETH/USD price, minus a configurable
///         slippage haircut. Pre-fund it with both tokens. Used in tests and on the devnet fork
///         (where the real pools have no usable liquidity for our mock USDC).
contract MockSwap is ISwapVenue {
    IERC20 public immutable USDC;
    IERC20 public immutable WETH;
    IPyth public immutable PYTH;
    bytes32 public immutable ETH_PRICE_ID;
    uint256 public slippageBps;   // haircut applied to every fill

    error Slippage();
    error BadPair();

    constructor(IERC20 usdc, IERC20 weth, IPyth pyth, bytes32 ethPriceId, uint256 _slippageBps) {
        USDC = usdc; WETH = weth; PYTH = pyth; ETH_PRICE_ID = ethPriceId; slippageBps = _slippageBps;
    }

    function setSlippageBps(uint256 bps) external { slippageBps = bps; }

    function _price() internal view returns (uint256) {
        IPyth.Price memory p = PYTH.getPriceUnsafe(ETH_PRICE_ID);
        return uint256(uint64(p.price));   // expo -8
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        uint256 price = _price();
        if (tokenIn == address(USDC) && tokenOut == address(WETH)) {
            amountOut = amountIn * 1e20 / price;          // usdc(6) -> weth(18)
        } else if (tokenIn == address(WETH) && tokenOut == address(USDC)) {
            amountOut = amountIn * price / 1e20;          // weth(18) -> usdc(6)
        } else {
            revert BadPair();
        }
        amountOut = amountOut * (10_000 - slippageBps) / 10_000;
        if (amountOut < minOut) revert Slippage();
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, amountOut);
    }
}

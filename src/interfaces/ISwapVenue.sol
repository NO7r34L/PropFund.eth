// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice Minimal spot-swap venue the desk trades through. One deep pool, exact-in swaps.
/// @dev Implementations: a Uniswap V3 / Aerodrome router adapter on real networks, MockSwap
///      (prices at Pyth spot) on forks and in tests. The desk approves `amountIn` of `tokenIn`
///      to the venue before calling; the venue pulls it and delivers `tokenOut` to `to`.
interface ISwapVenue {
    /// @notice Swap exactly `amountIn` of `tokenIn` for `tokenOut`, delivered to `to`.
    /// @dev MUST revert if the output would be below `minOut`.
    /// @return amountOut Amount of `tokenOut` delivered.
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);
}

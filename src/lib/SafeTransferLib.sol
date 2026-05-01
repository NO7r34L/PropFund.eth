// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";

/// @notice Minimal safe transfer library (Solady-inspired).
///         Handles non-conforming ERC-20s that:
///           - return no data (USDT)
///           - revert instead of returning false
///           - return a bool normally (well-behaved)
library SafeTransferLib {
    error TransferFailed();
    error TransferFromFailed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        bool ok;
        assembly {
            let fmp := mload(0x40)
            mstore(fmp, 0xa9059cbb00000000000000000000000000000000000000000000000000000000) // transfer(address,uint256)
            mstore(add(fmp, 0x04), to)
            mstore(add(fmp, 0x24), amount)

            let success := call(gas(), token, 0, fmp, 0x44, 0, 0x20)

            // Accept: success AND (no return data OR return data is true)
            ok := and(
                or(eq(returndatasize(), 0), and(eq(returndatasize(), 0x20), eq(mload(0), 1))),
                success
            )
        }
        if (!ok) revert TransferFailed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bool ok;
        assembly {
            let fmp := mload(0x40)
            mstore(fmp, 0x23b872dd00000000000000000000000000000000000000000000000000000000) // transferFrom(address,address,uint256)
            mstore(add(fmp, 0x04), from)
            mstore(add(fmp, 0x24), to)
            mstore(add(fmp, 0x44), amount)

            let success := call(gas(), token, 0, fmp, 0x64, 0, 0x20)

            ok := and(
                or(eq(returndatasize(), 0), and(eq(returndatasize(), 0x20), eq(mload(0), 1))),
                success
            )
        }
        if (!ok) revert TransferFromFailed();
    }
}

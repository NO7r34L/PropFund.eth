// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice EIP-3156 flash-loan interfaces (verbatim shapes), so any standard borrower can use the desk.
interface IERC3156FlashBorrower {
    /// @dev Must return keccak256("ERC3156FlashBorrower.onFlashLoan") and leave `amount + fee` approved to the lender.
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32);
}

interface IERC3156FlashLender {
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        returns (bool);
}

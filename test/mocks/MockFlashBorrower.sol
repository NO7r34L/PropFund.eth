// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "../../src/interfaces/IERC3156.sol";

/// @notice Configurable ERC-3156 borrower for tests and demos: repays in full, under-repays, or
///         tries to reenter the lender during the loan.
contract MockFlashBorrower is IERC3156FlashBorrower {
    bytes32 constant OK = keccak256("ERC3156FlashBorrower.onFlashLoan");
    enum Mode { Repay, ShortRepay, Reenter, BadReturn }
    Mode public mode;
    uint256 public lastAmount;
    uint256 public lastFee;

    function setMode(Mode m) external { mode = m; }

    function borrow(IERC3156FlashLender lender, address token, uint256 amount) external {
        lender.flashLoan(this, token, amount, "");
    }

    /// @notice Oracle-fresh borrow: forwards msg.value as the Pyth fee (excess comes back here).
    function borrowWithUpdate(address desk, address token, uint256 amount, bytes[] calldata priceUpdate) external payable {
        (bool ok, bytes memory ret) = desk.call{value: msg.value}(
            abi.encodeWithSignature("flashLoanWithUpdate(address,address,uint256,bytes[],bytes)", address(this), token, amount, priceUpdate, "")
        );
        if (!ok) { assembly { revert(add(ret, 32), mload(ret)) } }
    }
    receive() external payable {}

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata) external returns (bytes32) {
        lastAmount = amount; lastFee = fee;
        if (mode == Mode.Reenter) {
            // any state-changing call into the desk must be blocked while its capital is out
            (bool ok,) = msg.sender.call(abi.encodeWithSignature("claim()"));
            require(ok, "reentry blocked");
        }
        uint256 repay = mode == Mode.ShortRepay ? amount + fee - 1 : amount + fee;
        IERC20(token).approve(msg.sender, repay);
        return mode == Mode.BadReturn ? bytes32(0) : OK;
    }
}

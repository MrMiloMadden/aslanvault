// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library AslanErrors {
    error ZeroAddress();
    error ZeroAmount();
    error StrategyAlreadyActive(address strategy);
    error StrategyNotFound(address strategy);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error ExceedsMaxStrategies();
    error StrategyAssetMismatch();
    error InvalidFee();
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library AslanEvents {
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event StrategyDeposit(address indexed strategy, uint256 amount);
    event StrategyWithdraw(address indexed strategy, uint256 amount);
    event Harvest(address indexed strategy, uint256 profit, uint256 fee);
    event FeeRecipientUpdated(address indexed newRecipient);
    event LiquidityBufferUpdated(uint256 newBufferBps);
    event PerformanceFeeUpdated(uint256 newFeeBps);
}

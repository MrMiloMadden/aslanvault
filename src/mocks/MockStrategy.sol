// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IStrategy.sol";
import "./MockUSDC.sol";

contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public override vault;
    address public override asset;
    uint256 public deployedAssets;

    constructor(address _vault, address _asset) {
        vault = _vault;
        asset = _asset;
    }

    function deposit(uint256 amount) external override {
        deployedAssets += amount;
    }

    function withdraw(uint256 amount) external override returns (uint256 actualWithdrawn) {
        actualWithdrawn = amount > deployedAssets ? deployedAssets : amount;
        deployedAssets -= actualWithdrawn;
        IERC20(asset).safeTransfer(vault, actualWithdrawn);
        return actualWithdrawn;
    }

    function totalDeployedAssets() external view override returns (uint256) {
        return deployedAssets;
    }

    function harvest() external override returns (uint256 profit) {
        uint256 currentBalance = IERC20(asset).balanceOf(address(this));
        if (currentBalance > deployedAssets) {
            profit = currentBalance - deployedAssets;
            deployedAssets = currentBalance;
        }
        return profit;
    }

    function emergencyWithdraw() external override returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        deployedAssets = 0;
        IERC20(asset).safeTransfer(vault, balance);
        return balance;
    }

    /// @dev Test helper: mints extra tokens to simulate yield from a protocol
    function simulateYield(uint256 amount) external {
        MockUSDC(asset).mint(address(this), amount);
    }
}

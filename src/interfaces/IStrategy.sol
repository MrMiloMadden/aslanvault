// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStrategy {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external returns (uint256 actualWithdrawn);
    function totalDeployedAssets() external view returns (uint256);
    function harvest() external returns (uint256 profit);
    function emergencyWithdraw() external returns (uint256);
    function vault() external view returns (address);
    function asset() external view returns (address);
}

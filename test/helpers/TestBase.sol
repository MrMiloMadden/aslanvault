// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/AslanVault.sol";
import "../../src/mocks/MockUSDC.sol";
import "../../src/mocks/MockStrategy.sol";

abstract contract AslanTestBase is Test {
    AslanVault public vault;
    MockUSDC public usdc;
    MockStrategy public strategy;

    address public admin = makeAddr("admin");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public pauser = makeAddr("pauser");
    address public strategist = makeAddr("strategist");
    address public feeRecipient = makeAddr("feeRecipient");

    function setUp() public virtual {
        usdc = new MockUSDC();
        vault = new AslanVault(
            IERC20(address(usdc)),
            "Aslan USDC Vault",
            "aslUSDC",
            admin,
            feeRecipient
        );
        strategy = new MockStrategy(address(vault), address(usdc));

        // Grant roles
        vm.startPrank(admin);
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        vault.grantRole(vault.STRATEGIST_ROLE(), strategist);
        vm.stopPrank();

        // Label addresses for readable traces
        vm.label(address(vault), "AslanVault");
        vm.label(address(usdc), "MockUSDC");
        vm.label(address(strategy), "MockStrategy");
        vm.label(admin, "admin");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(pauser, "pauser");
        vm.label(strategist, "strategist");
        vm.label(feeRecipient, "feeRecipient");
    }

    function _mintUsdc(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    function _depositAs(address user, uint256 amount) internal returns (uint256 shares) {
        _mintUsdc(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./helpers/TestBase.sol";
import "../src/libraries/AslanErrors.sol";
import "../src/libraries/AslanEvents.sol";

/*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
//////////////////////////////////////////////////////////////*/

contract AslanVault_Deposit_Test is AslanTestBase {
    function test_deposit_mintsCorrectShares() public {
        uint256 amount = 1000e6; // 1000 USDC
        uint256 shares = _depositAs(user1, amount);
        assertGt(shares, 0, "Should mint shares");
        assertEq(vault.balanceOf(user1), shares, "User should hold shares");
    }

    function test_deposit_transfersAssets() public {
        uint256 amount = 1000e6;
        _depositAs(user1, amount);
        assertEq(usdc.balanceOf(address(vault)), amount, "Vault should hold assets");
        assertEq(usdc.balanceOf(user1), 0, "User should have 0 USDC");
    }

    function test_deposit_revertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        _mintUsdc(user1, 1000e6);
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(1000e6, user1);
        vm.stopPrank();
    }

    function test_deposit_zeroAmount_mintsZeroShares() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 0);
        uint256 shares = vault.deposit(0, user1);
        vm.stopPrank();
        assertEq(shares, 0, "Zero deposit should mint zero shares");
    }
}

/*//////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
//////////////////////////////////////////////////////////////*/

contract AslanVault_Withdraw_Test is AslanTestBase {
    function test_withdraw_burnsCorrectShares() public {
        uint256 amount = 1000e6;
        _depositAs(user1, amount);
        uint256 sharesBefore = vault.balanceOf(user1);

        vm.prank(user1);
        vault.withdraw(amount, user1, user1);

        assertEq(vault.balanceOf(user1), 0, "All shares should be burned");
        assertGt(sharesBefore, 0, "Had shares before");
    }

    function test_withdraw_transfersAssets() public {
        uint256 amount = 1000e6;
        _depositAs(user1, amount);

        vm.prank(user1);
        vault.withdraw(amount, user1, user1);

        assertEq(usdc.balanceOf(user1), amount, "User should get assets back");
    }

    function test_withdraw_revertsWhenPaused() public {
        _depositAs(user1, 1000e6);

        vm.prank(pauser);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.withdraw(1000e6, user1, user1);
    }

    function test_withdraw_pullsFromStrategyIfNeeded() public {
        uint256 amount = 1000e6;
        _depositAs(user1, amount);

        // Strategist adds strategy and deposits vault capital to it
        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));
        vault.depositToStrategy(address(strategy), 800e6);
        vm.stopPrank();

        // Vault only has 200 USDC, user wants 1000
        assertEq(usdc.balanceOf(address(vault)), 200e6);

        vm.prank(user1);
        vault.withdraw(amount, user1, user1);

        assertEq(usdc.balanceOf(user1), amount, "User should receive full amount");
    }
}

/*//////////////////////////////////////////////////////////////
                        ACCOUNTING TESTS
//////////////////////////////////////////////////////////////*/

contract AslanVault_Accounting_Test is AslanTestBase {
    function test_totalAssets_includesStrategyCapital() public {
        _depositAs(user1, 1000e6);

        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));
        vault.depositToStrategy(address(strategy), 800e6);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 1000e6, "Total assets should include strategy capital");
    }

    function test_sharePrice_increasesWithYield() public {
        _depositAs(user1, 1000e6);

        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));
        vault.depositToStrategy(address(strategy), 800e6);
        vm.stopPrank();

        uint256 sharesBefore = vault.convertToShares(1000e6);

        // Simulate 100 USDC yield
        strategy.simulateYield(100e6);

        // Harvest to update accounting
        vm.prank(strategist);
        vault.harvest(address(strategy));

        uint256 sharesAfter = vault.convertToShares(1000e6);
        assertLt(sharesAfter, sharesBefore, "Shares per asset should decrease (share price went up)");
    }

    function test_multipleDepositors_correctAccounting() public {
        _depositAs(user1, 1000e6);
        _depositAs(user2, 2000e6);

        assertEq(vault.totalAssets(), 3000e6, "Total assets = sum of deposits");

        // User2 deposited 2x, so should have ~2x shares
        uint256 shares1 = vault.balanceOf(user1);
        uint256 shares2 = vault.balanceOf(user2);
        // Allow 1 wei rounding
        assertApproxEqAbs(shares2, shares1 * 2, 1, "User2 should have ~2x shares");
    }

    function test_convertToShares_roundingConsistency() public {
        _depositAs(user1, 1000e6);

        uint256 shares = vault.convertToShares(500e6);
        uint256 assetsBack = vault.convertToAssets(shares);
        // Due to rounding, assets back should be <= original
        assertLe(assetsBack, 500e6, "Rounding should favor vault");
    }
}

/*//////////////////////////////////////////////////////////////
                    STRATEGY MANAGEMENT TESTS
//////////////////////////////////////////////////////////////*/

contract AslanVault_Strategy_Test is AslanTestBase {
    function test_addStrategy_works() public {
        vm.prank(strategist);
        vault.addStrategy(address(strategy));

        assertTrue(vault.isActiveStrategy(address(strategy)), "Strategy should be active");
        assertEq(vault.strategiesLength(), 1, "Should have 1 strategy");
        assertEq(vault.strategies(0), address(strategy), "Strategy address should match");
    }

    function test_addStrategy_revertsIfDuplicate() public {
        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));

        vm.expectRevert(abi.encodeWithSelector(AslanErrors.StrategyAlreadyActive.selector, address(strategy)));
        vault.addStrategy(address(strategy));
        vm.stopPrank();
    }

    function test_addStrategy_revertsIfWrongAsset() public {
        MockUSDC otherToken = new MockUSDC();
        MockStrategy badStrategy = new MockStrategy(address(vault), address(otherToken));

        vm.prank(strategist);
        vm.expectRevert(AslanErrors.StrategyAssetMismatch.selector);
        vault.addStrategy(address(badStrategy));
    }

    function test_removeStrategy_withdrawsCapital() public {
        _depositAs(user1, 1000e6);

        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));
        vault.depositToStrategy(address(strategy), 800e6);

        vault.removeStrategy(address(strategy));
        vm.stopPrank();

        assertFalse(vault.isActiveStrategy(address(strategy)), "Strategy should be inactive");
        assertEq(vault.strategiesLength(), 0, "Should have 0 strategies");
        assertEq(usdc.balanceOf(address(vault)), 1000e6, "Capital should be back in vault");
    }

    function test_depositToStrategy_movesAssets() public {
        _depositAs(user1, 1000e6);

        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));
        vault.depositToStrategy(address(strategy), 500e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 500e6, "Vault should have 500");
        assertEq(strategy.totalDeployedAssets(), 500e6, "Strategy should have 500");
    }

    function test_harvest_collectsFees() public {
        _depositAs(user1, 1000e6);

        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));
        vault.depositToStrategy(address(strategy), 800e6);
        vm.stopPrank();

        // Simulate 100 USDC yield
        strategy.simulateYield(100e6);

        uint256 feeRecipientSharesBefore = vault.balanceOf(feeRecipient);

        vm.prank(strategist);
        vault.harvest(address(strategy));

        uint256 feeRecipientSharesAfter = vault.balanceOf(feeRecipient);
        assertGt(feeRecipientSharesAfter, feeRecipientSharesBefore, "Fee recipient should receive shares");
    }
}

/*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL TESTS
//////////////////////////////////////////////////////////////*/

contract AslanVault_AccessControl_Test is AslanTestBase {
    function test_onlyPauser_canPause() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();

        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused(), "Should be paused");
    }

    function test_onlyStrategist_canManageStrategies() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.addStrategy(address(strategy));

        vm.prank(strategist);
        vault.addStrategy(address(strategy));
        assertTrue(vault.isActiveStrategy(address(strategy)));
    }

    function test_onlyAdmin_canSetFees() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setPerformanceFee(500);

        vm.prank(admin);
        vault.setPerformanceFee(500);
        assertEq(vault.performanceFeeBps(), 500);
    }

    function test_setPerformanceFee_revertsIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(AslanErrors.InvalidFee.selector);
        vault.setPerformanceFee(3001); // > 30%
    }

    function test_setLiquidityBuffer_revertsIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(AslanErrors.InvalidFee.selector);
        vault.setLiquidityBuffer(5001); // > 50%
    }

    function test_setFeeRecipient_revertsIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AslanErrors.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
    }

    function test_emergencyWithdraw_onlyPauser() public {
        _depositAs(user1, 1000e6);
        vm.startPrank(strategist);
        vault.addStrategy(address(strategy));
        vault.depositToStrategy(address(strategy), 500e6);
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert();
        vault.emergencyWithdrawFromStrategy(address(strategy));

        vm.prank(pauser);
        vault.emergencyWithdrawFromStrategy(address(strategy));
        assertEq(usdc.balanceOf(address(vault)), 1000e6, "All capital back in vault");
    }
}

/*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
//////////////////////////////////////////////////////////////*/

contract AslanVault_Fuzz_Test is AslanTestBase {
    function testFuzz_deposit_withdraw_roundTrip(uint256 amount) public {
        amount = bound(amount, 1e6, 100_000_000e6); // 1 to 100M USDC

        uint256 shares = _depositAs(user1, amount);

        vm.prank(user1);
        uint256 assetsOut = vault.redeem(shares, user1, user1);

        // Due to rounding, assetsOut may be slightly less
        assertLe(assetsOut, amount, "Should not get more than deposited");
        assertApproxEqAbs(assetsOut, amount, 1, "Should get ~same amount back");
    }

    function testFuzz_multipleUsersDeposit(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1e6, 50_000_000e6);
        amount2 = bound(amount2, 1e6, 50_000_000e6);

        _depositAs(user1, amount1);
        _depositAs(user2, amount2);

        assertEq(vault.totalAssets(), amount1 + amount2, "Total assets = sum");

        // Each user can withdraw their proportional share
        uint256 shares1 = vault.balanceOf(user1);
        vm.startPrank(user1);
        uint256 out1 = vault.redeem(shares1, user1, user1);
        vm.stopPrank();

        uint256 shares2 = vault.balanceOf(user2);
        vm.startPrank(user2);
        uint256 out2 = vault.redeem(shares2, user2, user2);
        vm.stopPrank();

        assertApproxEqAbs(out1 + out2, amount1 + amount2, 2, "All assets accounted for");
    }
}

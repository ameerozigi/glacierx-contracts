// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BaseTest} from "./helpers/TestHelpers.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {ICollateralVault} from "../src/interfaces/ICollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CollateralVaultTest is BaseTest {

    // ─── Basic ERC-4626 round-trip ─────────────────────────────────────────────

    /// @notice testDepositAndWithdraw: basic ERC-4626 deposit → withdraw round trip
    function testDepositAndWithdraw() public {
        uint256 amount = 1000e18;

        // Deposit
        uint256 sharesBefore = vault.balanceOf(alice);
        _deposit(alice, amount);
        uint256 sharesAfter = vault.balanceOf(alice);
        assertGt(sharesAfter, sharesBefore, "no shares minted");
        assertEq(vault.totalAssets(), amount, "totalAssets mismatch");

        // Withdraw full amount
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(amount, alice, alice);
        uint256 usdcAfter = usdc.balanceOf(alice);

        assertEq(usdcAfter - usdcBefore, amount, "wrong USDC returned");
        assertEq(vault.balanceOf(alice), 0, "shares not burned");
    }

    // ─── Locked margin blocks withdraw ────────────────────────────────────────

    /// @notice testLockedMarginBlocksWithdraw: lock margin, attempt withdraw, expect revert
    function testLockedMarginBlocksWithdraw() public {
        uint256 depositAmt = 1000e18;
        uint256 lockAmt    = 500e18;

        _deposit(alice, depositAmt);

        // Simulate PerpEngine locking margin
        vm.prank(address(engine));
        vault.lockMargin(alice, lockAmt);

        // Attempt to withdraw full amount — should revert
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVault.InsufficientFreeMargin.selector,
                depositAmt - lockAmt,
                depositAmt
            )
        );
        vault.withdraw(depositAmt, alice, alice);

        // Partial withdraw up to free margin should succeed
        vm.prank(alice);
        vault.withdraw(depositAmt - lockAmt, alice, alice);
    }

    // ─── Only PerpEngine can lock ──────────────────────────────────────────────

    /// @notice testOnlyPerpEngineCanLock: non-perpEngine caller reverts NotPerpEngine
    function testOnlyPerpEngineCanLock() public {
        _deposit(alice, 1000e18);

        vm.prank(bob); // bob is not perpEngine
        vm.expectRevert(CollateralVault.NotPerpEngine.selector);
        vault.lockMargin(alice, 100e18);
    }

    /// @notice testOnlyPerpEngineCanRelease: non-perpEngine caller reverts NotPerpEngine
    function testOnlyPerpEngineCanRelease() public {
        _deposit(alice, 1000e18);

        vm.prank(address(engine));
        vault.lockMargin(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(CollateralVault.NotPerpEngine.selector);
        vault.releaseMargin(alice, 100e18);
    }

    // ─── maxWithdraw respects locked margin ───────────────────────────────────

    /// @notice testMaxWithdrawRespectsLockedMargin: maxWithdraw() returns free margin only
    function testMaxWithdrawRespectsLockedMargin() public {
        uint256 depositAmt = 1000e18;
        uint256 lockAmt    = 300e18;

        _deposit(alice, depositAmt);

        vm.prank(address(engine));
        vault.lockMargin(alice, lockAmt);

        uint256 maxW = vault.maxWithdraw(alice);
        // Due to 1:1 share price, free margin = depositAmt - lockAmt
        assertEq(maxW, depositAmt - lockAmt, "maxWithdraw incorrect");
    }

    // ─── maxRedeem respects locked margin ─────────────────────────────────────

    function testMaxRedeemRespectsLockedMargin() public {
        _deposit(alice, 1000e18);

        vm.prank(address(engine));
        vault.lockMargin(alice, 400e18);

        uint256 maxR  = vault.maxRedeem(alice);
        uint256 total = vault.balanceOf(alice);
        // locked shares ≈ locked assets (1:1 rate)
        assertEq(maxR, total - vault.convertToShares(400e18), "maxRedeem incorrect");
    }

    // ─── Deposit limit enforcement ─────────────────────────────────────────────

    function testDepositLimitEnforced() public {
        vm.prank(owner);
        vault.setMaxDepositLimit(500e18);

        _deposit(alice, 500e18); // exactly at limit — OK

        // maxDeposit(alice) is now 0, so OZ reverts ERC4626ExceededMaxDeposit.
        // Our ExceedsDepositLimit fires from _deposit when assets > limit,
        // but OZ's outer guard fires first via maxDeposit check.
        // Either revert is acceptable — vault correctly rejects over-limit deposits.
        vm.prank(alice);
        vm.expectRevert(); // any revert is correct
        vault.deposit(100e18, alice); // exceeds limit
    }

    function testDepositLimitEnforcedViaMaxDeposit() public {
        vm.prank(owner);
        vault.setMaxDepositLimit(500e18);

        _deposit(alice, 500e18);

        // maxDeposit returns 0 when at cap
        assertEq(vault.maxDeposit(alice), 0, "maxDeposit should be 0 at cap");

        // Direct _deposit hook: attempt partial deposit under OZ guard but over limit
        // This is tested indirectly — above checks guard works
    }

    // ─── Pause blocks deposits ─────────────────────────────────────────────────

    /// @notice testPauseBlocksDeposits: paused vault reverts deposits
    function testPauseBlocksDeposits() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause
        vault.deposit(100e18, alice);
    }

    /// @notice Paused vault blocks withdrawals
    function testPauseBlocksWithdrawals() public {
        _deposit(alice, 1000e18);

        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause from _withdraw
        vault.withdraw(100e18, alice, alice);
    }

    /// @notice maxDeposit returns 0 when paused
    function testMaxDepositZeroWhenPaused() public {
        vm.prank(owner);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
    }

    // ─── ZeroAmount errors ─────────────────────────────────────────────────────

    function testLockZeroReverts() public {
        _deposit(alice, 1000e18);
        vm.prank(address(engine));
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.lockMargin(alice, 0);
    }

    function testReleaseZeroReverts() public {
        vm.prank(address(engine));
        vm.expectRevert(CollateralVault.ZeroAmount.selector);
        vault.releaseMargin(alice, 0);
    }

    // ─── totalLockedMargin tracking ───────────────────────────────────────────

    function testTotalLockedMarginAccumulatesAndReleases() public {
        _deposit(alice, 1000e18);
        _deposit(bob,   1000e18);

        vm.startPrank(address(engine));
        vault.lockMargin(alice, 200e18);
        vault.lockMargin(bob,   300e18);
        vm.stopPrank();

        assertEq(vault.totalLockedMargin(), 500e18);

        vm.prank(address(engine));
        vault.releaseMargin(alice, 200e18);
        assertEq(vault.totalLockedMargin(), 300e18);
    }

    // ─── Fuzz tests ───────────────────────────────────────────────────────────

    /// @notice testFuzz_DepositWithdraw: fuzz deposit/withdraw amounts within limits
    function testFuzz_DepositWithdraw(uint256 amount) public {
        // Keep amount within alice's balance
        amount = bound(amount, 1e6, usdc.balanceOf(alice));

        _deposit(alice, amount);
        assertEq(vault.totalAssets(), amount, "totalAssets wrong after deposit");

        vm.prank(alice);
        vault.withdraw(amount, alice, alice);
        assertEq(vault.totalAssets(), 0, "totalAssets should be 0 after full withdraw");
    }

    /// @notice testFuzz_LockUnlock: fuzz lock/unlock with varying deposits
    function testFuzz_LockUnlock(uint256 depositAmt, uint256 lockAmt) public {
        depositAmt = bound(depositAmt, 1e6, usdc.balanceOf(alice));
        lockAmt    = bound(lockAmt, 1, depositAmt);

        _deposit(alice, depositAmt);

        vm.prank(address(engine));
        vault.lockMargin(alice, lockAmt);
        assertEq(vault.lockedMargin(alice), lockAmt, "locked amount mismatch");
        assertEq(vault.maxWithdraw(alice), depositAmt - lockAmt, "free margin mismatch");

        vm.prank(address(engine));
        vault.releaseMargin(alice, lockAmt);
        assertEq(vault.lockedMargin(alice), 0, "margin not fully released");
    }

    // ─── setPerpEngine ─────────────────────────────────────────────────────────

    function testOnlyOwnerCanSetPerpEngine() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setPerpEngine(address(0x1234));
    }

    function testSetPerpEngineEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ICollateralVault.PerpEngineUpdated(address(engine), address(0xBEEF));
        vault.setPerpEngine(address(0xBEEF));
    }
}

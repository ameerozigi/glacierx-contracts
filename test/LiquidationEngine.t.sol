// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BaseTest} from "./helpers/TestHelpers.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {IPerpEngine} from "../src/interfaces/IPerpEngine.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";

/// @title LiquidationEngineTest
/// @notice Unit tests for LiquidationEngine.
///         The fork test section requires ARBITRUM_RPC_URL to be set in the environment.
///         Run with: forge test --match-contract LiquidationEngineTest --fork-url $ARBITRUM_RPC_URL
contract LiquidationEngineTest is BaseTest {

    // ─── Unit: canLiquidate ────────────────────────────────────────────────────

    function testCanLiquidateReturnsFalseForHealthyPosition() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 1000e18);

        assertFalse(liqEngine.canLiquidate(alice, MARKET_ETH), "healthy position should not be liquidatable");
    }

    function testCanLiquidateReturnsTrueForUnderwaterPosition() public {
        _deposit(alice, 1000e18);
        // 20x leverage: 100 collateral, 2000 size — minimal margin
        _openPosition(alice, MARKET_ETH, true, 2000e18, 100e18);

        // Drop price 6% to breach 5% maintenance margin
        oracle.setPrice(int256(1880e8));

        assertTrue(liqEngine.canLiquidate(alice, MARKET_ETH), "underwater position should be liquidatable");
    }

    // ─── Unit: liquidate ──────────────────────────────────────────────────────

    function testLiquidateClosesPosition() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 100e18);

        oracle.setPrice(int256(1880e8));

        vm.prank(keeper);
        liqEngine.liquidate(alice, MARKET_ETH);

        OrderTypes.Position memory pos = engine.getPosition(alice, MARKET_ETH);
        assertEq(pos.size, 0, "position not closed after liquidation");
        assertFalse(posManager.hasPosition(alice, MARKET_ETH), "ERC-1155 token not burned");
    }

    function testLiquidateEmitsEvent() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 100e18);
        oracle.setPrice(int256(1880e8));

        vm.prank(keeper);
        vm.expectEmit(true, true, true, false);
        emit LiquidationEngine.LiquidationExecuted(keeper, alice, MARKET_ETH, 100e18, 0);
        liqEngine.liquidate(alice, MARKET_ETH);
    }

    function testLiquidateRevertsForHealthyPosition() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 1000e18);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationEngine.NotLiquidatable.selector, engine.getHealthFactor(alice, MARKET_ETH))
        );
        liqEngine.liquidate(alice, MARKET_ETH);
    }

    // ─── Unit: admin ──────────────────────────────────────────────────────────

    function testSetPerpEngineOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        liqEngine.setPerpEngine(address(0x1234));
    }

    function testSetLiquidatorRewardBpsOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        liqEngine.setLiquidatorRewardBps(200);
    }

    function testSetLiquidatorRewardBpsInvalidReverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidationEngine.InvalidRewardBps.selector, 10_001)
        );
        liqEngine.setLiquidatorRewardBps(10_001);
    }

    function testUpdateLiquidatorReward() public {
        vm.prank(owner);
        liqEngine.setLiquidatorRewardBps(750); // 7.5%
        assertEq(liqEngine.liquidatorRewardBps(), 750);
    }

    // ─── Unit: short position liquidation ─────────────────────────────────────

    function testLiquidateShortPosition() public {
        _deposit(alice, 1000e18);
        // 20x short: 100 collateral, 2000 size
        _openPosition(alice, MARKET_ETH, false, 2000e18, 100e18);

        // Price rises 6% — short position underwater
        oracle.setPrice(int256(2120e8));

        assertTrue(liqEngine.canLiquidate(alice, MARKET_ETH), "short should be liquidatable");

        vm.prank(keeper);
        liqEngine.liquidate(alice, MARKET_ETH);

        assertEq(engine.getPosition(alice, MARKET_ETH).size, 0, "short not liquidated");
    }

    // ─── Fork test section ────────────────────────────────────────────────────
    //
    // These tests run against a forked Arbitrum mainnet state.
    // They are skipped automatically if ARBITRUM_RPC_URL is not set.
    // Run explicitly with:
    //   forge test --match-test testFork_ --fork-url $ARBITRUM_RPC_URL --fork-block-number 200000000
    //

    uint256 internal forkId;

    modifier onlyFork() {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            console.log("[SKIP] ARBITRUM_RPC_URL not set - skipping fork test");
            return;
        }
        forkId = vm.createFork(rpcUrl, 200_000_000);
        vm.selectFork(forkId);
        _;
    }

    /// @notice Fork test: positions near liquidation threshold can be liquidated
    ///         after oracle price manipulation via vm.mockCall.
    function testFork_LiquidationNearThreshold() public onlyFork {
        // Re-deploy on fork with same config
        setUp();

        // Setup: alice deposits and opens a high-leverage position
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 100e18);

        // Simulate oracle returning a price that puts the position underwater
        // Health factor < 1e18 when: (collateral + pnl) / maintenanceMargin < 1
        // With 5% MM: at $1880 price (6% drop), 100 collateral, 2000 size → HF < 1
        bytes memory returnData = abi.encode(
            uint80(1),
            int256(1880e8),  // $1,880 — 6% below entry of $2,000
            uint256(block.timestamp),
            uint256(block.timestamp),
            uint80(1)
        );

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(oracle.latestRoundData.selector),
            returnData
        );

        // Verify the position is now liquidatable
        uint256 hf = engine.getHealthFactor(alice, MARKET_ETH);
        assertLt(hf, 1e18, "health factor should be below 1 after mock");
        assertTrue(liqEngine.canLiquidate(alice, MARKET_ETH), "should be liquidatable");

        // Execute liquidation
        vm.prank(keeper);
        vm.expectEmit(true, true, true, false);
        emit LiquidationEngine.LiquidationExecuted(keeper, alice, MARKET_ETH, 100e18, 0);
        liqEngine.liquidate(alice, MARKET_ETH);

        // Post-liquidation assertions
        assertEq(engine.getPosition(alice, MARKET_ETH).size, 0, "position not closed");
        assertFalse(posManager.hasPosition(alice, MARKET_ETH), "token not burned");
        assertEq(vault.lockedMargin(alice), 0, "margin not released");

        vm.clearMockedCalls();
    }
}

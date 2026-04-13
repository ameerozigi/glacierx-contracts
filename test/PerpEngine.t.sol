// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BaseTest} from "./helpers/TestHelpers.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {IPerpEngine} from "../src/interfaces/IPerpEngine.sol";
import {OrderTypes} from "../src/libraries/OrderTypes.sol";
import {PositionMath} from "../src/libraries/PositionMath.sol";

contract PerpEngineTest is BaseTest {

    // ─── Open position ────────────────────────────────────────────────────────

    function testOpenPositionBasic() public {
        uint256 deposit    = 1000e18;
        uint256 size       = 2000e18;  // 2× leverage
        uint256 collateral = 1000e18;

        _deposit(alice, deposit);
        _openPosition(alice, MARKET_ETH, true, size, collateral);

        OrderTypes.Position memory pos = engine.getPosition(alice, MARKET_ETH);
        assertEq(pos.size,      size,      "size mismatch");
        assertEq(pos.collateral, collateral, "collateral mismatch");
        assertEq(pos.isLong,    true,      "direction mismatch");
        assertGt(pos.entryPrice, 0,        "entryPrice not set");
        assertGt(pos.openedAt,  0,         "openedAt not set");

        // Margin should be locked
        assertEq(vault.lockedMargin(alice), collateral, "margin not locked");
        assertTrue(posManager.hasPosition(alice, MARKET_ETH), "no position token");
    }

    function testOpenPositionShort() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, false, 2000e18, 1000e18);

        OrderTypes.Position memory pos = engine.getPosition(alice, MARKET_ETH);
        assertFalse(pos.isLong, "should be short");
    }

    // ─── Duplicate position rejected ──────────────────────────────────────────

    function testCannotOpenDuplicatePosition() public {
        _deposit(alice, 2000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 1000e18);

        vm.prank(alice);
        vm.expectRevert(IPerpEngine.PositionAlreadyOpen.selector);
        engine.openPosition(MARKET_ETH, true, 1000e18, 500e18);
    }

    // ─── Insufficient collateral rejected ─────────────────────────────────────

    function testOpenPositionInsufficientCollateral() public {
        _deposit(alice, 1000e18);

        // 20× leverage = max; exceeding it (21× = size/collateral > maxLeverage)
        // size=2100e18, collateral=100e18 → leverage = 21× > 20×
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpEngine.InsufficientCollateral.selector,
                100e18,                  // provided
                2100e18 / 20             // required = size / maxLeverage
            )
        );
        engine.openPosition(MARKET_ETH, true, 2100e18, 100e18);
    }

    // ─── Close position — flat (no PnL) ───────────────────────────────────────

    function testClosePositionFlat() public {
        uint256 deposit    = 1000e18;
        uint256 collateral = 500e18;
        uint256 size       = 1000e18;

        _deposit(alice, deposit);
        _openPosition(alice, MARKET_ETH, true, size, collateral);

        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        _closePosition(alice, MARKET_ETH);

        // Position should be gone
        OrderTypes.Position memory pos = engine.getPosition(alice, MARKET_ETH);
        assertEq(pos.size, 0, "position not deleted");
        assertEq(vault.lockedMargin(alice), 0, "margin still locked");
        assertFalse(posManager.hasPosition(alice, MARKET_ETH), "position token not burned");
    }

    // ─── Close position — with profit ─────────────────────────────────────────

    function testClosePositionWithProfit() public {
        uint256 deposit    = 1000e18;
        uint256 collateral = 1000e18;
        uint256 size       = 2000e18;

        _deposit(alice, deposit);
        _openPosition(alice, MARKET_ETH, true, size, collateral);

        // Price increases 10%: $2000 → $2200
        oracle.setPrice(int256(2200e8));

        uint256 sharesBefore = vault.balanceOf(alice);
        _closePosition(alice, MARKET_ETH);
        uint256 sharesAfter = vault.balanceOf(alice);

        // Alice should have more shares (profit credited)
        assertGt(sharesAfter, sharesBefore, "profit not credited");
    }

    // ─── Close position — with loss ───────────────────────────────────────────

    function testClosePositionWithLoss() public {
        uint256 deposit    = 1000e18;
        uint256 collateral = 1000e18;
        uint256 size       = 2000e18;

        _deposit(alice, deposit);
        _openPosition(alice, MARKET_ETH, true, size, collateral);

        // Price drops 10%: $2000 → $1800
        oracle.setPrice(int256(1800e8));

        uint256 sharesBefore = vault.balanceOf(alice);
        _closePosition(alice, MARKET_ETH);
        uint256 sharesAfter = vault.balanceOf(alice);

        // Alice should have fewer shares (loss deducted)
        assertLt(sharesAfter, sharesBefore, "loss not deducted");
    }

    // ─── Cannot close non-existent position ───────────────────────────────────

    function testCloseNonExistentPositionReverts() public {
        vm.prank(alice);
        vm.expectRevert(IPerpEngine.NoOpenPosition.selector);
        engine.closePosition(MARKET_ETH);
    }

    // ─── Market not active ────────────────────────────────────────────────────

    function testOpenPositionInactiveMarketReverts() public {
        _deposit(alice, 1000e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IPerpEngine.MarketNotActive.selector, 999)
        );
        engine.openPosition(999, true, 1000e18, 100e18);
    }

    // ─── Oracle staleness ─────────────────────────────────────────────────────

    function testStaleOracleReverts() public {
        _deposit(alice, 1000e18);
        // Warp to a large timestamp so we can safely subtract
        vm.warp(100_000);
        uint256 staleTs = block.timestamp - 7201; // 100000 - 7201 = 92799
        oracle.setUpdatedAt(staleTs);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPerpEngine.StaleOracle.selector,
                staleTs,
                block.timestamp
            )
        );
        engine.openPosition(MARKET_ETH, true, 1000e18, 100e18);
    }

    // ─── getHealthFactor ──────────────────────────────────────────────────────

    function testHealthFactorAboveOneForSolventPosition() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 1000e18);

        uint256 hf = engine.getHealthFactor(alice, MARKET_ETH);
        assertGt(hf, 1e18, "healthy position should have hf > 1");
    }

    function testHealthFactorBelowOneAfterPriceCollapse() public {
        _deposit(alice, 1000e18);
        // Open 20x long: collateral = 100, size = 2000
        _openPosition(alice, MARKET_ETH, true, 2000e18, 100e18);

        // Price drops 6% — enough to breach 5% maintenance margin
        oracle.setPrice(int256(1880e8)); // ~6% drop

        uint256 hf = engine.getHealthFactor(alice, MARKET_ETH);
        assertLt(hf, 1e18, "underwater position should have hf < 1");
    }

    function testHealthFactorMaxForNoPosition() public {
        uint256 hf = engine.getHealthFactor(alice, MARKET_ETH);
        assertEq(hf, type(uint256).max, "no position should return max");
    }

    // ─── Liquidate via LiquidationEngine ─────────────────────────────────────

    function testLiquidationFlow() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 100e18);

        // Crash price to make position liquidatable
        oracle.setPrice(int256(1880e8));

        assertTrue(liqEngine.canLiquidate(alice, MARKET_ETH), "should be liquidatable");

        vm.prank(keeper);
        liqEngine.liquidate(alice, MARKET_ETH);

        // Position must be gone
        assertEq(engine.getPosition(alice, MARKET_ETH).size, 0, "position not liquidated");
        assertFalse(posManager.hasPosition(alice, MARKET_ETH), "position token not burned");
    }

    function testCannotLiquidateHealthyPosition() public {
        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, true, 2000e18, 1000e18);

        vm.prank(keeper);
        vm.expectRevert();
        liqEngine.liquidate(alice, MARKET_ETH);
    }

    // ─── Admin functions ──────────────────────────────────────────────────────

    function testOnlyOwnerCanAddMarket() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.addMarket(99, IPerpEngine.MarketConfig({
            active: true,
            maxLeverage: 10e18,
            makerFee: 0.001e18,
            takerFee: 0.002e18
        }));
    }

    function testOnlyOwnerCanSetOracle() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.setOracle(address(0x1234));
    }

    function testPauseBlocksOpenPosition() public {
        _deposit(alice, 1000e18);

        vm.prank(owner);
        engine.pause();

        vm.prank(alice);
        vm.expectRevert();
        engine.openPosition(MARKET_ETH, true, 1000e18, 100e18);
    }

    // ─── Fuzz: open + close is safe across price range ────────────────────────

    function testFuzz_OpenAndClose(uint256 priceDelta, bool isLong) public {
        // Price delta: 0–50% move
        priceDelta = bound(priceDelta, 0, 1000e8); // max 50% move from $2000

        _deposit(alice, 1000e18);
        _openPosition(alice, MARKET_ETH, isLong, 2000e18, 1000e18);

        // Apply price move
        int256 newPrice = isLong
            ? int256(ETH_PRICE) + int256(priceDelta)
            : int256(ETH_PRICE) - int256(priceDelta);
        if (newPrice <= 0) newPrice = 100e8; // floor at $100
        oracle.setPrice(newPrice);

        // Closing should never revert for well-collateralised positions
        _closePosition(alice, MARKET_ETH);

        assertEq(engine.getPosition(alice, MARKET_ETH).size, 0, "position not cleared");
    }
}

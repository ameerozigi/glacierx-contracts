// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderTypes} from "./OrderTypes.sol";

/// @title PositionMath
/// @notice Pure math functions for health factor, PnL, and liquidation price calculations
/// @dev All values are in 1e18 fixed-point precision unless otherwise noted
library PositionMath {
    // ─── Constants ─────────────────────────────────────────────────────────────

    uint256 internal constant PRECISION = 1e18;

    // ─── PnL ───────────────────────────────────────────────────────────────────

    /// @notice Computes the unrealised profit or loss for an open position
    /// @param pos    The open position
    /// @param currentPrice The current oracle price, 1e18
    /// @return pnl   Signed PnL in USD (1e18). Positive = profit, negative = loss.
    function getUnrealisedPnL(
        OrderTypes.Position memory pos,
        uint256 currentPrice
    ) internal pure returns (int256 pnl) {
        // Avoid division by zero on a degenerate position
        if (pos.entryPrice == 0 || pos.size == 0) return 0;

        if (pos.isLong) {
            // Long PnL = (currentPrice − entryPrice) × size / entryPrice
            int256 priceDelta = int256(currentPrice) - int256(pos.entryPrice);
            pnl = (priceDelta * int256(pos.size)) / int256(pos.entryPrice);
        } else {
            // Short PnL = (entryPrice − currentPrice) × size / entryPrice
            int256 priceDelta = int256(pos.entryPrice) - int256(currentPrice);
            pnl = (priceDelta * int256(pos.size)) / int256(pos.entryPrice);
        }
    }

    // ─── Health factor ─────────────────────────────────────────────────────────

    /// @notice Computes the health factor of a position.
    ///         A health factor < 1e18 means the position is liquidatable.
    /// @param pos                   The open position
    /// @param currentPrice          Current oracle price, 1e18
    /// @param maintenanceMarginRatio Minimum margin ratio before liquidation, 1e18
    /// @return healthFactor         Health factor scaled to 1e18; 0 if equity ≤ 0
    function getHealthFactor(
        OrderTypes.Position memory pos,
        uint256 currentPrice,
        uint256 maintenanceMarginRatio
    ) internal pure returns (uint256 healthFactor) {
        int256 pnl = getUnrealisedPnL(pos, currentPrice);
        int256 equity = int256(pos.collateral) + pnl;

        // Position is insolvent
        if (equity <= 0) return 0;

        // maintenanceMargin = size × maintenanceMarginRatio / 1e18
        uint256 maintenanceMargin = (pos.size * maintenanceMarginRatio) / PRECISION;
        if (maintenanceMargin == 0) return type(uint256).max;

        // healthFactor = equity × 1e18 / maintenanceMargin
        healthFactor = (uint256(equity) * PRECISION) / maintenanceMargin;
    }

    // ─── Liquidation price ─────────────────────────────────────────────────────

    /// @notice Computes the oracle price at which this position would be liquidated.
    ///
    ///   Long  liqPrice = entryPrice × (1 − collateral/size + maintenanceMarginRatio)
    ///   Short liqPrice = entryPrice × (1 + collateral/size − maintenanceMarginRatio)
    ///
    /// @param pos                   The open position
    /// @param maintenanceMarginRatio Minimum margin ratio, 1e18
    /// @return liqPrice             Liquidation price scaled to 1e18
    function getLiquidationPrice(
        OrderTypes.Position memory pos,
        uint256 maintenanceMarginRatio
    ) internal pure returns (uint256 liqPrice) {
        if (pos.size == 0) return 0;

        // collateralRatio = collateral / size (both 1e18), result in 1e18
        uint256 collateralRatio = (pos.collateral * PRECISION) / pos.size;

        if (pos.isLong) {
            // factor = 1e18 − collateralRatio + maintenanceMarginRatio
            // Guard against underflow: collateralRatio must not exceed 1 + MMR
            uint256 base = PRECISION + maintenanceMarginRatio;
            if (collateralRatio > base) return 0; // already liquidatable
            uint256 factor = base - collateralRatio;
            liqPrice = (pos.entryPrice * factor) / PRECISION;
        } else {
            // factor = 1e18 + collateralRatio − maintenanceMarginRatio
            // Guard: maintenanceMarginRatio should never exceed collateralRatio + 1
            uint256 base = PRECISION + collateralRatio;
            if (maintenanceMarginRatio > base) return type(uint256).max;
            uint256 factor = base - maintenanceMarginRatio;
            liqPrice = (pos.entryPrice * factor) / PRECISION;
        }
    }

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Returns the protocol-wide maximum leverage allowed
    /// @return 20e18 (i.e. 20×)
    function getMaxLeverage() internal pure returns (uint256) {
        return 20e18;
    }
}

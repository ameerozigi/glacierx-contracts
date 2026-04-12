// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPerpEngine} from "./interfaces/IPerpEngine.sol";

/// @title LiquidationEngine
/// @notice Public entry point for keepers. Verifies a position is underwater,
///         delegates closure to PerpEngine, and records the liquidator reward.
contract LiquidationEngine is Ownable2Step {
    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Core protocol engine — source of position and health-factor data
    IPerpEngine public perpEngine;

    /// @notice Liquidation reward in basis points (500 = 5%)
    uint256 public liquidatorRewardBps;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotLiquidatable(uint256 healthFactor);
    error ZeroPerpEngine();
    error InvalidRewardBps(uint256 bps);

    // ─── Events ───────────────────────────────────────────────────────────────

    event LiquidationExecuted(
        address indexed liquidator,
        address indexed user,
        uint256 indexed marketId,
        uint256 collateralSeized,
        uint256 liquidatorReward
    );

    event PerpEngineUpdated(address indexed oldEngine, address indexed newEngine);
    event LiquidatorRewardUpdated(uint256 newBps);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param perpEngine_          Address of PerpEngine (may be address(0) at construction;
    ///                             call setPerpEngine before use)
    /// @param liquidatorRewardBps_ Reward to keeper in basis points (e.g. 500 = 5%)
    constructor(address perpEngine_, uint256 liquidatorRewardBps_)
        Ownable(msg.sender)
    {
        if (liquidatorRewardBps_ > BPS_DENOMINATOR) revert InvalidRewardBps(liquidatorRewardBps_);
        perpEngine = IPerpEngine(perpEngine_);
        liquidatorRewardBps = liquidatorRewardBps_;
    }

    // ─── Liquidation entry point ──────────────────────────────────────────────

    /// @notice Liquidates an under-margined position and records a keeper reward.
    ///         Reverts if the position is still healthy (hf >= 1e18).
    /// @param user     The address owning the underwater position
    /// @param marketId The market in which the position is open
    function liquidate(address user, uint256 marketId) external {
        uint256 healthFactor = perpEngine.getHealthFactor(user, marketId);
        if (healthFactor >= 1e18) revert NotLiquidatable(healthFactor);

        // Read collateral before liquidation to compute reward
        uint256 collateral = perpEngine.getPosition(user, marketId).collateral;

        // Execute the liquidation in PerpEngine (closes position, releases/seizes margin)
        perpEngine.liquidate(user, marketId);

        // Calculate reward and emit
        uint256 reward = (collateral * liquidatorRewardBps) / BPS_DENOMINATOR;

        emit LiquidationExecuted(msg.sender, user, marketId, collateral, reward);
    }

    // ─── View ──────────────────────────────────────────────────────────────────

    /// @notice Returns true if the given position can currently be liquidated.
    /// @param user     The position owner
    /// @param marketId The market ID
    /// @return True if healthFactor < 1e18
    function canLiquidate(address user, uint256 marketId) external view returns (bool) {
        return perpEngine.getHealthFactor(user, marketId) < 1e18;
    }

    // ─── Owner-restricted admin ───────────────────────────────────────────────

    /// @notice Updates the PerpEngine address
    /// @param engine New PerpEngine address (must not be address(0) once live)
    function setPerpEngine(address engine) external onlyOwner {
        address old = address(perpEngine);
        perpEngine = IPerpEngine(engine);
        emit PerpEngineUpdated(old, engine);
    }

    /// @notice Updates the liquidation reward rate
    /// @param newBps New reward in basis points (must be ≤ 10 000)
    function setLiquidatorRewardBps(uint256 newBps) external onlyOwner {
        if (newBps > BPS_DENOMINATOR) revert InvalidRewardBps(newBps);
        liquidatorRewardBps = newBps;
        emit LiquidatorRewardUpdated(newBps);
    }
}

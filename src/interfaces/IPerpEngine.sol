// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OrderTypes} from "../libraries/OrderTypes.sol";

/// @title IPerpEngine
/// @notice Interface for the GlacierX PerpEngine — the core protocol contract
interface IPerpEngine {
    // ─── Structs ──────────────────────────────────────────────────────────────

    /// @notice Configuration for a tradeable market
    struct MarketConfig {
        bool active;
        /// @dev Maximum leverage allowed, 1e18 precision (e.g. 20e18 = 20x)
        uint256 maxLeverage;
        /// @dev Maker fee rate, 1e18 precision (e.g. 0.0002e18 = 0.02%)
        uint256 makerFee;
        /// @dev Taker fee rate, 1e18 precision (e.g. 0.0005e18 = 0.05%)
        uint256 takerFee;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event PositionOpened(
        address indexed user,
        uint256 indexed marketId,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 entryPrice
    );

    event PositionClosed(
        address indexed user,
        uint256 indexed marketId,
        int256 pnl,
        uint256 exitPrice
    );

    event TradeSettled(
        address indexed maker,
        address indexed taker,
        uint256 indexed marketId,
        uint256 price,
        uint256 size
    );

    event Liquidated(
        address indexed liquidator,
        address indexed user,
        uint256 indexed marketId,
        uint256 collateralSeized
    );

    // ─── Errors ───────────────────────────────────────────────────────────────

    error MarketNotActive(uint256 marketId);
    error InsufficientCollateral(uint256 provided, uint256 required);
    error ExceedsMaxLeverage(uint256 leverage, uint256 maxLeverage);
    error PositionAlreadyOpen();
    error NoOpenPosition();
    error NotLiquidatable(uint256 healthFactor);
    error StaleOracle(uint256 updatedAt, uint256 currentTime);
    error InvalidOracleAnswer(int256 answer);
    error InvalidSignature();
    error NonceAlreadyUsed(uint256 nonce);
    error OnlyLiquidationEngine();
    error ZeroAmount();

    // ─── Core trading functions ───────────────────────────────────────────────

    /// @notice Opens a new perpetual position
    function openPosition(
        uint256 marketId,
        bool isLong,
        uint256 size,
        uint256 collateral
    ) external;

    /// @notice Closes an existing position and settles PnL
    function closePosition(uint256 marketId) external;

    /// @notice Settles a matched trade submitted by the authorised settlement engine
    function settleTrade(
        OrderTypes.MatchResult calldata result,
        bytes calldata engineSig
    ) external;

    /// @notice Liquidates an under-margined position
    function liquidate(address user, uint256 marketId) external;

    // ─── View functions ───────────────────────────────────────────────────────

    /// @notice Returns the stored position for a user in a given market
    function getPosition(address user, uint256 marketId)
        external
        view
        returns (OrderTypes.Position memory);

    /// @notice Returns the current health factor for a user's position (1e18 scale)
    function getHealthFactor(address user, uint256 marketId)
        external
        view
        returns (uint256);

    /// @notice Returns the current oracle price scaled to 1e18
    function getOraclePrice() external view returns (uint256);

    /// @notice Returns the maintenance margin ratio (1e18 precision)
    function maintenanceMarginRatio() external view returns (uint256);

    // ─── Admin functions ──────────────────────────────────────────────────────

    function setSettlementEngine(address engine) external;

    function addMarket(uint256 marketId, MarketConfig calldata config) external;

    function setOracle(address oracle) external;
}

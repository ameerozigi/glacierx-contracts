// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title OrderTypes
/// @notice Shared structs for orders, positions, and trade matching in GlacierX Protocol
library OrderTypes {
    // ─── Core structs ──────────────────────────────────────────────────────────

    /// @notice Represents an open perpetual position
    struct Position {
        /// @dev Position size in USD, 1e18 precision
        uint256 size;
        /// @dev Margin deposited, 1e18 precision
        uint256 collateral;
        /// @dev Oracle price at open, 1e18 precision
        uint256 entryPrice;
        /// @dev Leverage factor, e.g. 10e18 = 10x
        uint256 leverage;
        /// @dev True if the position is long; false if short
        bool isLong;
        /// @dev block.timestamp when the position was opened
        uint256 openedAt;
    }

    /// @notice Represents a trader's signed order (used off-chain matching)
    struct Order {
        address trader;
        uint256 marketId;
        bool isLong;
        uint256 size;
        uint256 collateral;
        uint256 price;
        uint256 nonce;
        bytes signature;
    }

    /// @notice Result produced by the off-chain matching engine, submitted on-chain
    struct MatchResult {
        address maker;
        address taker;
        uint256 marketId;
        uint256 price;
        uint256 size;
        bool makerIsLong;
        uint256 nonce;
    }
}

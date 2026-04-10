// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICollateralVault
/// @notice Interface for the GlacierX CollateralVault — the ERC-4626 vault that holds user margin
/// @dev Error selectors are defined on CollateralVault itself (not duplicated here to avoid
///      Solidity visibility conflicts when the contract inherits from this interface).
interface ICollateralVault {
    // ─── Events ───────────────────────────────────────────────────────────────

    event MarginLocked(address indexed user, uint256 amount);
    event MarginReleased(address indexed user, uint256 amount);
    event PerpEngineUpdated(address indexed oldEngine, address indexed newEngine);

    // ─── Margin management (only PerpEngine) ─────────────────────────────────

    /// @notice Locks `amount` of a user's vault balance as position margin
    /// @param user   The position owner
    /// @param amount Asset units to lock
    function lockMargin(address user, uint256 amount) external;

    /// @notice Releases previously locked margin back to the user's free balance
    /// @param user   The position owner
    /// @param amount Asset units to release
    function releaseMargin(address user, uint256 amount) external;

    /// @notice Settles a loss by burning the user's shares and transferring assets to PerpEngine
    /// @param user The position owner
    /// @param loss The loss amount in asset units
    function settleLoss(address user, uint256 loss) external;

    // ─── State accessors ─────────────────────────────────────────────────────

    /// @notice Returns the locked margin for a given user
    function lockedMargin(address user) external view returns (uint256);

    /// @notice Returns the total margin locked across all open positions
    function totalLockedMargin() external view returns (uint256);

    /// @notice Returns the underlying asset address (USDC on Arbitrum)
    function asset() external view returns (address);

    // ─── Owner-restricted config ──────────────────────────────────────────────

    /// @notice Sets the per-user maximum deposit cap
    function setMaxDepositLimit(uint256 limit) external;

    /// @notice Updates the authorised PerpEngine address
    function setPerpEngine(address engine) external;

    /// @notice Pauses vault operations
    function pause() external;

    /// @notice Unpauses vault operations
    function unpause() external;
}

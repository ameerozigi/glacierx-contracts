// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPositionManager
/// @notice Interface for the ERC-1155 position token manager
/// @dev Each ERC-1155 tokenId represents a marketId; balance of 1 == open position
interface IPositionManager {
    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotPerpEngine();
    error PositionAlreadyOpen();
    error NoOpenPosition();

    // ─── Events ───────────────────────────────────────────────────────────────

    event PerpEngineUpdated(address indexed oldEngine, address indexed newEngine);

    // ─── Mint / burn (only PerpEngine) ───────────────────────────────────────

    /// @notice Mints an ERC-1155 position token for a user in a given market
    /// @param user     The position owner
    /// @param tokenId  The market ID (used as ERC-1155 token ID)
    /// @param amount   Amount to mint (always 1 in normal usage)
    function mint(address user, uint256 tokenId, uint256 amount) external;

    /// @notice Burns an ERC-1155 position token on position close or liquidation
    /// @param user     The position owner
    /// @param tokenId  The market ID
    /// @param amount   Amount to burn (always 1 in normal usage)
    function burn(address user, uint256 tokenId, uint256 amount) external;

    // ─── View ──────────────────────────────────────────────────────────────────

    /// @notice Returns true if the user currently holds an open position in `marketId`
    function hasPosition(address user, uint256 marketId) external view returns (bool);

    // ─── Config ────────────────────────────────────────────────────────────────

    /// @notice Sets the authorised PerpEngine address
    function setPerpEngine(address engine) external;
}

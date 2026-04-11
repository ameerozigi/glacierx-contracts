// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";

/// @title PositionManager
/// @notice ERC-1155 position token manager for GlacierX Protocol.
///
///   Each ERC-1155 token ID maps to a market ID.
///   A user holding `balanceOf(user, marketId) == 1` has an open position in that market.
///   Only the authorised PerpEngine may mint or burn position tokens.
///
///   Token URI is intentionally empty — position data lives in PerpEngine storage.
///
contract PositionManager is ERC1155, Ownable2Step, IPositionManager {
    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice The authorised PerpEngine address that may mint/burn positions
    address public perpEngine;

    // ─── Modifier ─────────────────────────────────────────────────────────────

    modifier onlyPerpEngine() {
        if (msg.sender != perpEngine) revert NotPerpEngine();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param owner_ Initial contract owner (should be deployer; transferred to Safe later)
    constructor(address owner_) ERC1155("") Ownable(owner_) {}

    // ─── Config ───────────────────────────────────────────────────────────────

    /// @notice Sets the authorised PerpEngine address
    /// @param engine New PerpEngine address
    function setPerpEngine(address engine) external onlyOwner {
        address old = perpEngine;
        perpEngine = engine;
        emit PerpEngineUpdated(old, engine);
    }

    // ─── Mint / burn ──────────────────────────────────────────────────────────

    /// @notice Mints a position token to `user` for market `tokenId`.
    ///         Reverts if the user already has an open position in this market.
    /// @param user    The position owner
    /// @param tokenId The market ID (used directly as ERC-1155 token ID)
    /// @param amount  Should always be 1 for a single position
    function mint(address user, uint256 tokenId, uint256 amount) external onlyPerpEngine {
        if (balanceOf(user, tokenId) > 0) revert PositionAlreadyOpen();
        _mint(user, tokenId, amount, "");
    }

    /// @notice Burns a position token from `user` for market `tokenId`.
    ///         Reverts if the user has no open position in this market.
    /// @param user    The position owner
    /// @param tokenId The market ID
    /// @param amount  Should always be 1
    function burn(address user, uint256 tokenId, uint256 amount) external onlyPerpEngine {
        if (balanceOf(user, tokenId) == 0) revert NoOpenPosition();
        _burn(user, tokenId, amount);
    }

    // ─── View ──────────────────────────────────────────────────────────────────

    /// @notice Returns true if `user` currently has an open position in `marketId`
    /// @param user     The address to query
    /// @param marketId The market identifier
    /// @return True if an open position exists
    function hasPosition(address user, uint256 marketId) external view returns (bool) {
        return balanceOf(user, marketId) > 0;
    }
}

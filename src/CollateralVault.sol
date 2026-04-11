// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";

/// @title CollateralVault
/// @notice ERC-4626 vault holding user USDC margin. PerpEngine locks/releases margin
///         per open position; withdrawals are blocked for any locked portion.
contract CollateralVault is ERC4626, Ownable2Step, Pausable, ReentrancyGuard, ICollateralVault {
    using SafeERC20 for IERC20;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Address of the PerpEngine contract authorised to lock/release margin
    address public perpEngine;

    /// @notice Per-user maximum deposit cap in asset (USDC) units
    uint256 public maxDepositLimit;

    /// @notice Aggregate margin locked across all open positions
    uint256 public totalLockedMargin;

    /// @notice Per-user locked margin in asset units
    mapping(address => uint256) public lockedMargin;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotPerpEngine();
    error InsufficientFreeMargin(uint256 available, uint256 required);
    error ExceedsDepositLimit(uint256 attempted, uint256 limit);
    error ZeroAmount();

    // ─── Events ───────────────────────────────────────────────────────────────
    // (MarginLocked, MarginReleased, PerpEngineUpdated are declared in ICollateralVault)

    event MaxDepositLimitUpdated(uint256 newLimit);

    // ─── Modifier ─────────────────────────────────────────────────────────────

    modifier onlyPerpEngine() {
        if (msg.sender != perpEngine) revert NotPerpEngine();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @notice Deploys the CollateralVault
    /// @param asset_   Underlying ERC-20 (USDC on Arbitrum: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831)
    /// @param name_    ERC-20 name for vault share token (e.g. "GlacierX USDC Vault")
    /// @param symbol_  ERC-20 symbol for vault share token (e.g. "gxUSDC")
    /// @param owner_   Initial owner — should be immediately transferred to Gnosis Safe
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        // No deposit cap by default; owner sets it after deployment
        maxDepositLimit = type(uint256).max;
    }

    // ─── PerpEngine-restricted margin functions ───────────────────────────────

    /// @notice Locks `amount` of user's vault balance as margin for an open position.
    ///         Reverts if the user's free (unlocked) balance is insufficient.
    /// @param user   The position owner
    /// @param amount Asset units to lock (must be > 0)
    function lockMargin(address user, uint256 amount) external onlyPerpEngine {
        if (amount == 0) revert ZeroAmount();
        uint256 free = _freeMargin(user);
        if (free < amount) revert InsufficientFreeMargin(free, amount);

        lockedMargin[user] += amount;
        totalLockedMargin += amount;

        emit MarginLocked(user, amount);
    }

    /// @notice Releases `amount` of previously locked margin back to the user's free balance.
    ///         Called when a position is closed normally.
    /// @param user   The position owner
    /// @param amount Asset units to release (must be ≤ lockedMargin[user])
    function releaseMargin(address user, uint256 amount) external onlyPerpEngine {
        if (amount == 0) revert ZeroAmount();
        // Solidity 0.8+ overflow protection; lockedMargin[user] >= amount is guaranteed by PerpEngine
        lockedMargin[user] -= amount;
        totalLockedMargin -= amount;

        emit MarginReleased(user, amount);
    }

    /// @notice Settles a trading loss by burning the user's shares and forwarding the
    ///         underlying assets to the PerpEngine (fee pool).
    ///
    ///         Called by PerpEngine immediately after releaseMargin when PnL < 0.
    ///         The two-step (release then settleLoss) is safe within a single transaction
    ///         because no external withdraw can interleave.
    ///
    /// @param user The position owner
    /// @param loss The loss amount in asset units
    function settleLoss(address user, uint256 loss) external onlyPerpEngine {
        if (loss == 0) return;

        // Remove the loss from the locked-margin accounting if still tracked there
        uint256 locked = lockedMargin[user];
        if (locked >= loss) {
            lockedMargin[user] -= loss;
            totalLockedMargin -= loss;
        } else if (locked > 0) {
            // Partial overlap — clear whatever remains locked
            totalLockedMargin -= locked;
            lockedMargin[user] = 0;
        }

        // Burn shares proportional to the loss and transfer underlying to PerpEngine
        uint256 sharesToBurn = previewWithdraw(loss);
        _burn(user, sharesToBurn);
        SafeERC20.safeTransfer(IERC20(asset()), msg.sender, loss);

        emit MarginReleased(user, loss);
    }

    // ─── Owner-restricted admin functions ────────────────────────────────────

    /// @notice Sets the per-user maximum deposit cap
    /// @param limit New cap in asset units; set to type(uint256).max to remove cap
    function setMaxDepositLimit(uint256 limit) external onlyOwner {
        maxDepositLimit = limit;
        emit MaxDepositLimitUpdated(limit);
    }

    /// @notice Updates the authorised PerpEngine address
    /// @param engine New PerpEngine address (address(0) disables locking)
    function setPerpEngine(address engine) external onlyOwner {
        address old = perpEngine;
        perpEngine = engine;
        emit PerpEngineUpdated(old, engine);
    }

    /// @notice Pauses deposits and withdrawals
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes deposits and withdrawals
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── ERC-4626 overrides ───────────────────────────────────────────────────

    /// @notice Returns the underlying asset (disambiguates ERC4626 vs ICollateralVault)
    function asset()
        public
        view
        override(ERC4626, ICollateralVault)
        returns (address)
    {
        return ERC4626.asset();
    }

    /// @notice Deposits `assets` into the vault for `receiver`.
    ///         Blocked when paused; enforces per-user deposit cap via _deposit hook.
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        return super.deposit(assets, receiver);
    }

    /// @notice Mints `shares` to `receiver`.
    ///         Blocked when paused; enforces per-user deposit cap via _deposit hook.
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        return super.mint(shares, receiver);
    }

    /// @notice Withdraws `assets` from the vault for `owner_`.
    ///         Reverts InsufficientFreeMargin before OZ's generic ERC4626ExceededMaxWithdraw.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        uint256 free = _freeMargin(owner_);
        if (assets > free) revert InsufficientFreeMargin(free, assets);
        return super.withdraw(assets, receiver, owner_);
    }

    /// @notice Redeems `shares` from the vault for `owner_`.
    ///         Reverts InsufficientFreeMargin before OZ's generic ERC4626ExceededMaxRedeem.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        uint256 maxR = maxRedeem(owner_);
        if (shares > maxR) {
            uint256 freeAssets = _freeMargin(owner_);
            revert InsufficientFreeMargin(freeAssets, convertToAssets(shares));
        }
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice Maximum assets `owner_` may withdraw, respecting locked margin.
    /// @param owner_ The vault share holder
    /// @return Maximum withdrawable assets (free margin only)
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        return _freeMargin(owner_);
    }

    /// @notice Maximum shares `owner_` may redeem, respecting locked margin.
    /// @param owner_ The vault share holder
    /// @return Maximum redeemable shares
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 lockedShares = convertToShares(lockedMargin[owner_]);
        uint256 bal = balanceOf(owner_);
        return bal > lockedShares ? bal - lockedShares : 0;
    }

    /// @notice Maximum assets `receiver` may deposit, respecting the per-user cap.
    /// @param receiver The prospective depositor
    /// @return 0 if paused; otherwise remaining capacity
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        uint256 deposited = convertToAssets(balanceOf(receiver));
        return deposited >= maxDepositLimit ? 0 : maxDepositLimit - deposited;
    }

    /// @notice Maximum shares `receiver` may mint, derived from maxDeposit.
    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    // ─── Internal ERC-4626 hooks ──────────────────────────────────────────────

    /// @dev Pre-withdraw hook: enforces that `assets` does not exceed the user's
    ///      free (unlocked) margin. Called by ERC-4626's withdraw() and redeem().
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        // reentrancy and pause guards are on the external withdraw/redeem overrides
        uint256 free = _freeMargin(owner_);
        if (assets > free) revert InsufficientFreeMargin(free, assets);
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Pre-deposit hook: enforces the per-user deposit cap.
    ///      Pause check happens at the external deposit/mint level.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 deposited = convertToAssets(balanceOf(receiver));
        if (deposited + assets > maxDepositLimit) {
            revert ExceedsDepositLimit(deposited + assets, maxDepositLimit);
        }
        super._deposit(caller, receiver, assets, shares);
    }

    // ─── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Returns the free (unlocked) assets for `user` in asset units.
    ///      Free margin = total assets owned by user − locked margin.
    function _freeMargin(address user) internal view returns (uint256) {
        uint256 totalUserAssets = convertToAssets(balanceOf(user));
        uint256 locked = lockedMargin[user];
        return totalUserAssets > locked ? totalUserAssets - locked : 0;
    }
}

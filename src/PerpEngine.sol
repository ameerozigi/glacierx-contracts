// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPerpEngine} from "./interfaces/IPerpEngine.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {OrderTypes} from "./libraries/OrderTypes.sol";
import {PositionMath} from "./libraries/PositionMath.sol";

/// @title PerpEngine
/// @notice Core perpetual trading engine. Handles market open/close, ECDSA-verified
///         off-chain trade settlement, oracle price validation, and PnL accounting
///         against the vault's ERC-4626 share pool.
contract PerpEngine is Ownable2Step, Pausable, ReentrancyGuard, IPerpEngine {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @dev Maximum oracle age before a price is considered stale (1 hour)
    uint256 private constant MAX_ORACLE_AGE = 3600;

    /// @dev Chainlink ETH/USD price feed returns 8-decimal prices; scale to 1e18
    uint256 private constant CHAINLINK_SCALE = 1e10;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice ERC-4626 vault that custodies user USDC
    ICollateralVault public vault;

    /// @notice Chainlink ETH/USD price oracle (or any AggregatorV3-compatible feed)
    IOracle public oracle;

    /// @notice ERC-1155 position token manager
    IPositionManager public positionManager;

    /// @notice Address of the authorised off-chain matching engine
    address public settlementEngine;

    /// @notice Address of the LiquidationEngine — only it may call liquidate()
    address public liquidationEngine;

    /// @notice Minimum margin ratio to keep a position open; below this = liquidatable
    uint256 public maintenanceMarginRatio;

    /// @notice Protocol USDC reserve used to pay out trader profits
    uint256 public feePool;

    /// @notice All open positions: user → marketId → Position
    mapping(address => mapping(uint256 => OrderTypes.Position)) public positions;

    /// @notice Market configurations indexed by marketId
    mapping(uint256 => MarketConfig) public markets;

    /// @notice Replay protection for off-chain settlement nonces
    mapping(uint256 => bool) public usedNonces;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param vault_                  Deployed CollateralVault address
    /// @param oracle_                 Chainlink ETH/USD feed (8 decimals)
    /// @param positionManager_        Deployed PositionManager address
    /// @param maintenanceMarginRatio_ e.g. 0.05e18 for 5% maintenance margin
    constructor(
        ICollateralVault vault_,
        IOracle oracle_,
        IPositionManager positionManager_,
        uint256 maintenanceMarginRatio_
    ) Ownable(msg.sender) {
        vault = vault_;
        oracle = oracle_;
        positionManager = positionManager_;
        maintenanceMarginRatio = maintenanceMarginRatio_;
    }

    // ─── Core trading ─────────────────────────────────────────────────────────

    /// @notice Opens a new perpetual position for msg.sender.
    /// @param marketId  The market to trade (must exist and be active)
    /// @param isLong    True for a long, false for a short
    /// @param size      Notional position size in USD, 1e18 precision
    /// @param collateral Margin to lock, in asset (USDC) units, 1e18 precision
    function openPosition(
        uint256 marketId,
        bool isLong,
        uint256 size,
        uint256 collateral
    ) external nonReentrant whenNotPaused {
        _openPositionFor(msg.sender, marketId, isLong, size, collateral);
    }

    /// @notice Closes msg.sender's open position in `marketId` and settles PnL.
    ///         Profit is paid from the fee pool (vault deposit); loss burns the user's shares.
    /// @param marketId  The market to close the position in
    function closePosition(uint256 marketId) external nonReentrant whenNotPaused {
        _closePositionFor(msg.sender, marketId);
    }

    /// @notice Settles a matched trade from the off-chain engine. Signature must be
    ///         from `settlementEngine` over keccak256(abi.encode(result)); nonce is burned.
    /// @param result    The matched trade result produced by the off-chain engine
    /// @param engineSig ECDSA signature (65 bytes) from `settlementEngine`
    function settleTrade(
        OrderTypes.MatchResult calldata result,
        bytes calldata engineSig
    ) external nonReentrant whenNotPaused {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(result))
        );
        address signer = digest.recover(engineSig);
        if (signer != settlementEngine) revert InvalidSignature();

        if (usedNonces[result.nonce]) revert NonceAlreadyUsed(result.nonce);
        usedNonces[result.nonce] = true;

        MarketConfig memory cfg = markets[result.marketId];
        uint256 minCollateral = (result.size * 1e18) / cfg.maxLeverage;

        _openPositionFor(result.maker, result.marketId, result.makerIsLong,  result.size, minCollateral);
        _openPositionFor(result.taker, result.marketId, !result.makerIsLong, result.size, minCollateral);

        emit TradeSettled(result.maker, result.taker, result.marketId, result.price, result.size);
    }

    /// @notice Liquidates an under-margined position.
    ///         Only callable by the authorised LiquidationEngine.
    ///
    /// @param user     The position owner
    /// @param marketId The market the position is in
    function liquidate(address user, uint256 marketId)
        external
        nonReentrant
    {
        if (msg.sender != liquidationEngine) revert OnlyLiquidationEngine();

        uint256 currentHf = _computeHealthFactor(user, marketId);
        if (currentHf >= 1e18) revert NotLiquidatable(currentHf);

        OrderTypes.Position memory pos = positions[user][marketId];

        // Liquidate: return whatever collateral remains (after loss) to feePool
        uint256 currentPrice = _getOraclePrice();
        int256 pnl = PositionMath.getUnrealisedPnL(pos, currentPrice);

        uint256 seized;
        if (pnl >= 0) {
            // Position turned profitable just before liquidation — unlikely but handle it
            seized = pos.collateral;
        } else {
            uint256 loss = uint256(-pnl);
            seized = loss >= pos.collateral ? pos.collateral : loss;
        }

        // Release all locked margin
        vault.releaseMargin(user, pos.collateral);

        // Seize collateral into feePool for loss coverage
        if (seized > 0) {
            vault.settleLoss(user, seized);
            feePool += seized;
        }

        // Burn position token and delete storage
        positionManager.burn(user, marketId, 1);
        delete positions[user][marketId];

        emit Liquidated(msg.sender, user, marketId, seized);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /// @notice Returns the stored position for a user in a given market.
    function getPosition(address user, uint256 marketId)
        external
        view
        returns (OrderTypes.Position memory)
    {
        return positions[user][marketId];
    }

    /// @notice Returns the current health factor for a user's position.
    ///         Returns type(uint256).max if there is no open position.
    /// @param user     The position owner
    /// @param marketId The market ID
    /// @return healthFactor 1e18-scaled; < 1e18 means liquidatable
    function getHealthFactor(address user, uint256 marketId)
        external
        view
        returns (uint256)
    {
        return _computeHealthFactor(user, marketId);
    }

    /// @dev Internal health-factor computation (shared by external view and liquidate())
    function _computeHealthFactor(address user, uint256 marketId)
        internal
        view
        returns (uint256)
    {
        OrderTypes.Position memory pos = positions[user][marketId];
        if (pos.size == 0) return type(uint256).max;
        uint256 currentPrice = _getOraclePriceView();
        return PositionMath.getHealthFactor(pos, currentPrice, maintenanceMarginRatio);
    }

    /// @notice Returns the current oracle price scaled to 1e18.
    function getOraclePrice() external view returns (uint256) {
        return _getOraclePriceView();
    }

    // ─── Admin functions ──────────────────────────────────────────────────────

    /// @notice Sets the authorised off-chain settlement engine address
    /// @param engine New settlement engine address
    function setSettlementEngine(address engine) external onlyOwner {
        settlementEngine = engine;
    }

    /// @notice Adds or updates a market configuration
    /// @param marketId The market identifier
    /// @param config   Market parameters
    function addMarket(uint256 marketId, MarketConfig calldata config) external onlyOwner {
        markets[marketId] = config;
    }

    /// @notice Replaces the Chainlink oracle
    /// @param oracle_ New oracle address
    function setOracle(address oracle_) external onlyOwner {
        oracle = IOracle(oracle_);
    }

    /// @notice Sets the LiquidationEngine address
    /// @param engine New LiquidationEngine address
    function setLiquidationEngine(address engine) external onlyOwner {
        liquidationEngine = engine;
    }

    /// @notice Sets the maintenance margin ratio
    /// @param ratio New ratio, 1e18 precision (e.g. 0.05e18 = 5%)
    function setMaintenanceMarginRatio(uint256 ratio) external onlyOwner {
        maintenanceMarginRatio = ratio;
    }

    /// @notice Allows owner to seed the protocol fee pool
    /// @param amount USDC amount to deposit into the fee pool
    function fundFeePool(uint256 amount) external onlyOwner {
        IERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), amount);
        feePool += amount;
    }

    /// @notice Pauses the protocol
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the protocol
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Core logic for opening a position for any address (used by openPosition + settleTrade)
    function _openPositionFor(
        address user,
        uint256 marketId,
        bool isLong,
        uint256 size,
        uint256 collateral
    ) internal {
        MarketConfig memory cfg = markets[marketId];
        if (!cfg.active) revert MarketNotActive(marketId);
        if (size == 0) revert ZeroAmount();
        if (collateral == 0) revert ZeroAmount();

        // Enforce maximum leverage: collateral must be ≥ size / maxLeverage
        uint256 requiredMargin = (size * 1e18) / cfg.maxLeverage;
        if (collateral < requiredMargin) revert InsufficientCollateral(collateral, requiredMargin);

        uint256 leverage = (size * 1e18) / collateral;
        if (leverage > cfg.maxLeverage) revert ExceedsMaxLeverage(leverage, cfg.maxLeverage);

        // One position per user per market
        if (positions[user][marketId].size > 0) revert PositionAlreadyOpen();

        uint256 entryPrice = _getOraclePrice();

        // Lock margin in vault
        vault.lockMargin(user, collateral);

        // Mint ERC-1155 position token
        positionManager.mint(user, marketId, 1);

        // Persist position
        positions[user][marketId] = OrderTypes.Position({
            size: size,
            collateral: collateral,
            entryPrice: entryPrice,
            leverage: leverage,
            isLong: isLong,
            openedAt: block.timestamp
        });

        emit PositionOpened(user, marketId, isLong, size, collateral, entryPrice);
    }

    /// @dev Core logic for closing a position for any address
    function _closePositionFor(address user, uint256 marketId) internal {
        OrderTypes.Position memory pos = positions[user][marketId];
        if (pos.size == 0) revert NoOpenPosition();

        uint256 exitPrice = _getOraclePrice();
        int256 pnl = PositionMath.getUnrealisedPnL(pos, exitPrice);

        vault.releaseMargin(user, pos.collateral);

        if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            // Cap loss at collateral (can't lose more than deposited)
            uint256 actualLoss = loss > pos.collateral ? pos.collateral : loss;
            // Burn shares, forward USDC to this contract (feePool)
            vault.settleLoss(user, actualLoss);
            feePool += actualLoss;
        } else if (pnl > 0) {
            uint256 profit = uint256(pnl);
            // Pay profit from fee pool; cap at available pool balance
            uint256 actualProfit = profit > feePool ? feePool : profit;
            if (actualProfit > 0) {
                feePool -= actualProfit;
                // Approve vault and deposit on behalf of user (mints new shares)
                IERC20(vault.asset()).approve(address(vault), actualProfit);
                // ERC-4626 deposit: transfers from this contract, mints shares to user
                // Requires this contract to hold the USDC (sourced from feePool)
                _depositProfitToVault(user, actualProfit);
            }
        }

        positionManager.burn(user, marketId, 1);
        delete positions[user][marketId];

        emit PositionClosed(user, marketId, pnl, exitPrice);
    }

    /// @dev Deposits `profit` USDC from this contract into the vault, crediting `user`
    ///      Uses standard ERC-4626 deposit (msg.sender = this, receiver = user)
    function _depositProfitToVault(address user, uint256 profit) internal {
        IERC20 asset = IERC20(vault.asset());
        asset.approve(address(vault), profit);
        // ERC-4626 deposit pulls from msg.sender (this contract) and mints shares to `user`
        // We use the low-level interface; cast vault to the OZ ERC4626 deposit signature
        (bool success,) = address(vault).call(
            abi.encodeWithSignature("deposit(uint256,address)", profit, user)
        );
        // If deposit fails (e.g. paused), leave profit in feePool rather than revert
        if (!success) {
            feePool += profit;
            asset.approve(address(vault), 0);
        }
    }

    /// @dev Fetches and validates the oracle price. Reverts on stale or invalid data.
    ///      Used in state-changing functions.
    function _getOraclePrice() internal view returns (uint256) {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
        ) = oracle.latestRoundData();

        if (answer <= 0) revert InvalidOracleAnswer(answer);
        // Staleness check: price must be updated within the last hour
        if (block.timestamp - updatedAt > MAX_ORACLE_AGE) {
            revert StaleOracle(updatedAt, block.timestamp);
        }

        // Chainlink ETH/USD: 8 decimals → scale to 1e18
        return uint256(answer) * CHAINLINK_SCALE;
    }

    /// @dev View-safe version of _getOraclePrice (no revert on stale in view context)
    function _getOraclePriceView() internal view returns (uint256) {
        (, int256 answer, , uint256 updatedAt,) = oracle.latestRoundData();
        if (answer <= 0) return 0;
        if (block.timestamp - updatedAt > MAX_ORACLE_AGE) return 0;
        return uint256(answer) * CHAINLINK_SCALE;
    }
}

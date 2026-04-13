// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {CollateralVault} from "../../src/CollateralVault.sol";
import {PerpEngine} from "../../src/PerpEngine.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {LiquidationEngine} from "../../src/LiquidationEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─── Mock ERC-20 (18 decimals, mimics test USDC) ──────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─── Mock Oracle (AggregatorV3Interface) ─────────────────────────────────────

contract MockOracle is IOracle {
    int256 public price;
    uint256 public updatedAt;
    uint8 public constant override decimals = 8;

    constructor(int256 initialPrice) {
        price = initialPrice;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 ts) external {
        updatedAt = ts;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        )
    {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

// ─── BaseTest — shared setup for all GlacierX tests ──────────────────────────

contract BaseTest is Test {
    // Protocol contracts
    MockUSDC    internal usdc;
    CollateralVault internal vault;
    PositionManager internal posManager;
    LiquidationEngine internal liqEngine;
    PerpEngine  internal engine;
    MockOracle  internal oracle;

    // Test actors
    address internal owner   = makeAddr("owner");
    address internal alice   = makeAddr("alice");
    address internal bob     = makeAddr("bob");
    address internal keeper  = makeAddr("keeper");

    // Constants
    uint256 internal constant ETH_PRICE       = 2000e8;  // $2,000 with 8 decimals
    uint256 internal constant MARKET_ETH      = 1;
    uint256 internal constant MAINTENANCE_BPS = 0.05e18; // 5%

    function setUp() public virtual {
        vm.startPrank(owner);

        // 1. Deploy mock token
        usdc = new MockUSDC();

        // 2. Deploy vault
        vault = new CollateralVault(
            IERC20(address(usdc)),
            "GlacierX USDC Vault",
            "gxUSDC",
            owner
        );

        // 3. Deploy position manager
        posManager = new PositionManager(owner);

        // 4. Deploy liquidation engine (perpEngine set later)
        liqEngine = new LiquidationEngine(address(0), 500);

        // 5. Deploy oracle
        oracle = new MockOracle(int256(ETH_PRICE));

        // 6. Deploy perp engine
        engine = new PerpEngine(
            vault,
            oracle,
            posManager,
            MAINTENANCE_BPS
        );

        // 7. Wire up
        vault.setPerpEngine(address(engine));
        posManager.setPerpEngine(address(engine));
        liqEngine.setPerpEngine(address(engine));
        engine.setLiquidationEngine(address(liqEngine));

        // 8. Add ETH market (market 1, 20x max leverage)
        engine.addMarket(
            MARKET_ETH,
            IPerpEngine.MarketConfig({
                active: true,
                maxLeverage: 20e18,
                makerFee: 0.0002e18,
                takerFee: 0.0005e18
            })
        );

        vm.stopPrank();

        // Seed actors with USDC
        usdc.mint(alice, 10_000e18);
        usdc.mint(bob,   10_000e18);
        usdc.mint(owner, 100_000e18);

        // Pre-approve vault
        vm.prank(alice); usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(vault), type(uint256).max);
        vm.prank(owner); usdc.approve(address(vault), type(uint256).max);

        // Fund engine fee pool so it can pay out profits
        vm.startPrank(owner);
        usdc.approve(address(engine), type(uint256).max);
        engine.fundFeePool(50_000e18);
        vm.stopPrank();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Deposits `amount` USDC into vault for `user`; returns shares minted
    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit(amount, user);
    }

    /// @dev Opens a position for `user`
    function _openPosition(
        address user,
        uint256 marketId,
        bool isLong,
        uint256 size,
        uint256 collateral
    ) internal {
        vm.prank(user);
        engine.openPosition(marketId, isLong, size, collateral);
    }

    /// @dev Closes the position for `user` in `marketId`
    function _closePosition(address user, uint256 marketId) internal {
        vm.prank(user);
        engine.closePosition(marketId);
    }
}

// Re-export IPerpEngine for convenience
import {IPerpEngine} from "../../src/interfaces/IPerpEngine.sol";

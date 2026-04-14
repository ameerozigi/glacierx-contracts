// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../src/CollateralVault.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {IPerpEngine} from "../src/interfaces/IPerpEngine.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";

/// @title Deploy
/// @notice Deploys CollateralVault, PositionManager, LiquidationEngine, and PerpEngine
///         to Arbitrum One, wires dependencies, and registers the ETH market.
contract Deploy is Script {
    // ─── Arbitrum mainnet constants ────────────────────────────────────────────

    /// @dev USDC on Arbitrum One (6 decimals)
    address internal constant USDC_ARBITRUM = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @dev Chainlink ETH/USD feed on Arbitrum One (8 decimals)
    address internal constant CHAINLINK_ETH_USD_ARBITRUM = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    // ─── Protocol parameters ──────────────────────────────────────────────────

    uint256 internal constant MAINTENANCE_MARGIN_RATIO = 0.05e18; // 5%
    uint256 internal constant LIQUIDATOR_REWARD_BPS    = 500;     // 5%

    // ETH market config
    uint256 internal constant MARKET_ETH_ID    = 1;
    uint256 internal constant MARKET_MAX_LEV   = 20e18;
    uint256 internal constant MARKET_MAKER_FEE = 0.0002e18;  // 0.02%
    uint256 internal constant MARKET_TAKER_FEE = 0.0005e18;  // 0.05%

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("=== GlacierX Protocol Deployment ===");
        console.log("Deployer:  ", deployer);
        console.log("Chain ID:  ", block.chainid);
        console.log("Block:     ", block.number);
        console.log("");

        vm.startBroadcast(deployerKey);

        // ── 1. CollateralVault ──────────────────────────────────────────────
        CollateralVault vault = new CollateralVault(
            IERC20(USDC_ARBITRUM),
            "GlacierX USDC Vault",
            "gxUSDC",
            deployer
        );
        console.log("CollateralVault: ", address(vault));

        // ── 2. PositionManager ─────────────────────────────────────────────
        PositionManager posManager = new PositionManager(deployer);
        console.log("PositionManager: ", address(posManager));

        // ── 3. LiquidationEngine ───────────────────────────────────────────
        LiquidationEngine liqEngine = new LiquidationEngine(address(0), LIQUIDATOR_REWARD_BPS);
        console.log("LiquidationEngine:", address(liqEngine));

        // ── 4. PerpEngine ──────────────────────────────────────────────────
        PerpEngine perpEngine = new PerpEngine(
            vault,
            IOracle(CHAINLINK_ETH_USD_ARBITRUM),
            posManager,
            MAINTENANCE_MARGIN_RATIO
        );
        console.log("PerpEngine:      ", address(perpEngine));

        // ── 5. Wire up dependencies ────────────────────────────────────────
        liqEngine.setPerpEngine(address(perpEngine));
        vault.setPerpEngine(address(perpEngine));
        posManager.setPerpEngine(address(perpEngine));
        perpEngine.setLiquidationEngine(address(liqEngine));

        // ── 6. Add ETH market ──────────────────────────────────────────────
        perpEngine.addMarket(
            MARKET_ETH_ID,
            IPerpEngine.MarketConfig({
                active: true,
                maxLeverage: MARKET_MAX_LEV,
                makerFee: MARKET_MAKER_FEE,
                takerFee: MARKET_TAKER_FEE
            })
        );
        console.log("ETH market added (marketId=1)");

        vm.stopBroadcast();

        // ── 7. Summary ────────────────────────────────────────────────────
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("CollateralVault  :", address(vault));
        console.log("PositionManager  :", address(posManager));
        console.log("LiquidationEngine:", address(liqEngine));
        console.log("PerpEngine       :", address(perpEngine));
        console.log("");
        console.log("Next: run DeploySafe.s.sol to deploy the Gnosis Safe and transfer ownership.");
    }
}

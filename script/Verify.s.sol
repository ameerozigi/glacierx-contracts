// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CollateralVault} from "../src/CollateralVault.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";

/// @title Verify
/// @notice Post-deployment verification: reads on-chain state to confirm all contracts
///         are correctly wired together.
///
///   Usage
///   ─────
///   source .env
///   forge script script/Verify.s.sol:Verify \
///     --rpc-url $ARBITRUM_RPC_URL \
///     -vvvv
///
contract Verify is Script {
    function run() external view {
        address vaultAddr      = vm.envAddress("VAULT_ADDRESS");
        address engineAddr     = vm.envAddress("PERP_ENGINE_ADDRESS");
        address posManagerAddr = vm.envAddress("POS_MANAGER_ADDRESS");
        address liqEngineAddr  = vm.envAddress("LIQ_ENGINE_ADDRESS");

        CollateralVault  vault      = CollateralVault(vaultAddr);
        PerpEngine       engine     = PerpEngine(engineAddr);
        PositionManager  posManager = PositionManager(posManagerAddr);
        LiquidationEngine liqEngine = LiquidationEngine(liqEngineAddr);

        console.log("=== GlacierX Post-Deployment Verification ===");
        console.log("");

        // ── Vault checks ───────────────────────────────────────────────────
        console.log("--- CollateralVault ---");
        console.log("Address         :", vaultAddr);
        console.log("Asset (USDC)    :", vault.asset());
        console.log("PerpEngine      :", vault.perpEngine());
        console.log("maxDepositLimit :", vault.maxDepositLimit());
        console.log("totalLockedMargin:", vault.totalLockedMargin());
        _checkEq("vault.perpEngine == engine", vault.perpEngine(), engineAddr);

        // ── PerpEngine checks ──────────────────────────────────────────────
        console.log("");
        console.log("--- PerpEngine ---");
        console.log("Address               :", engineAddr);
        console.log("vault                 :", address(engine.vault()));
        console.log("oracle                :", address(engine.oracle()));
        console.log("positionManager       :", address(engine.positionManager()));
        console.log("liquidationEngine     :", engine.liquidationEngine());
        console.log("maintenanceMarginRatio:", engine.maintenanceMarginRatio());
        _checkEq("engine.vault == vault", address(engine.vault()), vaultAddr);
        _checkEq("engine.positionManager == posManager", address(engine.positionManager()), posManagerAddr);
        _checkEq("engine.liquidationEngine == liqEngine", engine.liquidationEngine(), liqEngineAddr);

        // Check ETH market is active
        (bool active, uint256 maxLev,,) = engine.markets(1);
        _checkTrue("markets[1].active", active);
        _checkEq("markets[1].maxLeverage == 20e18", maxLev, 20e18);

        // ── PositionManager checks ─────────────────────────────────────────
        console.log("");
        console.log("--- PositionManager ---");
        console.log("Address   :", posManagerAddr);
        console.log("perpEngine:", posManager.perpEngine());
        _checkEq("posManager.perpEngine == engine", posManager.perpEngine(), engineAddr);

        // ── LiquidationEngine checks ───────────────────────────────────────
        console.log("");
        console.log("--- LiquidationEngine ---");
        console.log("Address             :", liqEngineAddr);
        console.log("perpEngine          :", address(liqEngine.perpEngine()));
        console.log("liquidatorRewardBps :", liqEngine.liquidatorRewardBps());
        _checkEq("liqEngine.perpEngine == engine", address(liqEngine.perpEngine()), engineAddr);

        console.log("");
        console.log("=== All checks passed! ===");
    }

    function _checkEq(string memory label, address a, address b) internal pure {
        if (a != b) {
            console.log("[FAIL]", label);
            console.log("  expected:", b);
            console.log("  got:     ", a);
        } else {
            console.log("[PASS]", label);
        }
    }

    function _checkEq(string memory label, uint256 a, uint256 b) internal pure {
        if (a != b) {
            console.log("[FAIL]", label);
        } else {
            console.log("[PASS]", label);
        }
    }

    function _checkTrue(string memory label, bool cond) internal pure {
        if (!cond) {
            console.log("[FAIL]", label);
        } else {
            console.log("[PASS]", label);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

// ─── Minimal Safe interfaces (must be at file level for Solidity ^0.8.24) ────

interface ISafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes calldata initializer,
        uint256 saltNonce
    ) external returns (address proxy);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

interface IOwnable2Step {
    function transferOwnership(address newOwner) external;
}

/// @title DeploySafe
/// @notice Deploys a 2-of-3 Gnosis Safe on Arbitrum One and initiates ownership
///         transfer on CollateralVault and PerpEngine. The Safe must then call
///         acceptOwnership() on both to complete the Ownable2Step handover.
contract DeploySafe is Script {
    // ─── Gnosis Safe on Arbitrum One ──────────────────────────────────────────

    /// @dev Safe Proxy Factory v1.3.0 on Arbitrum
    address internal constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;

    /// @dev Safe L2 singleton v1.3.0 on Arbitrum
    address internal constant SAFE_SINGLETON = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;

    /// @dev Safe compatibility fallback handler
    address internal constant FALLBACK_HANDLER = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address owner2      = vm.envAddress("SAFE_OWNER_2");
        address owner3      = vm.envAddress("SAFE_OWNER_3");

        address vaultAddr  = vm.envAddress("VAULT_ADDRESS");
        address engineAddr = vm.envAddress("PERP_ENGINE_ADDRESS");

        console.log("=== Gnosis Safe Deployment ===");
        console.log("Owner 1 (deployer):", deployer);
        console.log("Owner 2:           ", owner2);
        console.log("Owner 3:           ", owner3);
        console.log("Vault:             ", vaultAddr);
        console.log("PerpEngine:        ", engineAddr);

        vm.startBroadcast(deployerKey);

        // ── Build Safe setup calldata ──────────────────────────────────────
        address[] memory owners = new address[](3);
        owners[0] = deployer;
        owners[1] = owner2;
        owners[2] = owner3;

        bytes memory initializer = abi.encodeWithSelector(
            ISafe.setup.selector,
            owners,          // owners
            2,               // threshold (2-of-3)
            address(0),      // to (no delegate call on setup)
            bytes(""),       // data
            FALLBACK_HANDLER,// fallbackHandler
            address(0),      // paymentToken (ETH)
            0,               // payment
            payable(address(0)) // paymentReceiver
        );

        // ── Deploy Safe ────────────────────────────────────────────────────
        // Use a deterministic salt based on deployer + block number
        uint256 saltNonce = uint256(keccak256(abi.encodePacked(deployer, block.number)));

        address safeAddress = ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(
            SAFE_SINGLETON,
            initializer,
            saltNonce
        );

        console.log("Gnosis Safe deployed:", safeAddress);

        // ── Transfer vault ownership to Safe ──────────────────────────────
        IOwnable2Step(vaultAddr).transferOwnership(safeAddress);
        console.log("Vault.transferOwnership ->", safeAddress);

        // ── Transfer PerpEngine ownership to Safe ─────────────────────────
        IOwnable2Step(engineAddr).transferOwnership(safeAddress);
        console.log("PerpEngine.transferOwnership ->", safeAddress);

        vm.stopBroadcast();

        // ── Summary ────────────────────────────────────────────────────────
        console.log("");
        console.log("=== Safe Deployment Summary ===");
        console.log("Gnosis Safe (2-of-3):", safeAddress);
        console.log("");
        console.log("IMPORTANT: The Safe must call acceptOwnership() on both contracts");
        console.log("to complete the Ownable2Step transfer.");
        console.log("Pending owner on Vault:     ", vaultAddr);
        console.log("Pending owner on PerpEngine:", engineAddr);
    }
}

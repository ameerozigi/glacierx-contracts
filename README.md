# GlacierX Protocol

Production-ready perpetual DEX contracts built on Arbitrum One.
ERC-4626 collateral vault + on-chain perp engine, owned by a Gnosis Safe 2-of-3 multisig.

---

## Deployed Contract Addresses (Arbitrum One)

| Contract            | Address |
|---------------------|---------|
| CollateralVault     | TBD     |
| PerpEngine          | TBD     |
| PositionManager     | TBD     |
| LiquidationEngine   | TBD     |
| Gnosis Safe (Owner) | TBD     |

> Addresses will be populated after mainnet deployment. Contracts are verified on Arbiscan.

---

## Architecture

```
                      ┌──────────────────────┐
                      │   Gnosis Safe (2/3)  │  ← Owner of all admin functions
                      └──────────┬───────────┘
                                 │ owns
              ┌──────────────────┼──────────────────┐
              │                  │                  │
      ┌───────▼──────┐  ┌────────▼───────┐  ┌──────▼────────────┐
      │CollateralVault│  │  PerpEngine    │  │ LiquidationEngine │
      │  (ERC-4626)  │◄─┤  (core logic)  │◄─┤  (keeper entry)   │
      └───────┬──────┘  └────────┬───────┘  └───────────────────┘
              │                  │
     holds    │           ┌──────▼────────┐
     USDC     │           │PositionManager│
              │           │  (ERC-1155)   │
              │           └───────────────┘
              │
     ┌────────▼────────┐
     │  Chainlink      │
     │  ETH/USD Oracle │
     └─────────────────┘
```

### Contract Relationships

- **CollateralVault** — ERC-4626 vault holding user USDC. Only `PerpEngine` can lock/release margin. Withdrawals are blocked for locked margin.
- **PerpEngine** — Opens/closes positions, validates oracle prices, settles PnL against the fee pool, and exposes `liquidate()` to `LiquidationEngine`.
- **PositionManager** — ERC-1155 token registry. `balanceOf(user, marketId) == 1` ↔ open position.
- **LiquidationEngine** — Public entry point for keepers. Checks health factor, calls `PerpEngine.liquidate()`, emits reward event.

---

## ERC-4626 Compliance

The `CollateralVault` inherits OpenZeppelin v5's `ERC4626` and overrides the following functions:

| Function | Override Reason |
|----------|----------------|
| `maxWithdraw(owner)` | Caps at `convertToAssets(balance) − lockedMargin` — users cannot withdraw locked margin |
| `maxRedeem(owner)` | Caps at `balance − convertToShares(lockedMargin)` — share equivalent of the above |
| `maxDeposit(receiver)` | Returns 0 when paused; enforces `maxDepositLimit` cap |
| `maxMint(receiver)` | Derived from `maxDeposit` |
| `_withdraw(...)` | Pre-flight check: reverts `InsufficientFreeMargin` if `assets > freeMargin` |
| `_deposit(...)` | Pre-flight check: reverts `ExceedsDepositLimit`; blocked when paused |

The vault maintains a strict 1:1 asset/share ratio unless yield is accrued. No fee-on-deposit/withdrawal.

---

## Safe Ownership

All admin functions on `CollateralVault` and `PerpEngine` use `Ownable2Step`:

1. `transferOwnership(safeAddress)` — initiates the transfer (called by deployer)
2. `acceptOwnership()` — Safe must sign and execute this transaction to complete the transfer

**Safe configuration:** 2-of-3 multisig
- Owner 1: Deployer
- Owner 2: `SAFE_OWNER_2` (from env)
- Owner 3: `SAFE_OWNER_3` (from env)

Admin-only functions protected:
- `vault.setPerpEngine`, `vault.setMaxDepositLimit`, `vault.pause/unpause`
- `engine.addMarket`, `engine.setOracle`, `engine.setSettlementEngine`, `engine.fundFeePool`

---

## Local Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Git

### Setup

```bash
git clone https://github.com/ameerozigi/glacierx-contracts
cd glacierx-contracts

# Install dependencies
forge install

# Copy and configure env
cp .env.example .env

# Build
forge build

# Run tests
forge test -vvv

# Gas report
forge test --gas-report
```

### Run with local fork

```bash
source .env
anvil --fork-url $ARBITRUM_RPC_URL
```

---

## Test Suite

```
test/
├── CollateralVault.t.sol       Unit + fuzz (ERC-4626, margin, pause, limits)
├── PerpEngine.t.sol            Unit + fuzz (open/close, liquidation, oracle)
├── LiquidationEngine.t.sol     Unit + optional Arbitrum fork test
└── invariants/
    └── VaultInvariants.t.sol   Stateful fuzzing (4 invariants, 500 runs × depth 100)
```

Run specific suites:

```bash
# Unit tests only
forge test --match-contract CollateralVaultTest -vvv

# Fuzz with more runs
forge test --match-contract PerpEngineTest --fuzz-runs 50000

# Invariant tests
forge test --match-contract VaultInvariants -vvv

# Fork tests (requires ARBITRUM_RPC_URL)
forge test --match-test testFork_ --fork-url $ARBITRUM_RPC_URL
```

---

## Deployment

### 1. Deploy Core Contracts

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $ARBITRUM_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ARBISCAN_API_KEY \
  -vvvv
```

### 2. Deploy Gnosis Safe + Transfer Ownership

```bash
# Set addresses from step 1 in .env:
# VAULT_ADDRESS=0x...
# PERP_ENGINE_ADDRESS=0x...

forge script script/DeploySafe.s.sol:DeploySafe \
  --rpc-url $ARBITRUM_RPC_URL \
  --broadcast \
  -vvvv
```

### 3. Accept Ownership via Safe

After `DeploySafe.s.sol`, the Safe must call `acceptOwnership()` on both contracts.
Create a Safe transaction batch at [app.safe.global](https://app.safe.global):

```
CollateralVault.acceptOwnership()
PerpEngine.acceptOwnership()
```

### 4. Post-Deploy Verification

```bash
# Set all addresses in .env, then:
forge script script/Verify.s.sol:Verify --rpc-url $ARBITRUM_RPC_URL -vvvv
```

---

## Arbiscan Verification

```bash
# CollateralVault
forge verify-contract <VAULT_ADDRESS> \
  src/CollateralVault.sol:CollateralVault \
  --chain-id 42161 \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,string,string,address)" \
    0xaf88d065e77c8cC2239327C5EDb3A432268e5831 \
    "GlacierX USDC Vault" "gxUSDC" <DEPLOYER_ADDRESS>)

# PerpEngine
forge verify-contract <ENGINE_ADDRESS> \
  src/PerpEngine.sol:PerpEngine \
  --chain-id 42161 \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint256)" \
    <VAULT_ADDRESS> \
    0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612 \
    <POS_MANAGER_ADDRESS> \
    50000000000000000)

# PositionManager
forge verify-contract <POS_MANAGER_ADDRESS> \
  src/PositionManager.sol:PositionManager \
  --chain-id 42161 \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDRESS>)

# LiquidationEngine
forge verify-contract <LIQ_ENGINE_ADDRESS> \
  src/LiquidationEngine.sol:LiquidationEngine \
  --chain-id 42161 \
  --etherscan-api-key $ARBISCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,uint256)" <ENGINE_ADDRESS> 500)
```

---

## Gas Report

Run `forge test --gas-report` to generate. Key functions:

| Function                  | Estimated Gas |
|---------------------------|---------------|
| `vault.deposit`           | ~95,000        |
| `vault.withdraw`          | ~85,000        |
| `engine.openPosition`     | ~160,000       |
| `engine.closePosition`    | ~140,000       |
| `liqEngine.liquidate`     | ~130,000       |

> Exact numbers are in the gas report output from `forge test --gas-report`.

---

## Security Considerations

- All arithmetic uses Solidity 0.8.24 checked math (no `unchecked` blocks).
- Oracle staleness: prices older than 1 hour cause revert.
- Reentrancy: all state-changing functions use `nonReentrant` (ERC-4626 hooks + PerpEngine).
- Custom errors everywhere — no `require(condition, "string")`.
- `Ownable2Step` prevents accidental ownership transfer to wrong address.
- All admin functions require the Gnosis Safe 2-of-3 threshold.

---

## License

MIT

# Based Loans — Smart Contracts

Based Loans is a zero-liquidation lending protocol where borrowers post collateral and repay a fixed buyback price before expiry, or lenders claim the collateral.

## How It Works

1. Borrower deposits collateral
2. Lenders provide USDC (matched via FIFO queue)
3. Borrower repays a fixed amount before expiry
4. If not repaid, lenders claim the collateral

**Core properties:**
- No liquidations
- Fixed terms and fixed cost
- FIFO lender matching
- USDC-only deposits

Idle lender funds may be wrapped into mUSDC to remain productive between loan matches (see /vaults).

For detailed contract mechanics and edge cases, see [AUDIT.md](AUDIT.md).

## Contracts

| Contract | Description |
|---|---|
| `Core.sol` | Loan lifecycle: origination, partial/full buyback, collateral claims on default. |
| `LendingLedger.sol` | Lender deposits, FIFO matching queue, loan settlement, proceeds tracking. Holds all USDC. |
| `AssetManager.sol` | Collateral asset configuration: oracle sources, LTV caps, exposure limits, risk parameters. |
| `OracleManager.sol` | Multi-source price aggregation (Pyth real-time + V3-compatible TWAP). |
| `FeeDistributor.sol` | Three-tier fee distribution: protocol treasury, automated burns, per-asset growth incentives. |
| `AutoBurnSplitter.sol` | Receives tier-2 fees. Vault path (mUSDC rate growth) and DEX swap path (MONSTRO burns). |

### Libraries

| File | Description |
|---|---|
| `libraries/FullMath.sol` | 512-bit multiplication and division for precise price calculations. |
| `libraries/TickMath.sol` | Tick-to-sqrtPrice conversion for V3-compatible TWAP decoding. |

### Interfaces

| File | Description |
|---|---|
| `interfaces/IOracleAdapter.sol` | Standard interface all oracle adapters implement. |
| `interfaces/IERC20Minimal.sol` | Minimal ERC-20 interface. |
| `interfaces/IERC4626Minimal.sol` | Minimal ERC-4626 interface for vault integration. |

### Oracle Adapters

| Adapter | Description |
|---|---|
| `adapters/UniswapV3.sol` | TWAP oracle for Uniswap V3 and compatible DEXes (Aerodrome, Alien Base, PancakeSwap). |
| `adapters/Pyth.sol` | Real-time price oracle via Pyth Network. |
| `adapters/Algebra.sol` | TWAP oracle for Algebra V2 forks (TrebleSwap, HydrexFi). |

## Architecture

```
Borrower → Core (collateral in, USDC out)
              ↓
         LendingLedger (FIFO queue matching, vault wrapping)
              ↓
         mUSDC Vault (idle yield via ERC-4626, see /vaults)
              
Fees → FeeDistributor → AutoBurnSplitter → mUSDC rate growth + MONSTRO burns
                       → Protocol treasury
                       → Growth incentives

Prices → OracleManager → Adapters (Pyth, UniswapV3, Algebra)
                        → AssetManager (LTV, exposure, config)
```

## Access Control

- **Owner**: Monstro DAO LLC multisig (5-of-7). Full control over all contracts.
- **Operator**: Monstro Labs multisig (2-of-2). Limited to: pause Cores, manage growth subscriptions, configure assets. Cannot authorize/remove Cores, change tier config, modify vault settings, or move user funds.

## Audits

| Contract | Auditor | Status |
|---|---|---|
| Core | Hashlock | In progress |
| LendingLedger | Hashlock | In progress |
| AssetManager | Hashlock | In progress |
| OracleManager | Hashlock | In progress |
| FeeDistributor | Hashlock | In progress |
| AutoBurnSplitter | Hashlock | In progress |
| UniswapV3 Adapter | Hashlock | In progress |
| Pyth Adapter | Hashlock | In progress |
| Algebra Adapter | Hashlock | In progress |

## Deployments (Base Mainnet, chainId: 8453)

| Contract | Address |
|---|---|
| Core | Pending audit completion |
| LendingLedger | Pending audit completion |
| AssetManager | Pending audit completion |
| OracleManager | Pending audit completion |
| FeeDistributor | Pending audit completion |
| AutoBurnSplitter | Pending audit completion |

## License

MIT

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
| `adapters/RatioDerived.sol` | Prices a token as a fixed or on-chain ratio of a base token already configured in AssetManager. Supports escrowed/discounted tokens (fixed ratio) and LST-style tokens with a live conversion rate (on-chain ratio via selector call). |

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

Prices → OracleManager → Adapters (Pyth, UniswapV3, Algebra, RatioDerived)
                        → AssetManager (LTV, exposure, config)
```

## Access Control

- **Owner**: Monstro DAO LLC multisig (5-of-7). Full control over all contracts.
- **Operator**: Monstro Labs multisig (2-of-2). Limited to: pause Cores, manage growth subscriptions, configure assets. Cannot authorize/remove Cores, change tier config, modify vault settings, or move user funds.

## Audits

| Contract | Auditor | Status |
|---|---|---|
| Core | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| LendingLedger | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| AssetManager | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| OracleManager | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| FeeDistributor | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| AutoBurnSplitter | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| UniswapV3 Adapter | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| Pyth Adapter | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| Algebra Adapter | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| RatioDerived Adapter | — | Pending |

## Deployments (Base Mainnet, chainId: 8453)

| Contract | Address |
|---|---|
| Core | [`0x88Df29c4c2D564A2996d99bbe3C85da505881Aa3`](https://basescan.org/address/0x88Df29c4c2D564A2996d99bbe3C85da505881Aa3) |
| LendingLedger | [`0x278CfeaDeAaCBe88f24692ef199247cF17c5141F`](https://basescan.org/address/0x278CfeaDeAaCBe88f24692ef199247cF17c5141F) |
| AssetManager | [`0xA93407aE856Ee3241550292B8A8B7cF8B98b1212`](https://basescan.org/address/0xA93407aE856Ee3241550292B8A8B7cF8B98b1212) |
| OracleManager | [`0xeAbD8B03aC04Dfe8b31ADD7f0f760462FD6A8C17`](https://basescan.org/address/0xeAbD8B03aC04Dfe8b31ADD7f0f760462FD6A8C17) |
| FeeDistributor | [`0x754D694d81C96D134cd33f3F164bb1084Df019e5`](https://basescan.org/address/0x754D694d81C96D134cd33f3F164bb1084Df019e5) |
| AutoBurnSplitter | [`0x10cfdbed46960370b45686cf58babd67e4d656a4`](https://basescan.org/address/0x10cfdbed46960370b45686cf58babd67e4d656a4) |
| UniswapV3 Adapter | [`0xfcDafF6e23d22d430A19aabDefDb9B2Aa2975ba2`](https://basescan.org/address/0xfcDafF6e23d22d430A19aabDefDb9B2Aa2975ba2) |
| Algebra Adapter | [`0x218CDFd5802fF3d6a22ffB14A41C3311EBfc2908`](https://basescan.org/address/0x218CDFd5802fF3d6a22ffB14A41C3311EBfc2908) |
| Pyth Adapter | [`0x85Ad3d6817646143e7076096D4A053ED38eFc958`](https://basescan.org/address/0x85Ad3d6817646143e7076096D4A053ED38eFc958) |
| RatioDerived Adapter | [`0xB5391e137cd3Bb9dda02c164B599c95Af0F88b52`](https://basescan.org/address/0xB5391e137cd3Bb9dda02c164B599c95Af0F88b52) |

## License

MIT

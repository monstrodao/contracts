# Monstro DAO LLC — Smart Contracts

Canonical smart contracts for the **Monstro DAO LLC** protocol on Base.

## Repository Structure

| Directory | Contract | Description |
|---|---|---|
| `token/` | `MonstroToken.sol` | MONSTRO protocol token (ERC-20) |
| `staking/` | `MonstroStaking.sol` | Tiered staking with time-weighted rewards and early-exit penalties |
| `vaults/` | `MonstroUSDC.sol` | ERC-4626 yield-bearing USDC vault (mUSDC) |

## Contracts

### MonstroToken

ERC-20 protocol token. Deployed on Base.

### MonstroStaking

Staking contract with tiered reward multipliers and configurable penalty curves for early unstaking. Stakers earn MONSTRO rewards proportional to their stake duration and tier.

### MonstroUSDC (mUSDC)

ERC-4626 vault that wraps USDC into mUSDC shares. The exchange rate only increases over time through two mechanisms:

1. **Immutable fees.** A 0.05% mint fee and 0.25% redeem fee stay in the vault on every deposit/withdrawal, increasing the share price for all holders.
2. **Protocol revenue.** External USDC deposits (e.g., from Based Loans fee distribution) increase totalAssets without minting new shares.

Key properties:
- Non-upgradeable. No owner, no admin functions, no pause mechanism.
- Fees are hardcoded constants, not configurable parameters.
- Constructor seeds 1 USDC to a dead address, mitigating ERC-4626 inflation attacks.
- Built on OpenZeppelin ERC4626 v5.

mUSDC is the first Monstro DAO LLC primitive. Based Loans is the first integration, using mUSDC to keep idle lender capital productive between loan matches. Future protocols can integrate independently.

## Audits

| Contract | Auditor | Status |
|---|---|---|
| MonstroToken | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| MonstroStaking | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| MonstroUSDC | Hashlock | In progress |

## Deployments (Base Mainnet)

| Contract | Address |
|---|---|
| MonstroToken | [`0x1d3bE1CC80cA89DDbabe5b5C254AF63200e708f7`](https://basescan.org/address/0x1d3bE1CC80cA89DDbabe5b5C254AF63200e708f7) |
| MonstroStaking | [`0x99741758A3BCD7A95B80845E124C5C499DF4742b`](https://basescan.org/address/0x99741758A3BCD7A95B80845E124C5C499DF4742b) |
| MonstroUSDC | Pending audit completion |

## Security

The smart contracts in this repository are provided **as-is** without warranty of any kind. Use at your own risk. Monstro DAO LLC and its contributors make no representations regarding the security, correctness, or fitness for any purpose of the code contained herein.

## Contributions

Contributions may be accepted at the discretion of Monstro DAO LLC or its authorized service providers. Submission of code does not imply acceptance or deployment.

## License

MIT

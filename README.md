# Monstro DAO LLC — Smart Contracts

Canonical smart contracts for the **Monstro DAO LLC** protocol on Base.

## Repository Structure

| Directory | Description |
|---|---|
| `token/` | MONSTRO protocol token (ERC-20) |
| `staking/` | Tiered staking with time-weighted rewards and early-exit penalties |
| `vaults/` | MonstroUSDC (mUSDC) — ERC-4626 yield-bearing USDC vault |
| `based_loans/` | [Based Loans protocol](based_loans/README.md) — see Based Loans README |

## Contracts

### MonstroToken

ERC-20 protocol token. Deployed on Base.

### MonstroStaking

Staking contract with tiered reward multipliers and configurable penalty curves for early unstaking. Stakers earn MONSTRO rewards proportional to their stake duration and tier.

### MonstroUSDC (mUSDC)

ERC-4626 vault wrapping USDC into mUSDC shares. The exchange rate increases over time through protocol fees and external revenue flows.

Key properties:
- Non-upgradeable with no admin controls
- Immutable fee structure
- Used by Based Loans to keep idle lender capital productive

## Audits

| Contract | Auditor | Status |
|---|---|---|
| MonstroToken | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| MonstroStaking | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| MonstroUSDC | [Hashlock](https://hashlock.com/audits/monstro) | Complete |
| Based Loans (all contracts) | [Hashlock](https://hashlock.com/audits/based-loans) | Complete |

## Deployments (Base Mainnet, chainId: 8453)

| Contract | Address |
|---|---|
| MonstroToken | [`0x1d3bE1CC80cA89DDbabe5b5C254AF63200e708f7`](https://basescan.org/address/0x1d3bE1CC80cA89DDbabe5b5C254AF63200e708f7) |
| MonstroStaking | [`0x99741758A3BCD7A95B80845E124C5C499DF4742b`](https://basescan.org/address/0x99741758A3BCD7A95B80845E124C5C499DF4742b) |
| MonstroUSDC | [`0xfA68Ac5cA298aB4B96bCE6542ec74bB9516b0397`](https://basescan.org/address/0xfA68Ac5cA298aB4B96bCE6542ec74bB9516b0397) |

## Security

The smart contracts in this repository are provided **as-is** without warranty of any kind. Use at your own risk. Monstro DAO LLC and its contributors make no representations regarding the security, correctness, or fitness for any purpose of the code contained herein. Users should only interact with verified contract addresses or official frontends.

## Contributions

Contributions may be accepted at the discretion of Monstro DAO LLC or its authorized service providers. Submission of code does not imply acceptance or deployment.

## License

MIT

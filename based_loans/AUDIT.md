# Audit Context — Based Loans Protocol

## Audit Scope

This document covers all contracts within the Based Loans protocol, including Core, LendingLedger, AssetManager, OracleManager, FeeDistributor, and related adapters.

MonstroToken, MonstroStaking, and MonstroUSDC are documented separately but referenced where relevant.

## Protocol Summary

Zero-liquidation DeFi lending on Base. Borrowers deposit collateral and receive USDC from a FIFO lender queue. They buy back collateral before expiry or lenders claim it at a discount. Fixed terms, fixed cost, no variable rates, no liquidation engine. Collateral value is only checked at origination; no re-evaluation occurs after loan creation.

## Contract Responsibilities

| Contract | Role |
|---|---|
| Core | Loan lifecycle: origination, partial/full buyback, collateral claims. Core never holds or transfers USDC directly. All USDC accounting and movement is handled by LendingLedger. |
| LendingLedger | Lender deposits, FIFO queue, matching, settlement, proceeds. Sole contract that holds all USDC deposits. Wraps idle funds to mUSDC vault. |
| AssetManager | Collateral config: oracle sources, LTV, exposure caps, risk params. |
| OracleManager | Multi-source price aggregation (Pyth + TWAP). Deviation checks, staleness, TWAP windows. |
| FeeDistributor | 3-tier fee split: treasury, AutoBurnSplitter, per-asset growth subs. |
| AutoBurnSplitter | Vault path (USDC → mUSDC rate growth) + DEX swap path (buy/burn MONSTRO). |
| MonstroUSDC | ERC-4626 USDC vault. Non-upgradeable, immutable fees (5 bps mint, 25 bps redeem). |
| Adapters | UniswapV3, Algebra, Pyth — thin oracle wrappers called by OracleManager. |

## Access Control

- **Owner**: DAO multisig (5-of-7). Full control.
- **Operator**: Labs multisig (2-of-2). Limited to: pause Cores, growth subs, asset config. Cannot authorize/remove Cores, change tier config, or modify vault. Operator cannot move user funds or withdraw balances under any circumstance.

## Areas of Expected Scrutiny

### 1. Share Tracking (LendingLedger)

When lender USDC is locked for a loan, it is converted to vault shares. Two mappings track the exact shares per-loan-per-lender:

- `_loanSharesOriginal` — set at lock time, never modified. Denominator for proportional release.
- `_loanSharesRemaining` — decremented on each settlement. Cleared on writeOff.

This prevents share-rate asymmetry when the vault appreciates between lock and unlock. Without it, re-converting USDC to shares at a higher rate would release fewer shares than locked.

### 2. Vault Deliverability Cap (LendingLedger)

Per-lender idle balances can exceed what the vault can actually redeem, because vault redeem fees reduce the vault's share pool without adjusting individual lender state. The `_vaultDeliverable()` helper caps all execution and view paths at the vault's actual redeemable amount.

Applied in: `requestLiquidity`, `withdraw`, `withdrawAsMusdc` (excluded — shares transfer directly), `claimLoanProceeds`, partial redeploy withdrawals, and all view functions (`getAccount`, `getLenderSummary`, `getProtocolStats`, `getMatchableLiquidity`).

### 3. Vault Redeem Fee Socialization (LendingLedger)

When USDC is unwrapped from the vault (loan disbursement, proceeds claims), the vault's 25 bps redeem fee burns extra shares. This cost is socialized:

- `totalDeposited` is reduced by the fee shares immediately.
- Per-lender `globalDeposit`, `globalLocked`, and per-loan share records are not adjusted at that point.
- Loss is realized lazily during settlement and withdrawal.

This creates a bounded drift where `totalLocked` may slightly exceed `totalDeposited`. The drift closes as loans settle. Per-lender allocation was evaluated and rejected due to underflow risk in the settlement path (empirically verified).

This does not introduce insolvency risk. The effect is limited to bounded timing-based value drift proportional to the redeem fee rate.

### 4. Vault Switching Guard (LendingLedger)

`setVault()` requires `totalDeposited == 0`. Deposits are tracked as shares (vault mode) or raw USDC (no-vault mode). Switching modes with existing deposits would corrupt balance interpretation.

### 5. mUSDC Vault (MonstroUSDC)

- `withdraw()` delivers exact requested assets to receiver. Fee is embedded in the share burn count.
- `maxWithdraw()` uses a round-trip verification loop (up to 8 decrements) to ensure `withdraw(maxWithdraw(owner))` never reverts.
- `mint()` has a `ZeroShares` guard matching `deposit()`.
- Constructor seeds 1 USDC to `address(0xdead)` for inflation attack mitigation.
- `_decimalsOffset()` not overridden (returns 0). Seed provides adequate protection.

## External Dependencies

| Dependency | Role | Trust Assumption |
|---|---|---|
| USDC (Circle) | Sole deposit asset. ERC-20, 6 decimals, upgradeable proxy, admin blacklist. | Circle does not blacklist protocol contracts. If blacklisted, affected balances may become permanently inaccessible. |
| Pyth Network | Primary price source via PythAdapter. | Pyth feed IDs are correct and update within staleness window. |
| Uniswap V3 / Algebra pools | TWAP price source via adapter. | Pool has sufficient liquidity and observation cardinality for manipulation resistance. |
| OpenZeppelin 5.x | ERC-4626, ReentrancyGuard, Ownable2Step, Pausable, SafeERC20. | Audited library, used without modification. |

## Intentional Design Decisions

- **Pause = full freeze.** A paused Core blocks all Ledger calls from that Core, including withdrawals and claims. This is an intentional safety tradeoff prioritizing system integrity over user liquidity during incidents. This behavior is global per Core and cannot be selectively bypassed for individual users.
- **USDC-only deposits.** No `depositMusdc` path on LendingLedger. Permanent decision.
- **`releaseLiquidity` unused.** Present in LendingLedger but not called from the current Core. Retained for forward compatibility with alternative Core implementations.
- **No mUSDC pause/admin.** The vault is non-upgradeable with no owner, no admin functions, no pause.
- **No ERC-4626 slippage params.** Standard ERC-4626 behavior. Integrators (LendingLedger) add their own constraints.
- **Multi-Core architecture.** LendingLedger supports multiple authorized Cores. Loan proceeds are namespaced by `[core][loanId][lender]`.
- **`totalLocked > totalDeposited` after disbursements.** See "Vault Redeem Fee Socialization" above.
- **Fee rounding to zero on sub-penny amounts.** Expected behavior due to integer division; negligible at protocol scale.

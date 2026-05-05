# Audit Context — Based Loans Protocol

## Audit Scope

This document covers all contracts within the Based Loans protocol, including Core, LendingLedger, AssetManager, OracleManager, FeeDistributor, AutoBurnSplitter, and related adapters.

MonstroToken, MonstroStaking, and MonstroUSDC are documented separately but referenced where relevant.

## Protocol Summary

Zero-liquidation DeFi lending on Base. Borrowers deposit collateral and receive USDC from a FIFO lender queue. They buy back collateral before expiry or lenders claim it at a discount. Fixed terms, fixed cost, no variable rates, no liquidation engine. Collateral value is only checked at origination; no re-evaluation occurs after loan creation.

Idle lender funds may be wrapped into mUSDC while they are not actively disbursed into loans.

## Contract Responsibilities

| Contract | Role |
|---|---|
| Core | Loan lifecycle: origination, partial/full buyback, collateral claims. Core never holds or transfers USDC directly. All USDC accounting and movement is handled by LendingLedger. |
| LendingLedger | Lender deposits, FIFO queue, matching, settlement, proceeds. Sole protocol contract that holds lender-side USDC/mUSDC accounting. Wraps idle funds to mUSDC vault when configured. |
| AssetManager | Collateral config: oracle sources, LTV, exposure caps, risk params. |
| OracleManager | Multi-source price aggregation: Pyth + TWAP. Deviation checks, staleness, TWAP windows. |
| FeeDistributor | 3-tier fee split: treasury, AutoBurnSplitter, per-asset growth subs. |
| AutoBurnSplitter | Vault path, USDC to mUSDC rate growth, plus DEX swap path, buy/burn MONSTRO. |
| MonstroUSDC | ERC-4626 USDC vault. Non-upgradeable, immutable fees: 5 bps mint, 25 bps redeem. |
| Adapters | UniswapV3, Algebra, Pyth. Thin oracle wrappers called by OracleManager. |

## Access Control

- **Owner**: DAO multisig, 5-of-7. Full control.
- **Operator**: Labs multisig, 2-of-2. Limited to: pause Cores, growth subs, asset config. Cannot authorize/remove Cores, change tier config, or modify vault. Operator cannot move user funds or withdraw balances under any circumstance.

## Areas of Expected Scrutiny

### 1. Share Tracking — LendingLedger

When lender USDC is matched into a loan, the Ledger locks the exact vault-share amount needed to deliver that matched USDC amount later during disbursement.

Two mappings track the exact shares per loan per lender:

- `_loanSharesOriginal` — set at lock time, never modified. Used as a non-zero integrity check; not the denominator for settlement.
- `_loanSharesRemaining` — decremented on each settlement using the live remaining-state ratio (`remainingShares * principal / remainingUsdc`). Cleared exactly on final buyback or write-off.

This prevents share-rate asymmetry when the vault appreciates between lock and unlock. Without this, re-converting USDC to shares at a higher rate could release fewer shares than were originally locked.

For mUSDC, LendingLedger uses owner-aware exact-withdraw previewing through `previewWithdrawFrom(address(this), amount)` when available, with fallback to standard `previewWithdraw(amount)` for generic ERC-4626 vaults.

### 2. Vault Deliverability Cap — LendingLedger

Per-lender idle balances are valued using the vault’s actual withdrawable/share mechanics. The `_vaultDeliverable()` helper caps execution and idle-view paths at the vault’s actual redeemable/withdrawable amount.

Applied in:

- `requestLiquidity`
- `withdraw`
- `claimLoanProceeds`
- partial redeploy withdrawals
- idle portions of view functions, including `getAccount`, `getLenderSummary`, `getProtocolStats`, and `getMatchableLiquidity`

`withdrawAsMusdc` is excluded because it transfers mUSDC shares directly and does not redeem from the vault.

Display getters intentionally separate:

- **idle value**: physical idle vault shares valued through current vault mechanics
- **locked value**: active loan USDC principal exposure / cap utilization
- **deposited value**: idle + locked

This avoids applying the live vault exchange rate to already-redeemed locked loan book shares.

### 3. Vault Withdraw Fee Localization — LendingLedger

Loan disbursement does not globally socialize vault redeem/withdraw costs across unrelated depositors.

When a lender is matched into a loan, `requestLiquidity` locks the exact number of shares required for the Ledger to later deliver the matched USDC amount. For mUSDC, this uses the owner-aware `previewWithdrawFrom(address(this), amount)` helper when available, with fallback to standard `previewWithdraw(amount)` for generic ERC-4626 vaults.

During disbursement, LendingLedger uses `withdraw(amount, ...)` for exact USDC output instead of `redeem(previewWithdraw(amount), ...)`. This keeps share locking and share burning aligned, including fee-bearing vault boundary cases.

The withdraw cost is localized to the matched lenders funding that loan. `totalDeposited` is not globally haircut to socialize the cost across unrelated lenders.

### 4. Vault Switching Guard — LendingLedger

`setVault()` requires `totalDeposited == 0`.

Deposits are tracked as shares in vault mode and raw USDC in no-vault mode. Switching modes with existing deposits would corrupt balance interpretation.

### 5. mUSDC Vault — MonstroUSDC

- `withdraw()` delivers exact requested assets to receiver. Fee is embedded in the share burn count.
- Last-live-redeemer handling is owner-aware. If an owner holds all non-dead supply, `withdraw()` uses the no-fee share path for amounts up to `maxWithdraw(owner)`, avoiding fees that would accrue only to dead shares.
- `previewWithdrawFrom(owner, assets)` provides an owner-aware preview for integrations that need the exact shares `withdraw(assets, receiver, owner)` will burn.
- Standard `previewWithdraw()` remains owner-agnostic and conservative where owner-specific last-live-redeemer status matters.
- `maxWithdraw()` is aligned with executable withdrawal behavior so `withdraw(maxWithdraw(owner))` does not revert.
- `mint()` has a `ZeroShares` guard matching `deposit()`.
- Constructor seeds 1 USDC to `address(0xdead)` for inflation attack mitigation.
- `_decimalsOffset()` is not overridden and returns 0. Seed provides adequate protection.

**LLR accounting alignment — LendingLedger `_sharesToUsdcNet`:**

mUSDC's `withdraw()` waives the 25 bps redeem fee when `totalSupply() <= balanceOf(owner) + SEED_AMOUNT` — an owner-balance check, not an amount check. This means when LendingLedger is the sole live mUSDC holder, the fee is waived for **any** withdrawal amount up to `maxWithdraw`, not only full-balance withdrawals. `_sharesToUsdcNet` mirrors this condition using the overflow-safe form: `vault.totalSupply() <= MUSDC_SEED_AMOUNT || vault.totalSupply() - MUSDC_SEED_AMOUNT <= vault.balanceOf(address(this))` (named constant `MUSDC_SEED_AMOUNT = 1e6` equals mUSDC's private `SEED_AMOUNT`). When the condition holds, the function returns `convertToAssets(shares)` (gross, no fee) for any partial `shares` argument. This ensures view functions such as `getAccount` correctly report gross idle USDC for each lender when LendingLedger is the LLR, preventing `_vaultDeliverable()` from undercounting and blocking withdrawals. This logic is intentionally mUSDC-specific: `withdraw()` in other ERC-4626 vaults may not share this owner-aware LLR behavior.

### 6. Queue Lifecycle — LendingLedger

Lenders enter per-asset FIFO queues only when they have usable capacity:

- asset cap configured
- remaining cap above `minAssetCap`
- net idle USDC above `minAssetCap`
- asset still active/configured

All enqueue paths check usable capacity before adding a lender to the queue.

Settlement paths also refresh queue eligibility:

- auto-redeploy buyback settlement re-enqueues the lender if eligible
- manual-mode buyback settlement does not re-enqueue because proceeds are claimable, not automatically lendable
- write-off settlement refreshes queue eligibility after locked exposure is released
- cap-cleared or unconfigured assets do not requeue

The queue guard prevents duplicate queue entries.

### 7. Cap Utilization — LendingLedger

Per-asset cap utilization is tracked in USDC principal exposure, not vault shares.

This prevents cap utilization from drifting as the mUSDC exchange rate changes. Cap checks compare USDC caps against USDC utilization directly.

`totalUtilizedUsdc` mirrors aggregate per-lender/per-asset utilization and is used by protocol-wide display getters.

### 8. Loan Settlement — LendingLedger

Buyback settlement uses two steps:

1. `pullBuybackPayment` pulls borrower repayment and records the actual mUSDC shares minted by the vault.
2. `settleBuybackForLender` releases old locked exposure and credits lenders based on actual repayment shares.

Repayment accounting separates:

- old locked-share exposure from loan origination
- new repayment shares minted by the vault
- per-loan remaining USDC exposure through `_loanUsdcRemaining`

This handles vault appreciation where fewer shares may represent the same USDC value at repayment time.

Default settlement uses `writeOffPosition`, which clears remaining locked loan state and cap utilization using per-loan remaining accounting.

### 9. Removed Active-Core Settlement Helpers

`creditLoanProceeds` and `releaseLiquidity` were removed from LendingLedger.

They were not used by the current Core lifecycle and could confuse the corrected repayment/accounting model. Current lifecycle exits are:

- buyback: `pullBuybackPayment` + `settleBuybackForLender`
- default: `writeOffPosition`

No current cancellation path exists, so retaining unused active-callable settlement helpers in a non-upgradeable contract was unnecessary attack surface.

## External Dependencies

| Dependency | Role | Trust Assumption |
|---|---|---|
| USDC (Circle) | Sole deposit asset. ERC-20, 6 decimals, upgradeable proxy, admin blacklist. | Circle does not blacklist protocol contracts. If blacklisted, affected balances may become permanently inaccessible. |
| mUSDC (MonstroUSDC) | ERC-4626 vault used for idle lender liquidity. | mUSDC exact-withdraw, preview, redeem, and maxWithdraw behavior remain aligned. |
| Pyth Network | Primary price source via PythAdapter. | Pyth feed IDs are correct and update within staleness window. |
| Uniswap V3 / Algebra pools | TWAP price source via adapter. | Pool has sufficient liquidity and observation cardinality for manipulation resistance. |
| OpenZeppelin 5.x | ERC-4626, ReentrancyGuard, Ownable2Step, Pausable, SafeERC20. | Audited library, used without modification. |
| AlienBase / V3-compatible routers | AutoBurnSplitter swap route where configured. | Router supports the configured no-deadline exactInputSingle interface and pool fee matches the configured pool. |

## Intentional Design Decisions

- **Pause = full freeze.** A paused Core blocks all Ledger calls from that Core, including withdrawals and claims. This is an intentional safety tradeoff prioritizing system integrity over user liquidity during incidents. This behavior is global per Core and cannot be selectively bypassed for individual users.
- **USDC-only deposits.** No `depositMusdc` path on LendingLedger. Permanent decision.
- **Idle vault wrapping only.** mUSDC is used to make idle lender funds productive. Funds actively disbursed into loans are represented by loan accounting, not live vault shares.
- **Locked loan value is reported as USDC exposure.** Active locked loan value is tracked/reported as USDC principal exposure rather than converting already-redeemed book shares at the live vault exchange rate. Idle value still uses physical idle vault shares.
- **No mUSDC pause/admin.** The vault is non-upgradeable with no owner, no admin functions, no pause.
- **No ERC-4626 slippage params.** Standard ERC-4626 behavior. Integrators such as LendingLedger add their own constraints.
- **Multi-Core architecture.** LendingLedger supports multiple authorized Cores. Loan proceeds are namespaced by `[core][loanId][lender]`.
- **Fee rounding to zero on sub-penny amounts.** Expected behavior due to integer division; negligible at protocol scale.
- **AutoBurnSplitter router specificity.** AutoBurnSplitter is configured for routers matching the no-deadline exactInputSingle interface used by the current burn path. A router with a different ABI requires a new splitter deployment or adapter-based splitter version.
- **No public affiliate system at MVP.** Growth subs / per-asset fee routing are admin-configured and not permissionless.

## Known Non-Issues / Expected Behaviors

### mUSDC Exchange Rate Appreciation

mUSDC is a vault share, not a stablecoin peg.

The exchange rate can increase when fees or revenue are retained in the vault. This is expected. Depositors mint fewer shares when the exchange rate is higher, preserving proportional accounting.

### High mUSDC Price-Per-Share at Low Supply

If most live vault shares are redeemed into active loans and USDC is later donated into the vault, price-per-share can increase sharply while live supply is low.

This is valid vault-share behavior, but display getters must not apply that live vault PPS to active loan book shares. LendingLedger separates idle vault-share value from active loan USDC exposure for this reason.

### Manual Proceeds Mode

If a lender disables auto-redeploy, buyback repayments are credited to claimable proceeds instead of automatically becoming lendable deposit.

Manual-mode lenders should not be requeued after settlement until they redeploy or deposit again.

### `withdrawAsMusdc`

`withdrawAsMusdc` transfers mUSDC shares directly and does not redeem USDC from the vault. It therefore uses direct share availability rather than net redeemable USDC availability.

### AutoBurnSplitter `executeBurns`

`claimAndBurn()` is the intended keeper path: it claims from FeeDistributor and then executes burns internally.

`executeBurns()` remains as a permissionless sweeper for USDC already sitting in AutoBurnSplitter, such as direct transfers or manual funding.

FeeDistributor no longer attempts to auto-callback into `executeBurns()` during `claim()`.

## Test / Review Focus

Auditors should pay special attention to:

- exact-withdraw share locking in `requestLiquidity`
- exact-USDC vault unwrapping through `withdraw(amount, ...)`
- owner-aware mUSDC preview behavior through `previewWithdrawFrom`
- partial buyback and final buyback share release
- cap utilization release across multiple loans for the same lender/asset
- queue unlink/relink behavior during matching
- requeue eligibility after auto-redeploy settlement and write-off
- manual proceeds mode not requeueing automatically
- display getter separation of idle vault-share value and locked USDC exposure
- default collateral dust handling and zero-share claimant handling
- AutoBurnSplitter poolFee validation and no-deadline router interface assumptions

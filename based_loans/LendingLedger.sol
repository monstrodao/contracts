// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev Extension interface for fee-bearing vaults (e.g. mUSDC) that expose an owner-aware
///      withdrawal preview. previewWithdrawFrom(owner, assets) returns the exact share count
///      that withdraw(assets, *, owner) will burn, accounting for the owner's LLR status.
interface IOwnerPreviewVault {
    function previewWithdrawFrom(address owner, uint256 assets) external view returns (uint256);
}

/// @title BasedLoansLendingLedger
/// @notice Manages lender USDC deposits, per-asset allocation caps, FIFO liquidity queues,
///         and per-loan proceeds from collateral buybacks.
/// @dev The authorized Core contract is the only caller permitted to lock, release, disburse,
///      credit, or write off lender positions.
///
///      Lender balance model:
///      - `globalDeposit`  — total USDC the lender is owed (deposited and not withdrawn).
///      - `globalLocked`   — portion of globalDeposit currently committed to active loans.
///      - idle             — globalDeposit - globalLocked (freely withdrawable).
///
///      Loan proceeds (yield from buybacks) are tracked separately per loan in `loanProceeds`
///      so they cannot be automatically swept into new loan allocations. Lenders either
///      withdraw them directly or explicitly redeploy them into globalDeposit. Redeploying
///      automatically re-enqueues the lender for every asset they have a configured cap on.
///
///      Queue behaviour:
///      - Lenders opt in per asset by calling updateCap() with a non-zero amount.
///      - requestLiquidity() walks the queue head-first and locks funds from each lender in order.
///      - A lender who is partially filled (loan satisfied before their cap is exhausted) remains
///        at the head of the queue with their remaining capacity intact.
///      - A lender who is fully drained, or who has no available funds at processing time,
///        is dequeued lazily. They re-enter automatically when their lock is released via
///        settleBuybackForLender, writeOffPosition, or redeployLoanProceeds.
///
///      Asset configuration:
///      - Each lender may configure at most MAX_CONFIGURED_ASSETS (50) distinct assets.
///      - Setting a cap to 0 removes that asset from the lender's configured list, freeing a slot.
contract BasedLoansLendingLedger is Ownable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                             ERRORS
    // =============================================================

    error ZeroAddress();
    error BelowMinDeposit(uint256 provided, uint256 minimum);
    error InsufficientUnlockedBalance();
    error CapBelowMinimum(uint256 provided, uint256 minimum);
    error CapAboveMaximum(uint256 provided, uint256 maximum);
    error CapBelowUtilized(uint256 provided, uint256 utilized);
    error InvalidCapBounds();
    error InvalidMaxLenders();
    error TooManyConfiguredAssets();
    error InvalidInput();
    error BatchTooLarge();
    error NoProceeds();
    error Unauthorized();
    error NotOperatorOrOwner();
    error VaultNotSet();
    error VaultDepositFailed();
    error VaultMaxWithdrawExceeded();
    error CoreAlreadyAuthorized();
    error CoreNotAuthorized();
    error ShareAccountingInvariantBroken();
    error NoPendingPayment();
    error InvalidLoanAccounting();
    error NothingToSettle();
    error SettlementTooSmall();
    error NothingToWriteOff();

    // =============================================================
    //                             STRUCTS
    // =============================================================

    struct Account {
        uint256 globalDeposit; // mUSDC shares (or USDC when vault is address(0))
        uint256 globalLocked;  // mUSDC shares locked across all active loans
    }

    struct AssetCap {
        uint256 maxCap;   // Maximum USDC the lender will allocate to this asset
        uint256 utilized; // USDC currently locked for this asset (was shares; tracks USDC directly to prevent drift with vault PPS)
    }

    struct Queue {
        address head;
        address tail;
    }

    // =============================================================
    //                            CONSTANTS
    // =============================================================

    /// @notice Maximum number of lenders that can contribute to a single loan fill.
    uint8 public constant MAX_LENDERS_PER_FILL = 25;

    /// @notice Maximum number of distinct assets a single lender may configure caps for.
    uint8 public constant MAX_CONFIGURED_ASSETS = 50;

    /// @notice Maximum items per batch call (claimLoanProceeds, redeployLoanProceeds).
    uint8 public constant MAX_BATCH_SIZE = 50;

    /// @notice Shares minted to address(0xdead) in the mUSDC constructor (inflation-attack seed).
    ///         mUSDC waives the redeem fee when burning `shares` would leave only this seed.
    ///         Mirrors mUSDC's private SEED_AMOUNT constant; safe to hardcode because mUSDC is immutable.
    uint256 public constant MUSDC_SEED_AMOUNT = 1e6;

    // =============================================================
    //                     CONFIGURABLE BOUNDS
    // =============================================================

    uint256 public minDeposit;
    uint256 public minAssetCap;
    uint256 public maxAssetCap;

    // =============================================================
    //                         STATE VARIABLES
    // =============================================================

    IERC20 public immutable USDC;

    /// @notice Whitelist of Core contracts permitted to call Core-gated ledger functions.
    mapping(address => bool) public authorizedCores;

    /// @notice Per-Core pause flag. Active Cores must not be paused to call any ledger function.
    mapping(address => bool) public pausedCores;

    /// @notice Optional secondary role permitted to pause an authorized Core. Owner-only actions
    ///         (authorize, remove, unpause, vault config, parameter updates) are not delegated.
    address public operator;

    /// @notice Sum of all lender globalDeposit values in mUSDC shares. Updated on deposit, withdraw, settleBuybackForLender, writeOff, and redeploy.
    ///         disburseLoan does NOT modify this value — locked shares (previewWithdraw) exactly equal
    ///         shares burned, so no global adjustment is needed and sum(globalDeposit) == totalDeposited throughout.
    uint256 public totalDeposited;

    /// @notice Sum of all lender globalLocked values in mUSDC shares. Updated on requestLiquidity, settleBuybackForLender, writeOffPosition, and writeOff.
    uint256 public totalLocked;

    /// @notice Sum of all per-lender per-asset cap utilization in USDC. Mirrors the aggregate of
    ///         _caps[lender][asset].utilized across all active loans. Used by display getters so
    ///         locked loan value is reported as USDC principal exposure rather than converting
    ///         already-redeemed shares at the current vault exchange rate (which inflates when
    ///         most shares have been disbursed and vault PPS spikes from protocol fee donations).
    uint256 public totalUtilizedUsdc;

    /// @notice ERC-4626 vault for auto-wrapping idle USDC to mUSDC. address(0) = disabled.
    address public vault;

    /// @notice Maximum number of lenders that can contribute to a single loan fill.
    /// @dev Bounds gas cost per requestLiquidity call linearly. Adjustable within [1, MAX_LENDERS_PER_FILL].
    uint8 public maxLendersPerFill;

    mapping(address => Account) private _accounts;
    mapping(address => mapping(address => AssetCap)) private _caps;

    mapping(address => Queue) private _assetQueues;
    mapping(address => mapping(address => address)) public nextInLine;
    mapping(address => mapping(address => bool)) public isQueued;

    /// @dev Ordered list of assets a lender has ever configured with a non-zero cap.
    ///      Used by redeployLoanProceeds to auto-re-enqueue. Bounded by MAX_CONFIGURED_ASSETS.
    mapping(address => address[]) private _lenderAssets;
    mapping(address => mapping(address => bool)) private _lenderAssetConfigured;

    /// @notice Per-Core, per-loan claimable proceeds for each lender (from buybacks or defaults).
    /// @dev Stored in mUSDC shares (or USDC when vault is disabled). Tracked separately from
    ///      globalDeposit so proceeds cannot be auto-swept into new loans.
    ///      Composite key `[core][loanId][lender]` keeps each Core's loan ID namespace isolated.
    mapping(address => mapping(uint256 => mapping(address => uint256))) public loanProceeds;

    /// @notice Original shares locked per-loan-per-lender at lock time. Never modified after lock.
    ///         Used as the denominator for proportional share release on partial buybacks.
    mapping(address => mapping(uint256 => mapping(address => uint256))) private _loanSharesOriginal;

    /// @notice Remaining locked shares per-loan-per-lender. Decremented on each settlement.
    ///         Cleared to zero on writeOff (full default) or when all partials complete.
    mapping(address => mapping(uint256 => mapping(address => uint256))) private _loanSharesRemaining;

    /// @notice Remaining USDC cap exposure per-loan-per-lender. Decremented proportionally on each
    ///         partial settlement; cleared to zero on final settlement or writeOff.
    ///         Prevents cap utilization from over-releasing when Core passes principal = funded on final.
    mapping(address => mapping(uint256 => mapping(address => uint256))) private _loanUsdcRemaining;

    /// @notice Per-lender auto-redeploy setting. When true (default), buyback principal returns
    ///         to idle deposit balance (available for new loans). When false, principal goes to
    ///         loanProceeds for manual claim, giving the lender full control over their funds.
    mapping(address => bool) private _autoRedeployDisabled;

    /// @notice Per-lender withdrawal token preference. Stored on-chain so the frontend can read
    ///         it back and route withdrawals/claims accordingly (ClaimDrawer, WithdrawDrawer,
    ///         SettingsDrawer). The preference is not enforced internally — callers choose the
    ///         withdrawal path (withdraw vs withdrawAsMusdc). Not dead: setter/getter are part
    ///         of the user-facing settings flow.
    mapping(address => bool) private _preferMusdc;

    /// @dev Pending repayment state set by pullBuybackPayment and consumed by settleBuybackForLender.
    ///      Keyed by (core, loanId) so concurrent loans on the same core remain isolated.
    ///      Cleared when the final lender for a payment is settled.
    mapping(address => mapping(uint256 => uint256)) private _pendingPaymentUsdc;
    mapping(address => mapping(uint256 => uint256)) private _pendingPaymentShares;
    mapping(address => mapping(uint256 => uint256)) private _pendingPaymentUsdcAllocated;
    mapping(address => mapping(uint256 => uint256)) private _pendingPaymentSharesAllocated;

    // =============================================================
    //                             EVENTS
    // =============================================================

    event Deposit(address indexed lender, uint256 amount);
    event Withdrawal(address indexed lender, uint256 amount);
    event CapUpdated(address indexed lender, address indexed asset, uint256 newCap);
    event Enqueued(address indexed lender, address indexed asset);
    event LiquidityLocked(address indexed lender, address indexed asset, uint256 amount);
    event LiquidityReleased(address indexed lender, address indexed asset, uint256 amount);
    event PositionWrittenOff(address indexed lender, address indexed asset, uint256 shares, uint256 usdcRelease);
    event LoanDisbursed(address indexed to, uint256 amount);
    event LoanProceedsCredited(uint256 indexed loanId, address indexed lender, uint256 amount);
    event LoanProceedsClaimed(uint256 indexed loanId, address indexed lender, uint256 amount);
    event LoanProceedsRedeployed(uint256 indexed loanId, address indexed lender, uint256 amount);
    event PartialRedeploy(address indexed lender, uint256 redeployed, uint256 withdrawn);
    event CoreAuthorized(address indexed core);
    event CoreRemoved(address indexed core);
    event CorePaused(address indexed core, address indexed by);
    event CoreUnpaused(address indexed core);
    event OperatorUpdated(address oldOperator, address newOperator);
    event MaxLendersPerFillUpdated(uint8 oldValue, uint8 newValue);
    event MinDepositUpdated(uint256 oldValue, uint256 newValue);
    event AssetCapBoundsUpdated(uint256 newMin, uint256 newMax);
    event VaultUpdated(address oldVault, address newVault);
    event WithdrawalAsMusdc(address indexed lender, uint256 usdcAmount, uint256 sharesTransferred);
    event AutoRedeployUpdated(address indexed lender, bool enabled);
    event WithdrawPreferenceUpdated(address indexed lender, bool preferMusdc);

    // =============================================================
    //                           MODIFIERS
    // =============================================================

    /// @dev Allows the contract owner or the configured operator.
    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != operator) revert NotOperatorOrOwner();
        _;
    }

    /// @dev Caller must be an authorized Core that is not currently paused.
    function _onlyActiveCore() internal view {
        if (!authorizedCores[msg.sender] || pausedCores[msg.sender]) revert Unauthorized();
    }

    // =============================================================
    //                           CONSTRUCTOR
    // =============================================================

    /// @notice Deploys the LendingLedger.
    /// @param _usdc Address of the USDC token contract.
    /// @param _owner Address that will own this contract.
    /// @param _operator Optional operator address (address(0) to disable).
    /// @param _maxLendersPerFill Initial maximum lenders per loan fill (within [1, 25]).
    /// @param _minDeposit Minimum USDC a lender must deposit.
    /// @param _minAssetCap Minimum per-asset allocation cap a lender may set.
    /// @param _maxAssetCap Maximum per-asset allocation cap a lender may set.
    constructor(
        address _usdc,
        address _owner,
        address _operator,
        uint8 _maxLendersPerFill,
        uint256 _minDeposit,
        uint256 _minAssetCap,
        uint256 _maxAssetCap
    ) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_maxLendersPerFill < 1 || _maxLendersPerFill > MAX_LENDERS_PER_FILL) revert InvalidMaxLenders();
        if (_minAssetCap == 0 || _minAssetCap >= _maxAssetCap) revert InvalidCapBounds();

        USDC = IERC20(_usdc);
        operator = _operator;
        maxLendersPerFill = _maxLendersPerFill;
        minDeposit = _minDeposit;
        minAssetCap = _minAssetCap;
        maxAssetCap = _maxAssetCap;
    }

    // =============================================================
    //                       OWNER CONFIGURATION
    // =============================================================

    /// @notice Sets the operator address. Only callable by the owner.
    /// @param _operator New operator address (address(0) to disable operator access).
    function setOperator(address _operator) external onlyOwner {
        address old = operator;
        operator = _operator;
        emit OperatorUpdated(old, _operator);
    }

    /// @notice Adds a Core contract to the authorized whitelist.
    /// @param core Address of the Core contract to authorize.
    function addAuthorizedCore(address core) external onlyOwner {
        if (core == address(0)) revert ZeroAddress();
        if (authorizedCores[core]) revert CoreAlreadyAuthorized();
        authorizedCores[core] = true;
        emit CoreAuthorized(core);
    }

    /// @notice Removes a Core contract from the authorized whitelist.
    /// @dev Proceeds keyed under `loanProceeds[core][...]` remain claimable by lenders.
    /// @param core Address of the Core contract to remove.
    function removeAuthorizedCore(address core) external onlyOwner {
        if (!authorizedCores[core]) revert CoreNotAuthorized();
        authorizedCores[core] = false;
        emit CoreRemoved(core);
    }

    /// @notice Pauses `core` — all Core-gated calls from it revert until unpaused.
    /// @dev Callable by owner or operator.
    /// @param core Address of the Core contract to pause.
    function pauseCore(address core) external onlyOwnerOrOperator {
        if (!authorizedCores[core]) revert CoreNotAuthorized();
        if (pausedCores[core]) return;
        pausedCores[core] = true;
        emit CorePaused(core, msg.sender);
    }

    /// @notice Re-enables a paused Core. Owner-only.
    /// @param core Address of the Core contract to unpause.
    function unpauseCore(address core) external onlyOwner {
        if (!pausedCores[core]) return;
        pausedCores[core] = false;
        emit CoreUnpaused(core);
    }

    /// @notice Updates the maximum number of lenders that can fill a single loan.
    /// @param _newMax New maximum lender count per fill (within [1, 25]).
    function setMaxLendersPerFill(uint8 _newMax) external onlyOwner {
        if (_newMax < 1 || _newMax > MAX_LENDERS_PER_FILL) revert InvalidMaxLenders();
        uint8 old = maxLendersPerFill;
        maxLendersPerFill = _newMax;
        emit MaxLendersPerFillUpdated(old, _newMax);
    }

    /// @notice Updates the minimum deposit amount required from lenders.
    /// @param _newMin New minimum deposit in USDC (6 decimals).
    function setMinDeposit(uint256 _newMin) external onlyOwner {
        uint256 old = minDeposit;
        minDeposit = _newMin;
        emit MinDepositUpdated(old, _newMin);
    }

    /// @notice Sets the ERC-4626 vault for auto-wrapping idle USDC. address(0) to disable.
    /// @dev Vault mint and redeem fees are both supported. Loan disbursement redeem costs are
    ///      localized to matched lenders by locking previewWithdrawFrom(address(this), amount)
    ///      shares during requestLiquidity (falls back to previewWithdraw for standard ERC-4626
    ///      vaults). Vault can only be changed when the ledger has no deposits at all,
    ///      to prevent misinterpreting existing USDC balances as vault shares or vice versa.
    /// @param _vault Address of the vault contract, or address(0) to disable.
    function setVault(address _vault) external onlyOwner {
        if (totalDeposited > 0) revert InvalidInput(); // Cannot switch vault while deposits exist
        address old = vault;
        vault = _vault;
        emit VaultUpdated(old, _vault);
    }

    /// @notice Updates the min and max bounds for per-asset allocation caps.
    /// @param _newMin New minimum cap in USDC (6 decimals). Must be > 0.
    /// @param _newMax New maximum cap in USDC (6 decimals). Must be > _newMin.
    function setAssetCapBounds(uint256 _newMin, uint256 _newMax) external onlyOwner {
        if (_newMin == 0 || _newMin >= _newMax) revert InvalidCapBounds();
        minAssetCap = _newMin;
        maxAssetCap = _newMax;
        emit AssetCapBoundsUpdated(_newMin, _newMax);
    }

    // =============================================================
    //                         LENDER ACTIONS
    // =============================================================

    /// @notice Deposits USDC into the lender's account.
    /// @param amount The amount of USDC to deposit. Must meet minDeposit.
    function deposit(uint256 amount) external {
        if (amount < minDeposit) revert BelowMinDeposit(amount, minDeposit);
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = _wrapToVault(amount);
        _accounts[msg.sender].globalDeposit += shares;
        totalDeposited += shares;

        // Re-enqueue for configured assets where the lender now has usable capacity.
        address[] storage assets = _lenderAssets[msg.sender];
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address a = assets[i];
            if (!isQueued[a][msg.sender] && _hasUsableCapacity(msg.sender, a)) {
                _enqueue(a, msg.sender);
            }
        }

        emit Deposit(msg.sender, amount);
    }

    /// @notice Deposits USDC and sets collateral caps atomically in one transaction.
    /// @dev Combines deposit + updateCap. If either fails, the entire tx reverts.
    ///      Use this for first-time lender onboarding so funds are never unprotected.
    /// @param amount The amount of USDC to deposit. Must meet minDeposit.
    /// @param assets The collateral asset addresses to set caps for.
    /// @param newCaps The new maximum USDC amounts (same length as assets).
    function depositAndSetCaps(uint256 amount, address[] calldata assets, uint256[] calldata newCaps) external {
        if (assets.length != newCaps.length) revert InvalidInput();
        if (assets.length == 0) revert InvalidInput();

        // Deposit
        if (amount < minDeposit) revert BelowMinDeposit(amount, minDeposit);
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = _wrapToVault(amount);
        _accounts[msg.sender].globalDeposit += shares;
        totalDeposited += shares;
        emit Deposit(msg.sender, amount);

        // Set caps
        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            uint256 newCap = newCaps[i];

            if (newCap != 0) {
                if (newCap < minAssetCap) revert CapBelowMinimum(newCap, minAssetCap);
                if (newCap > maxAssetCap) revert CapAboveMaximum(newCap, maxAssetCap);
                uint256 currentUtilizedUsdc = _caps[msg.sender][asset].utilized;
                if (newCap < currentUtilizedUsdc) revert CapBelowUtilized(newCap, currentUtilizedUsdc);

                if (!_lenderAssetConfigured[msg.sender][asset]) {
                    if (_lenderAssets[msg.sender].length >= MAX_CONFIGURED_ASSETS) revert TooManyConfiguredAssets();
                    _lenderAssets[msg.sender].push(asset);
                    _lenderAssetConfigured[msg.sender][asset] = true;
                }

                _caps[msg.sender][asset].maxCap = newCap;

                // Only enqueue if idle liquidity and remaining cap both meet minimum threshold.
                if (!isQueued[asset][msg.sender] && _hasUsableCapacity(msg.sender, asset)) {
                    _enqueue(asset, msg.sender);
                }

                emit CapUpdated(msg.sender, asset, newCap);
            } else {
                // L-05: zero-cap branch — clear maxCap and only remove the asset slot when
                // no active loan exposure remains. If utilized > 0 the asset must stay in
                // _lenderAssets so getAccount/getLenderSummary still include the locked value.
                _caps[msg.sender][asset].maxCap = 0;
                if (_lenderAssetConfigured[msg.sender][asset]) {
                    if (_caps[msg.sender][asset].utilized == 0) {
                        _removeLenderAsset(msg.sender, asset);
                    }
                    emit CapUpdated(msg.sender, asset, 0);
                }
            }
        }
    }

    /// @notice Withdraws idle (unlocked) USDC from the lender's account.
    /// @param amount The USDC amount requested. Vault is redeemed by shares, so actual
    ///        delivered may be up to 1 wei less when ceiling-rounding would push shares
    ///        past the account balance. The delivered amount is what the lender receives
    ///        and is emitted in the Withdrawal event.
    function withdraw(uint256 amount) external {
        Account storage acct = _accounts[msg.sender];
        uint256 idleShares = acct.globalDeposit - acct.globalLocked;
        uint256 idleUsdc = _sharesToUsdcNet(idleShares);
        uint256 deliverable = _vaultDeliverable();
        if (idleUsdc > deliverable) idleUsdc = deliverable;
        if (idleUsdc < amount) revert InsufficientUnlockedBalance();

        uint256 sharesToBurn;
        uint256 usdcOut;
        if (vault == address(0)) {
            sharesToBurn = amount;
            usdcOut = amount;
        } else {
            // Use withdraw() not redeem(previewWithdraw()): in fee-bearing vaults
            // redeem(previewWithdraw(X)) can burn a mismatched share amount (dead zone),
            // stranding USDC in the contract. withdraw() delivers exactly X.
            sharesToBurn = IERC4626(vault).withdraw(amount, address(this), address(this));
            // Defensive: the amount guard above (idleUsdc < amount) prevents this, but we
            // assert it explicitly so any vault miscalculation surfaces immediately rather than
            // silently draining other lenders' shares.
            if (sharesToBurn > idleShares) revert ShareAccountingInvariantBroken();
            usdcOut = amount;
        }

        acct.globalDeposit -= sharesToBurn;
        totalDeposited -= sharesToBurn;
        USDC.safeTransfer(msg.sender, usdcOut);
        emit Withdrawal(msg.sender, usdcOut);
    }

    /// @notice Withdraws idle USDC as mUSDC vault shares (no redemption from vault).
    /// @dev Only available when vault is set. Transfers mUSDC shares directly to the lender.
    /// @param amount The USDC-denominated amount to withdraw.
    function withdrawAsMusdc(uint256 amount) external {
        if (vault == address(0)) revert VaultNotSet();
        Account storage acct = _accounts[msg.sender];
        uint256 idleShares = acct.globalDeposit - acct.globalLocked;

        // Transfers shares directly — no vault redemption occurs.
        // Check against gross share value, not net redeemable USDC, because no redeem
        // fee is paid here. Using _sharesToUsdcNet would block withdrawals the lender
        // is entitled to receive.
        IERC4626 v = IERC4626(vault);
        uint256 shares = v.convertToShares(amount);
        if (shares > idleShares) revert InsufficientUnlockedBalance();
        acct.globalDeposit -= shares;
        totalDeposited -= shares;
        IERC20(vault).safeTransfer(msg.sender, shares);

        emit WithdrawalAsMusdc(msg.sender, amount, shares);
    }

    /// @notice Toggles auto-redeploy for the caller. When enabled (default), buyback principal
    ///         returns to idle deposit balance and can be matched into new loans. When disabled,
    ///         all buyback returns (principal + yield) go to loanProceeds for manual claim.
    /// @param enabled True to auto-redeploy (default), false to require manual claim.
    function setAutoRedeploy(bool enabled) external {
        _autoRedeployDisabled[msg.sender] = !enabled;
        emit AutoRedeployUpdated(msg.sender, enabled);
    }

    /// @notice Returns whether auto-redeploy is enabled for a lender (true by default).
    function autoRedeployEnabled(address lender) external view returns (bool) {
        return !_autoRedeployDisabled[lender];
    }

    /// @notice Stores the lender's preferred withdrawal token on-chain.
    /// @dev Read by the frontend (ClaimDrawer, WithdrawDrawer, SettingsDrawer) to route
    ///      withdrawals to USDC or mUSDC. The contract does not enforce this preference
    ///      internally — it is a user-set signal for the UI. Not internally dead.
    /// @param preferMusdc True to prefer mUSDC, false for USDC (default).
    function setWithdrawPreference(bool preferMusdc) external {
        _preferMusdc[msg.sender] = preferMusdc;
        emit WithdrawPreferenceUpdated(msg.sender, preferMusdc);
    }

    /// @notice Returns the lender's stored withdrawal preference (false = USDC, true = mUSDC).
    function prefersMusdc(address lender) external view returns (bool) {
        return _preferMusdc[lender];
    }

    /// @notice Sets the lender's maximum USDC allocation caps for one or more assets in a single tx.
    /// @dev A non-zero cap enqueues the lender at the tail if not already queued, and registers
    ///      the asset in their configured list (up to MAX_CONFIGURED_ASSETS distinct assets).
    ///      Setting cap to 0 removes the asset from the configured list (freeing a slot) and
    ///      opts out of future fills. Any in-queue position is cleared lazily by requestLiquidity.
    ///      Active locks are not affected by cap changes.
    /// @param assets The collateral asset addresses to set caps for.
    /// @param newCaps The new maximum USDC amounts (same length as assets), or 0 to opt out.
    function updateCap(address[] calldata assets, uint256[] calldata newCaps) external {
        if (assets.length != newCaps.length) revert InvalidInput();
        if (assets.length == 0) revert InvalidInput();

        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            uint256 newCap = newCaps[i];

            if (newCap != 0) {
                if (newCap < minAssetCap) revert CapBelowMinimum(newCap, minAssetCap);
                if (newCap > maxAssetCap) revert CapAboveMaximum(newCap, maxAssetCap);
                // utilized is USDC; compare directly without share conversion
                uint256 currentUtilizedUsdc = _caps[msg.sender][asset].utilized;
                if (newCap < currentUtilizedUsdc) revert CapBelowUtilized(newCap, currentUtilizedUsdc);

                if (!_lenderAssetConfigured[msg.sender][asset]) {
                    if (_lenderAssets[msg.sender].length >= MAX_CONFIGURED_ASSETS) revert TooManyConfiguredAssets();
                    _lenderAssets[msg.sender].push(asset);
                    _lenderAssetConfigured[msg.sender][asset] = true;
                }

                _caps[msg.sender][asset].maxCap = newCap;

                // Only enqueue if idle liquidity and remaining cap both meet minimum threshold.
                // Cap setting without deposit is allowed; the separate-tx flow just won't enqueue until funded.
                if (!isQueued[asset][msg.sender] && _hasUsableCapacity(msg.sender, asset)) {
                    _enqueue(asset, msg.sender);
                }
            } else {
                _caps[msg.sender][asset].maxCap = 0;

                // Only free the slot when no active loan exposure remains; if utilized > 0
                // the asset must stay in _lenderAssets so getAccount can include the lock.
                if (_lenderAssetConfigured[msg.sender][asset] && _caps[msg.sender][asset].utilized == 0) {
                    _removeLenderAsset(msg.sender, asset);
                }
            }

            emit CapUpdated(msg.sender, asset, newCap);
        }
    }

    /// @notice Withdraws the caller's claimable proceeds from one or more loans on a given Core.
    /// @dev Proceeds accumulate here (not in globalDeposit) as buybacks occur,
    ///      so they remain isolated from the lender's lending pool.
    ///      Silently skips loans with zero proceeds (no revert on empty).
    ///      All loanIds must belong to the same `core` — loan IDs are namespaced per-Core.
    /// @param core The Core contract whose loans these IDs belong to.
    /// @param loanIds The loan IDs to claim proceeds from (max MAX_BATCH_SIZE).
    function claimLoanProceeds(address core, uint256[] calldata loanIds) external {
        if (loanIds.length == 0) revert InvalidInput();
        if (loanIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalShares;
        for (uint256 i; i < loanIds.length; i++) {
            uint256 shares = loanProceeds[core][loanIds[i]][msg.sender];
            if (shares > 0) {
                loanProceeds[core][loanIds[i]][msg.sender] = 0;
                totalShares += shares;
                emit LoanProceedsClaimed(loanIds[i], msg.sender, _sharesToUsdc(shares));
            }
        }
        if (totalShares == 0) revert NoProceeds();
        // Redeem by exact shares so no redeem fee is socialized into totalDeposited.
        // Proceeds shares live in loanProceeds (not globalDeposit), so the caller bears only
        // the vault's own redeem fee on their specific proceeds — nothing is mutualized.
        uint256 usdcOut;
        if (vault == address(0)) {
            usdcOut = totalShares;
        } else {
            usdcOut = IERC4626(vault).redeem(totalShares, address(this), address(this));
        }
        USDC.safeTransfer(msg.sender, usdcOut);
    }

    /// @notice Moves the caller's claimable proceeds from one or more loans into their general
    ///         deposit balance and automatically re-enqueues them for all configured assets.
    /// @dev Re-enqueue is skipped for any asset where the lender is already in the queue.
    ///      The lender's cap settings are unchanged by this call.
    ///      Silently skips loans with zero proceeds (no revert on empty).
    ///      All loanIds must belong to the same `core`.
    /// @param core The Core contract whose loans these IDs belong to.
    /// @param loanIds The loan IDs whose proceeds to redeploy (max MAX_BATCH_SIZE).
    function redeployLoanProceeds(address core, uint256[] calldata loanIds) external {
        if (loanIds.length == 0) revert InvalidInput();
        if (loanIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();

        uint256 totalShares;
        for (uint256 i; i < loanIds.length; i++) {
            uint256 shares = loanProceeds[core][loanIds[i]][msg.sender];
            if (shares > 0) {
                loanProceeds[core][loanIds[i]][msg.sender] = 0;
                totalShares += shares;
                emit LoanProceedsRedeployed(loanIds[i], msg.sender, _sharesToUsdc(shares));
            }
        }
        if (totalShares == 0) revert NoProceeds();

        // Proceeds are already in shares. Add directly to deposit accounting.
        _accounts[msg.sender].globalDeposit += totalShares;
        totalDeposited += totalShares;

        // Re-enqueue for configured assets where the lender now has usable capacity.
        address[] storage assets = _lenderAssets[msg.sender];
        uint256 len = assets.length;
        for (uint256 i; i < len; i++) {
            address a = assets[i];
            if (!isQueued[a][msg.sender] && _hasUsableCapacity(msg.sender, a)) {
                _enqueue(a, msg.sender);
            }
        }
    }

    /// @notice Claims proceeds from one or more loans on a given Core, redeploys a specified
    ///         amount back into the lending pool, and withdraws the remainder to the caller.
    /// @dev All proceeds for each loanId are fully consumed (set to zero). The `amount` parameter
    ///      controls how much of the total proceeds is added to globalDeposit vs sent to the lender.
    ///      If `amount` >= total proceeds, all proceeds are redeployed (same as the no-amount overload).
    ///      Reverts if `amount` is 0 (use claimLoanProceeds to withdraw everything instead).
    ///      All loanIds must belong to the same `core`.
    /// @param core The Core contract whose loans these IDs belong to.
    /// @param loanIds The loan IDs whose proceeds to process (max MAX_BATCH_SIZE).
    /// @param amount The USDC amount to redeploy into the lending pool.
    function redeployLoanProceeds(address core, uint256[] calldata loanIds, uint256 amount) external {
        if (loanIds.length == 0) revert InvalidInput();
        if (loanIds.length > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (amount == 0) revert InvalidInput();

        uint256 totalShares;
        for (uint256 i; i < loanIds.length; i++) {
            uint256 shares = loanProceeds[core][loanIds[i]][msg.sender];
            if (shares > 0) {
                loanProceeds[core][loanIds[i]][msg.sender] = 0;
                totalShares += shares;
                emit LoanProceedsRedeployed(loanIds[i], msg.sender, _sharesToUsdc(shares));
            }
        }
        if (totalShares == 0) revert NoProceeds();

        // Keep accounting in shares throughout to avoid net/gross domain mixing.
        // Convert the user's USDC request to shares (gross) and cap at what we have.
        uint256 toRedeployShares = _usdcToShares(amount);
        if (toRedeployShares > totalShares) toRedeployShares = totalShares;
        uint256 toWithdrawShares = totalShares - toRedeployShares;

        // Redeploy: add shares directly to deposit accounting
        _accounts[msg.sender].globalDeposit += toRedeployShares;
        totalDeposited += toRedeployShares;

        // Re-enqueue for configured assets where the lender now has usable capacity.
        address[] storage assets = _lenderAssets[msg.sender];
        uint256 len = assets.length;
        for (uint256 i; i < len; i++) {
            address a = assets[i];
            if (!isQueued[a][msg.sender] && _hasUsableCapacity(msg.sender, a)) {
                _enqueue(a, msg.sender);
            }
        }

        // Withdraw remainder by exact shares; no fee socialization into totalDeposited.
        uint256 toWithdrawUsdc;
        if (toWithdrawShares > 0) {
            if (vault == address(0)) {
                toWithdrawUsdc = toWithdrawShares;
            } else {
                toWithdrawUsdc = IERC4626(vault).redeem(toWithdrawShares, address(this), address(this));
            }
            USDC.safeTransfer(msg.sender, toWithdrawUsdc);
        }

        emit PartialRedeploy(msg.sender, _sharesToUsdc(toRedeployShares), toWithdrawUsdc);
    }

    // =============================================================
    //                          CORE ACTIONS
    // =============================================================

    /// @notice Walks the FIFO queue and locks liquidity from lenders to fill a loan.
    /// @dev Queue advancement rules:
    ///      - `canLend < minAssetCap`: lender dequeued, walk advances.
    ///      - `minFillPerLender > 0 && canLend < minFillPerLender`: lender skipped but kept in queue.
    ///      - Lender is fully drained by the take: dequeued, walk advances.
    ///      - Lender is partially taken and loan is filled: lender stays in queue.
    ///      At most `effectiveMax = min(maxLenders == 0 ? maxLendersPerFill : maxLenders, maxLendersPerFill)`
    ///      lenders are touched per call. Partial fills are possible if the queue is exhausted
    ///      before `needed` is met.
    /// @param asset The collateral asset address to source liquidity for.
    /// @param needed The total USDC amount requested.
    /// @param maxLenders Per-call cap on lenders walked. 0 uses the ledger default. Bounded by maxLendersPerFill.
    /// @param minFillPerLender Skip any lender whose canLend is below this. 0 disables the filter.
    /// @param loanId The Core-assigned loan ID. Used to record per-loan share locks for precise unlock.
    /// @return totalFound Total USDC amount successfully locked.
    /// @return lenders Lender addresses that contributed (length == effectiveMax, trailing zeros unused).
    /// @return amounts Corresponding locked amounts per lender (parallel to lenders array).
    /// @return foundCount Number of lenders that actually contributed (valid entries in lenders/amounts).
    function requestLiquidity(
        address asset,
        uint256 needed,
        uint8 maxLenders,
        uint256 minFillPerLender,
        uint256 loanId
    )
        external
        returns (uint256 totalFound, address[] memory lenders, uint256[] memory amounts, uint256 foundCount)
    {
        _onlyActiveCore();

        // Cap at what the vault can actually deliver. Matching uses net withdrawable
        // liquidity so requestLiquidity never locks more USDC than the vault can fund.
        uint256 deliverable = _vaultDeliverable();
        if (needed > deliverable) needed = deliverable;

        uint8 globalMax = maxLendersPerFill;
        uint8 limit = maxLenders == 0
            ? globalMax
            : (maxLenders < globalMax ? maxLenders : globalMax);
        lenders = new address[](limit);
        amounts = new uint256[](limit);
        uint256 totalSharesLocked;

        // Traverse with prev/current/next so downstream dequeues reconnect
        // the linked list even when a head or earlier node was skipped (not dequeued).
        address prev = address(0);
        address current = _assetQueues[asset].head;

        while (current != address(0) && totalFound < needed && foundCount < limit) {
            address next = nextInLine[asset][current];

            uint256 idleSharesWalk = _accounts[current].globalDeposit - _accounts[current].globalLocked;
            // Net withdrawable USDC is correct here — we can only match USDC the vault can
            // actually deliver. Redeem fees are localized to matched lenders via previewWithdraw
            // share locks, not socialized globally. Using net is intentional.
            uint256 idleUsdc = _sharesToUsdcNet(idleSharesWalk);
            uint256 _maxCap = _caps[current][asset].maxCap;
            // utilized is USDC; compare directly without share conversion.
            uint256 capUtilizedUsdc = _caps[current][asset].utilized;
            uint256 availAsset = _maxCap > capUtilizedUsdc ? _maxCap - capUtilizedUsdc : 0;
            uint256 canLend = idleUsdc < availAsset ? idleUsdc : availAsset;

            if (canLend < minAssetCap) {
                // Below the ledger minimum — dequeue and reconnect via _unlinkQueued.
                _unlinkQueued(asset, prev, current, next);
                current = next;
                // prev stays unchanged: it still points to the last live node.
            } else if (minFillPerLender > 0 && canLend < minFillPerLender) {
                // Below this loan's per-lender floor — skip without dequeuing.
                prev = current;
                current = next;
            } else {
                uint256 stillNeeded = needed - totalFound;
                uint256 take = canLend < stillNeeded ? canLend : stillNeeded;

                // If the remaining need is below the per-fill minimum, the resulting
                // lender position would be dust. Stop matching — lender stays queued.
                if (take < minAssetCap) break;
                if (minFillPerLender > 0 && take < minFillPerLender) break;

                // Lock fee-inclusive shares: previewWithdraw(take) == shares that disburseLoan will burn.
                // Ensures sum(globalDeposit) == totalDeposited throughout the loan lifecycle.
                // _sharesToUsdcNet(idleSharesWalk) guarantees previewWithdraw(take) <= idleSharesWalk.
                // If that invariant is ever violated (e.g. future vault with unexpected rounding), the
                // transaction must revert rather than silently under-lock shares while recording the
                // full take in amounts[]/totalFound.
                uint256 takeShares = _usdcToWithdrawShares(take);
                if (takeShares > idleSharesWalk) revert ShareAccountingInvariantBroken();
                _accounts[current].globalLocked += takeShares;
                // Track USDC amount, not shares, so cap utilization doesn't drift with vault appreciation.
                _caps[current][asset].utilized += take;
                totalUtilizedUsdc += take;
                totalSharesLocked += takeShares;
                _loanSharesOriginal[msg.sender][loanId][current] += takeShares;
                _loanSharesRemaining[msg.sender][loanId][current] += takeShares;
                // Track USDC separately from shares for correct cap utilization release.
                _loanUsdcRemaining[msg.sender][loanId][current] += take;

                lenders[foundCount] = current;
                amounts[foundCount] = take;
                totalFound += take;
                foundCount++;

                emit LiquidityLocked(current, asset, take);

                if (take == canLend) {
                    // Fully drained — dequeue and reconnect. prev stays unchanged.
                    _unlinkQueued(asset, prev, current, next);
                    current = next;
                } else {
                    // Partially taken because stillNeeded < canLend, so the loan is now satisfied.
                    // Lender stays in queue. Loop exits on the next iteration's condition check.
                    prev = current;
                    current = next;
                }
            }
        }

        totalLocked += totalSharesLocked;
    }

    /// @notice Transfers USDC out of the ledger to Core for disbursement to a borrower.
    /// @dev Called by Core immediately after requestLiquidity. No accounting update needed:
    ///      requestLiquidity locks the shares vault.withdraw(take) will burn (via owner-aware
    ///      previewWithdrawFrom when available, previewWithdraw otherwise), which exactly equals
    ///      the shares _unwrapFromVault burns here. Per-lender and global accounting remain
    ///      consistent — sum(globalDeposit) == totalDeposited is preserved.
    /// @param to Recipient address (Core contract, which then forwards to borrower minus fee).
    /// @param amount USDC amount to transfer out.
    function disburseLoan(address to, uint256 amount) external {
        _onlyActiveCore();
        _unwrapFromVault(amount);
        USDC.safeTransfer(to, amount);
        emit LoanDisbursed(to, amount);
    }

    /// @notice Settles a lender's buyback payment using the actual vault shares minted by the
    ///         prior pullBuybackPayment call for this loan. Handles both principal unlock and
    ///         yield crediting based on the lender's auto-redeploy preference.
    /// @dev Requires a preceding pullBuybackPayment(from, amount, loanId) call from the same Core.
    ///      lenderActualShares = pendingShares * totalPayment / pendingUsdc (proportional allocation).
    ///      The last lender (usdcAllocated + totalPayment == pendingUsdc) receives remaining shares
    ///      to absorb integer-division rounding. Pending state is deleted on final settlement.
    ///
    ///      Lender credits are based on vault-minted shares, not _usdcToShares conversions that
    ///      ignore mint fees or vault share appreciation.
    ///
    ///      Auto-redeploy ON:  principal stays idle; net share delta (actual - locked) applied to deposit.
    ///                         Positive = yield shares added. Negative = deposit trimmed to vault reality.
    ///      Auto-redeploy OFF: principalLockedRelease leaves deposit; lenderActualShares go to proceeds.
    /// @param loanId The loan ID being repaid.
    /// @param lender The lender receiving the payment.
    /// @param asset The collateral asset the liquidity was locked for.
    /// @param principal The USDC principal component of this lender's payment.
    /// @param totalPayment The full USDC payment to this lender (principal + yield).
    ///                     Sum across all lenders must equal the pullBuybackPayment amount.
    /// @param originalFunded The total USDC originally locked for this lender at loan origination.
    function settleBuybackForLender(
        uint256 loanId,
        address lender,
        address asset,
        uint256 principal,
        uint256 totalPayment,
        uint256 originalFunded
    ) external {
        _onlyActiveCore();

        // ── Pending payment guard ────────────────────────────────────────────────
        uint256 pendingUsdc = _pendingPaymentUsdc[msg.sender][loanId];
        uint256 pendingShares = _pendingPaymentShares[msg.sender][loanId];
        if (pendingUsdc == 0) revert NoPendingPayment();

        // ── Allocate this lender's proportional share of actual minted shares ───
        // Last lender gets remaining shares to absorb integer-division rounding.
        // Over-allocation (sum of lenderPayments > pendingUsdc) reverts rather than
        // silently treating the excess as a final settlement.
        uint256 usdcAllocated = _pendingPaymentUsdcAllocated[msg.sender][loanId];
        uint256 sharesAllocated = _pendingPaymentSharesAllocated[msg.sender][loanId];
        uint256 newUsdcAllocated = usdcAllocated + totalPayment;
        if (newUsdcAllocated > pendingUsdc) revert ShareAccountingInvariantBroken();
        bool isFinalLender = (newUsdcAllocated == pendingUsdc);
        uint256 lenderActualShares;
        if (isFinalLender) {
            lenderActualShares = pendingShares > sharesAllocated ? pendingShares - sharesAllocated : 0;
            delete _pendingPaymentUsdc[msg.sender][loanId];
            delete _pendingPaymentShares[msg.sender][loanId];
            delete _pendingPaymentUsdcAllocated[msg.sender][loanId];
            delete _pendingPaymentSharesAllocated[msg.sender][loanId];
        } else {
            lenderActualShares = pendingShares * totalPayment / pendingUsdc;
            if (sharesAllocated + lenderActualShares > pendingShares) revert ShareAccountingInvariantBroken();
            _pendingPaymentUsdcAllocated[msg.sender][loanId] = newUsdcAllocated;
            _pendingPaymentSharesAllocated[msg.sender][loanId] = sharesAllocated + lenderActualShares;
        }

        // ── Validate loan accounting state ──────────────────────────────────────
        uint256 originalShares = _loanSharesOriginal[msg.sender][loanId][lender];
        if (originalShares == 0 || originalFunded == 0) revert InvalidLoanAccounting();
        uint256 remainingShares = _loanSharesRemaining[msg.sender][loanId][lender];
        uint256 remainingUsdc = _loanUsdcRemaining[msg.sender][loanId][lender];
        if (remainingShares == 0 && remainingUsdc == 0) revert NothingToSettle();
        if (remainingShares == 0 || remainingUsdc == 0) revert InvalidLoanAccounting();

        // ── Compute release using live remaining-state ratio ─────────────────────
        // Uses remainingShares/remainingUsdc (not original) to prevent cumulative rounding
        // drift across partial settlements and correctly reflect vault appreciation.
        if (principal == 0) revert SettlementTooSmall();
        uint256 principalLockedRelease;
        uint256 assetRelease;
        if (principal >= remainingUsdc) {
            // Final settlement: sweep exact remaining state.
            principalLockedRelease = remainingShares;
            assetRelease = remainingUsdc;
        } else {
            principalLockedRelease = remainingShares * principal / remainingUsdc;
            if (principalLockedRelease == 0) revert SettlementTooSmall();
            assetRelease = principal;
        }

        // ── Release lock tracking ────────────────────────────────────────────────
        _loanSharesRemaining[msg.sender][loanId][lender] = remainingShares - principalLockedRelease;
        _loanUsdcRemaining[msg.sender][loanId][lender] = remainingUsdc - assetRelease;
        if (principalLockedRelease > _accounts[lender].globalLocked) revert ShareAccountingInvariantBroken();
        if (assetRelease > _caps[lender][asset].utilized) revert ShareAccountingInvariantBroken();
        _accounts[lender].globalLocked -= principalLockedRelease;
        _caps[lender][asset].utilized -= assetRelease;
        totalUtilizedUsdc -= assetRelease;
        totalLocked -= principalLockedRelease;
        // If lender opted out (maxCap == 0) and the loan is now fully settled, free the slot.
        if (_caps[lender][asset].utilized == 0 && _caps[lender][asset].maxCap == 0
                && _lenderAssetConfigured[lender][asset]) {
            _removeLenderAsset(lender, asset);
        }

        // ── Credit deposit / proceeds with vault-actual shares ────────────────────
        if (_autoRedeployDisabled[lender]) {
            // Manual mode: principal portion leaves deposit; actual minted shares go to proceeds.
            if (principalLockedRelease > _accounts[lender].globalDeposit) revert ShareAccountingInvariantBroken();
            if (principalLockedRelease > totalDeposited) revert ShareAccountingInvariantBroken();
            _accounts[lender].globalDeposit -= principalLockedRelease;
            totalDeposited -= principalLockedRelease;
            loanProceeds[msg.sender][loanId][lender] += lenderActualShares;
            emit LoanProceedsCredited(loanId, lender, totalPayment);
        } else {
            // Auto-redeploy: principal stays idle (lock released above). Apply net share delta.
            if (lenderActualShares >= principalLockedRelease) {
                // Normal case: yield shares (actual minus locked release) added to deposit.
                uint256 yieldShares = lenderActualShares - principalLockedRelease;
                _accounts[lender].globalDeposit += yieldShares;
                totalDeposited += yieldShares;
            } else {
                // Vault appreciated: repayment minted fewer shares than originally locked.
                // Trim deposit to reflect true vault backing.
                uint256 delta = principalLockedRelease - lenderActualShares;
                if (delta > _accounts[lender].globalDeposit) revert ShareAccountingInvariantBroken();
                if (delta > totalDeposited) revert ShareAccountingInvariantBroken();
                _accounts[lender].globalDeposit -= delta;
                totalDeposited -= delta;
            }
            // Auto-redeploy settlement restored idle/cap capacity — re-enqueue if eligible.
            // Manual mode skips this: proceeds are claimable, not automatically lendable.
            if (!isQueued[asset][lender] && _hasUsableCapacity(lender, asset)) {
                _enqueue(asset, lender);
            }
        }

        emit LiquidityReleased(lender, asset, principal);
    }

    /// @notice Pulls buyback USDC from the borrower, deposits it into the vault, and records
    ///         the actual shares minted for proportional distribution across lenders.
    /// @dev Called by Core once per buyback payment before settleBuybackForLender. The borrower
    ///      must have approved this contract (not Core) for USDC transfers. Keyed by loanId so
    ///      concurrent loans remain isolated. Resets any prior allocation state for the same
    ///      (core, loanId) pair to support multiple partial payments over a loan's lifetime.
    /// @param from The borrower address to pull USDC from.
    /// @param amount The USDC amount to pull.
    /// @param loanId The loan ID this payment corresponds to.
    function pullBuybackPayment(address from, uint256 amount, uint256 loanId) external {
        _onlyActiveCore();
        USDC.safeTransferFrom(from, address(this), amount);
        uint256 actualShares = _wrapToVault(amount);
        _pendingPaymentUsdc[msg.sender][loanId] = amount;
        _pendingPaymentShares[msg.sender][loanId] = actualShares;
        delete _pendingPaymentUsdcAllocated[msg.sender][loanId];
        delete _pendingPaymentSharesAllocated[msg.sender][loanId];
    }

    /// @notice Writes off a lender's position when a loan expires unredeemed (default path).
    /// @dev Decrements both globalLocked and globalDeposit to reflect that the principal USDC
    ///      was permanently lost — the lender receives collateral tokens as compensation instead
    ///      (handled by Core). No USDC returns to this contract on this path.
    /// @param loanId The loan ID being written off.
    /// @param lender The lender whose position to write off.
    /// @param asset The collateral asset the liquidity was locked for.
    function writeOffPosition(uint256 loanId, address lender, address asset) external {
        _onlyActiveCore();
        uint256 shares = _loanSharesRemaining[msg.sender][loanId][lender];
        uint256 assetRelease = _loanUsdcRemaining[msg.sender][loanId][lender];
        if (shares == 0 && assetRelease == 0) revert NothingToWriteOff();
        if (shares == 0 || assetRelease == 0) revert InvalidLoanAccounting();
        if (shares > _accounts[lender].globalLocked) revert ShareAccountingInvariantBroken();
        if (shares > _accounts[lender].globalDeposit) revert ShareAccountingInvariantBroken();
        _loanSharesRemaining[msg.sender][loanId][lender] = 0;
        _loanUsdcRemaining[msg.sender][loanId][lender] = 0;
        if (assetRelease > _caps[lender][asset].utilized) revert ShareAccountingInvariantBroken();

        _accounts[lender].globalLocked -= shares;
        _accounts[lender].globalDeposit -= shares;
        _caps[lender][asset].utilized -= assetRelease;
        totalUtilizedUsdc -= assetRelease;
        totalLocked -= shares;
        totalDeposited -= shares;
        // If lender opted out (maxCap == 0) and fully written off, free the slot.
        if (_caps[lender][asset].utilized == 0 && _caps[lender][asset].maxCap == 0
                && _lenderAssetConfigured[lender][asset]) {
            _removeLenderAsset(lender, asset);
        }
        // Re-enqueue if the lender still has usable capacity after absorbing the loss.
        if (!isQueued[asset][lender] && _hasUsableCapacity(lender, asset)) {
            _enqueue(asset, lender);
        }
        emit PositionWrittenOff(lender, asset, shares, assetRelease);
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    /// @dev Deposits USDC into the ERC-4626 vault. Returns shares received.
    ///      When vault is address(0), returns the USDC amount (1:1).
    function _wrapToVault(uint256 amount) internal returns (uint256 sharesReceived) {
        if (amount == 0) return 0;
        if (vault == address(0)) return amount;
        if (USDC.allowance(address(this), vault) < amount) {
            USDC.forceApprove(vault, type(uint256).max);
        }
        sharesReceived = IERC4626(vault).deposit(amount, address(this));
        if (sharesReceived == 0) revert VaultDepositFailed();
    }

    /// @dev Maximum USDC the vault can actually deliver right now. Per-lender idle
    ///      balances reflect locked fee-inclusive shares so sum(globalDeposit) equals
    ///      totalDeposited; this cap guards against any residual gap from the proceeds
    ///      claim path or direct vault donations. Callers use it to cap amounts at reality.
    function _vaultDeliverable() internal view returns (uint256) {
        if (vault == address(0)) return type(uint256).max;
        return _sharesToUsdcNet(IERC4626(vault).balanceOf(address(this)));
    }

    /// @dev Withdraws exactly `amount` USDC from the ERC-4626 vault using withdraw().
    ///      Returns actual shares burned. Reverts if amount exceeds vault.maxWithdraw.
    ///      Uses withdraw() not redeem(previewWithdraw()) because fee-bearing vaults can have
    ///      a dead zone where previewWithdraw(X) claims no fee needed, but redeem() applies
    ///      the fee anyway — delivering less than X. withdraw() always delivers exactly X USDC.
    ///      No-op when vault is address(0), returns amount (1:1).
    function _unwrapFromVault(uint256 amount) internal returns (uint256 sharesBurned) {
        if (vault == address(0) || amount == 0) return amount;
        IERC4626 v = IERC4626(vault);
        if (amount > v.maxWithdraw(address(this))) revert VaultMaxWithdrawExceeded();
        sharesBurned = v.withdraw(amount, address(this), address(this));
    }

    /// @dev Converts mUSDC shares to USDC (gross, before redeem fees).
    ///      Use for display/accounting contexts where you want the "owed" value.
    function _sharesToUsdc(uint256 shares) internal view returns (uint256) {
        if (vault == address(0)) return shares;
        return IERC4626(vault).convertToAssets(shares);
    }

    /// @dev Net USDC a given number of shares can actually produce after vault redeem fees,
    ///      verified to be executable through the vault's withdraw path. Uses the same
    ///      round-trip check as mUSDC.maxWithdraw: decrements until previewWithdraw(net)
    ///      fits within the available shares, preventing the previewRedeem/previewWithdraw
    ///      rounding asymmetry from advertising more USDC than _unwrapFromVault can deliver.
    ///      This function assumes the configured vault is the immutable mUSDC vault; the
    ///      last-live-redeemer branch is mUSDC-specific and not safe to use with other ERC-4626 vaults
    ///      that charge a redeem fee.
    function _sharesToUsdcNet(uint256 shares) internal view returns (uint256) {
        if (vault == address(0)) return shares;
        if (shares == 0) return 0;

        IERC4626 v = IERC4626(vault);

        // Mirror mUSDC's withdraw() last-live-redeemer condition: if LendingLedger holds all
        // non-seed shares, mUSDC waives the redeem fee for ANY withdrawal amount (not just
        // full-balance ones). This uses balanceOf(this), matching the owner-aware check in
        // mUSDC.withdraw(), not the amount-based check in mUSDC.previewRedeem(). Written
        // overflow-safe: supply - MUSDC_SEED_AMOUNT <= ledgerBalance rather than
        // ledgerBalance + MUSDC_SEED_AMOUNT >= supply.
        uint256 supply = IERC20(vault).totalSupply();
        uint256 ledgerBalance = IERC20(vault).balanceOf(address(this));
        if (supply <= MUSDC_SEED_AMOUNT || supply - MUSDC_SEED_AMOUNT <= ledgerBalance) {
            return v.convertToAssets(shares);
        }

        uint256 net = v.previewRedeem(shares);
        if (net == 0) return 0;

        // 8 iterations is sufficient for mUSDC's current 25 bps redeem fee in tested ranges.
        // Increase this bound if integrating a vault with materially higher fees or different rounding behavior.
        for (uint256 i; i < 8 && net > 0; i++) {
            if (v.previewWithdraw(net) <= shares) return net;
            net -= 1;
        }

        return net;
    }

    /// @dev Converts USDC to mUSDC shares. When vault is address(0), returns usdc (1:1).
    function _usdcToShares(uint256 usdc) internal view returns (uint256) {
        if (vault == address(0)) return usdc;
        return IERC4626(vault).convertToShares(usdc);
    }

    /// @dev Shares that _unwrapFromVault(usdc) will actually burn via vault.withdraw().
    ///      Uses previewWithdrawFrom (owner-aware) so the locked share count at origination
    ///      matches the burned count at disbursement.
    ///      Falls back to previewWithdraw for standard ERC-4626 vaults without the extension.
    function _usdcToWithdrawShares(uint256 usdc) internal view returns (uint256) {
        if (vault == address(0)) return usdc;
        try IOwnerPreviewVault(vault).previewWithdrawFrom(address(this), usdc) returns (uint256 s) {
            return s;
        } catch {
            return IERC4626(vault).previewWithdraw(usdc);
        }
    }

    /// @dev Returns true only when a lender has both idle liquidity and remaining cap
    ///      that together meet the minimum fill threshold. Used by all enqueue paths
    ///      to prevent unusable entries from bloating the queue.
    function _hasUsableCapacity(address lender, address asset) internal view returns (bool) {
        uint256 idleShares = _accounts[lender].globalDeposit - _accounts[lender].globalLocked;
        uint256 idleUsdc = _sharesToUsdcNet(idleShares);
        AssetCap storage cap = _caps[lender][asset];
        if (cap.maxCap == 0) return false;
        uint256 remainingCap = cap.maxCap > cap.utilized ? cap.maxCap - cap.utilized : 0;
        uint256 usable = idleUsdc < remainingCap ? idleUsdc : remainingCap;
        return usable >= minAssetCap;
    }

    /// @dev Appends a lender to the tail of the FIFO queue for the given asset.
    function _enqueue(address asset, address lender) internal {
        Queue storage q = _assetQueues[asset];
        if (q.head == address(0)) {
            q.head = lender;
            q.tail = lender;
        } else {
            nextInLine[asset][q.tail] = lender;
            q.tail = lender;
        }
        isQueued[asset][lender] = true;
        emit Enqueued(lender, asset);
    }

    /// @dev Removes `current` from the FIFO queue for `asset`, safely reconnecting the
    ///      linked list regardless of whether current is the head, tail, or a middle node.
    ///      `prev` is the last node that was NOT removed (address(0) when current == head).
    ///      `next` must be current's original nextInLine, captured before this call.
    function _unlinkQueued(address asset, address prev, address current, address next) internal {
        Queue storage q = _assetQueues[asset];

        if (prev == address(0)) {
            q.head = next;
        } else {
            nextInLine[asset][prev] = next;
        }

        if (q.tail == current) {
            q.tail = prev;
        }

        nextInLine[asset][current] = address(0);
        isQueued[asset][current] = false;

        // Extra safety: if head was just set to zero, ensure tail is also zero.
        if (q.head == address(0)) {
            q.tail = address(0);
        }
    }

    /// @dev Swap-and-pop removal of an asset from a lender's configured asset list.
    ///      O(n) scan bounded by MAX_CONFIGURED_ASSETS (50).
    function _removeLenderAsset(address lender, address asset) internal {
        address[] storage arr = _lenderAssets[lender];
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == asset) {
                arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
        }
        _lenderAssetConfigured[lender][asset] = false;
    }

    // =============================================================
    //                         VIEW FUNCTIONS
    // =============================================================

    /// @notice Returns protocol-wide aggregate USDC stats.
    /// @return deposited Total USDC value of all lender positions: idle share value + active loan principal.
    /// @return locked Total USDC principal currently locked across all active loans (sum of cap utilization).
    /// @return idle Total net USDC available for new loans (physical idle shares, post-fee, capped at vault deliverable).
    function getProtocolStats() external view returns (uint256 deposited, uint256 locked, uint256 idle) {
        locked = totalUtilizedUsdc;
        idle = _sharesToUsdcNet(totalDeposited - totalLocked);
        uint256 deliverable = _vaultDeliverable();
        if (idle > deliverable) idle = deliverable;
        deposited = idle + locked;
    }

    /// @notice Returns the depth (number of lenders) in the FIFO queue for an asset.
    /// @dev O(n) walk over the linked list. Safe for off-chain view calls.
    /// @param asset The collateral asset address to query.
    /// @return depth Number of lenders currently queued for this asset.
    function getQueueDepth(address asset) external view returns (uint256 depth) {
        address current = _assetQueues[asset].head;
        while (current != address(0)) {
            depth++;
            current = nextInLine[asset][current];
        }
    }

    /// @notice Returns the USDC amount actually matchable for a new loan against this asset,
    ///         respecting the maxLendersPerFill cap, each lender's idle + asset-cap constraints,
    ///         and an optional minFillPerLender filter for single-lender / chunky-fill scenarios.
    /// @dev Mirrors the requestLiquidity walk but read-only: walks the queue from head up to
    ///      maxLendersPerFill lenders, summing min(globalIdle, assetCapRemaining) per qualifying lender.
    ///      Lenders whose canLend is below `minFillPerLender` are skipped (but would remain queued
    ///      in a real call); lenders below `minAssetCap` are also skipped in this preview.
    /// @param asset The collateral asset address to query.
    /// @param minFillPerLender Minimum canLend a lender must offer to count. 0 = no minimum.
    /// @return matchable Total USDC a borrower could receive right now for this asset under these constraints.
    /// @return lenderCount Number of lenders that would participate in the fill.
    function getMatchableLiquidity(address asset, uint256 minFillPerLender)
        external
        view
        returns (uint256 matchable, uint256 lenderCount)
    {
        uint8 limit = maxLendersPerFill;
        address current = _assetQueues[asset].head;
        uint256 deliverable = _vaultDeliverable();

        while (current != address(0) && lenderCount < limit) {
            uint256 idle = _sharesToUsdcNet(_accounts[current].globalDeposit - _accounts[current].globalLocked);
            uint256 _maxCap = _caps[current][asset].maxCap;
            uint256 _utilizedUsdc = _caps[current][asset].utilized;
            uint256 availAsset = _maxCap > _utilizedUsdc ? _maxCap - _utilizedUsdc : 0;
            uint256 canLend = idle < availAsset ? idle : availAsset;

            if (canLend >= minAssetCap && (minFillPerLender == 0 || canLend >= minFillPerLender)) {
                matchable += canLend;
                lenderCount++;
            }

            current = nextInLine[asset][current];
        }
        // Cap at vault reality
        if (matchable > deliverable) matchable = deliverable;
    }

    /// @notice Returns the total matchable USDC for each asset in a single call.
    /// @dev Convenience batch wrapper around getMatchableLiquidity for multicall-free usage.
    ///      A single `minFillPerLender` is applied uniformly across all assets queried.
    /// @param assets Array of collateral asset addresses to query.
    /// @param minFillPerLender Minimum canLend a lender must offer. 0 = no minimum.
    /// @return matchable Array of matchable USDC amounts (same order as input).
    /// @return lenderCounts Array of lender counts per asset.
    function getMatchableLiquidityBatch(address[] calldata assets, uint256 minFillPerLender)
        external
        view
        returns (uint256[] memory matchable, uint256[] memory lenderCounts)
    {
        matchable = new uint256[](assets.length);
        lenderCounts = new uint256[](assets.length);

        for (uint256 i; i < assets.length; i++) {
            (matchable[i], lenderCounts[i]) = this.getMatchableLiquidity(assets[i], minFillPerLender);
        }
    }

    /// @notice Returns a complete snapshot of a lender's account and all configured asset positions.
    /// @dev Combines getAccount + getLenderAssets + getAssetCap + isLenderQueued into one call.
    /// @param lender The lender address to query.
    /// @return deposited Total USDC value of the lender's position: idle share value + active loan principal.
    /// @return locked Total USDC principal locked in active loans (sum of per-asset cap utilization).
    /// @return idle Net USDC value of unlocked vault shares (post-fee, capped at vault deliverable).
    /// @return assets Configured asset addresses (non-zero cap).
    /// @return maxCaps Maximum allocation per asset.
    /// @return utilized Amount currently locked per asset in USDC.
    /// @return queued Whether the lender is currently queued per asset.
    function getLenderSummary(address lender)
        external
        view
        returns (
            uint256 deposited,
            uint256 locked,
            uint256 idle,
            address[] memory assets,
            uint256[] memory maxCaps,
            uint256[] memory utilized,
            bool[] memory queued
        )
    {
        Account storage acct = _accounts[lender];
        assets = _lenderAssets[lender];
        uint256 len = assets.length;
        maxCaps = new uint256[](len);
        utilized = new uint256[](len);
        queued = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            AssetCap storage cap = _caps[lender][assets[i]];
            maxCaps[i] = cap.maxCap;
            utilized[i] = cap.utilized;
            queued[i] = isQueued[assets[i]][lender];
            locked += cap.utilized;
        }

        idle = _sharesToUsdcNet(acct.globalDeposit - acct.globalLocked);
        uint256 deliverable = _vaultDeliverable();
        if (idle > deliverable) idle = deliverable;
        deposited = idle + locked;
    }

    /// @notice Returns the account totals for a lender.
    /// @dev `locked` uses per-asset USDC cap utilization rather than converting locked shares at
    ///      the current vault exchange rate. Locked shares are redeemed when a loan is disbursed
    ///      and no longer exist in the vault, so applying the live PPS to them produces inflated
    ///      values whenever the vault exchange rate rises after disbursement (e.g. from fee donations
    ///      with few idle shares). `idle` is unaffected — those shares still physically exist in vault.
    /// @param lender The lender address to query.
    /// @return deposited Total USDC value of the lender's position: idle share value + active loan principal.
    /// @return locked Total USDC principal currently locked in active loans (sum of per-asset cap utilization).
    /// @return idle Net USDC value of unlocked vault shares available for withdrawal or new loans.
    function getAccount(address lender)
        external
        view
        returns (uint256 deposited, uint256 locked, uint256 idle)
    {
        Account storage acct = _accounts[lender];
        address[] storage assets = _lenderAssets[lender];
        uint256 len = assets.length;
        for (uint256 i; i < len; i++) {
            locked += _caps[lender][assets[i]].utilized;
        }
        idle = _sharesToUsdcNet(acct.globalDeposit - acct.globalLocked);
        uint256 deliverable = _vaultDeliverable();
        if (idle > deliverable) idle = deliverable;
        deposited = idle + locked;
    }

    /// @notice Returns the asset-specific cap and utilization for a lender.
    /// @param lender The lender address to query.
    /// @param asset The collateral asset address to query.
    /// @return maxCap The lender's maximum allocation for this asset.
    /// @return utilized The amount currently locked for this asset.
    /// @return remaining The remaining allocatable amount (maxCap - utilized).
    function getAssetCap(address lender, address asset)
        external
        view
        returns (uint256 maxCap, uint256 utilized, uint256 remaining)
    {
        AssetCap storage cap = _caps[lender][asset];
        // utilized is USDC; no share conversion needed
        uint256 rem = cap.maxCap > cap.utilized ? cap.maxCap - cap.utilized : 0;
        return (cap.maxCap, cap.utilized, rem);
    }

    /// @notice Returns the claimable proceeds for a specific Core's loan and lender, in USDC.
    /// @dev Converts internal share-denominated proceeds to USDC at current vault rate.
    /// @param core The Core contract namespace the loan ID belongs to.
    /// @param loanId The loan ID within that Core's namespace.
    /// @param lender The lender address to query.
    function getLoanProceedsUsdc(address core, uint256 loanId, address lender) external view returns (uint256) {
        return _sharesToUsdc(loanProceeds[core][loanId][lender]);
    }

    /// @notice Returns the full list of assets a lender has configured caps for.
    /// @dev Readable directly from chain — no subgraph or event parsing required.
    /// @param lender The lender address to query.
    /// @return Array of asset addresses with active (non-zero) cap configurations.
    function getLenderAssets(address lender) external view returns (address[] memory) {
        return _lenderAssets[lender];
    }

    /// @notice Returns the head and tail of an asset's FIFO queue.
    /// @param asset The collateral asset address to query.
    /// @return head Address of the first lender in the queue.
    /// @return tail Address of the last lender in the queue.
    function getQueue(address asset) external view returns (address head, address tail) {
        return (_assetQueues[asset].head, _assetQueues[asset].tail);
    }

    /// @notice Returns whether a lender is currently in the queue for a specific asset.
    /// @param asset The collateral asset address to query.
    /// @param lender The lender address to check.
    /// @return True if the lender is currently queued.
    function isLenderQueued(address asset, address lender) external view returns (bool) {
        return isQueued[asset][lender];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IOracleAdapter.sol";

// =============================================================
//                     MINIMAL INTERFACES
// =============================================================

interface IPyth {
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
}

interface IAssetManager {
    function getOracleParams(address asset)
        external
        view
        returns (
            OraclePath[] memory sources,
            OraclePath[] memory wethSources,
            uint256 maxDeviationBps,
            uint16 maxLtvBps,
            uint8 minSources,
            bool active,
            uint256 maxExposureUsdc
        );
}

interface IOracleManager {
    function getPriceReport(OraclePath[] calldata sources, OraclePath[] calldata wethSources)
        external
        view
        returns (uint256 minPriceUsdc18, uint256 maxPriceUsdc18, uint256 maxDeviationBps, uint8 validCount);
}

interface ILendingLedger {
    function requestLiquidity(
        address asset,
        uint256 needed,
        uint8 maxLenders,
        uint256 minFillPerLender,
        uint256 loanId
    )
        external
        returns (uint256 totalFound, address[] memory lenders, uint256[] memory amounts, uint256 foundCount);
    function disburseLoan(address to, uint256 amount) external;
    function settleBuybackForLender(uint256 loanId, address lender, address asset, uint256 principal, uint256 totalPayment, uint256 originalFunded) external;
    function pullBuybackPayment(address from, uint256 amount, uint256 loanId) external;
    function writeOffPosition(uint256 loanId, address lender, address asset, uint256 amount) external;
}

interface IFeeDistributor {
    function getGlobalFee() external view returns (uint16);
    function distributeFees(address asset, uint256 amount) external;
}

/// @title BasedLoansCore
/// @notice Orchestrates the full pawn-shop loan lifecycle for Based Loans: origination, partial/full
///         buyback, and defaulted collateral claims.
/// @dev Flow summary:
///      1. Borrower calls openLoan() with collateral + optional Pyth price update data.
///      2. Core prices the collateral, requests USDC liquidity from LendingLedger, and disburses
///         (loan amount minus protocol fee) to the borrower. Fee goes to FeeDistributor.
///      3. Borrower may call buyback() any number of times before expiry, paying down the fixed
///         buyback price and reclaiming a proportional share of their collateral each time.
///      4. If the loan expires with remaining collateral, each lender may call claimCollateral()
///         to receive their proportional share of the remaining collateral tokens.
///
///      Pyth price updates:
///      - Core owns the updatePriceFeeds() call at the start of openLoan().
///      - Pass non-empty pythUpdateData and sufficient msg.value when Pyth sources are configured.
///      - Excess ETH is returned to the caller.
///
///      Pause:
///      - When paused, only new loan origination is blocked. Buybacks and collateral claims
///        continue unaffected so borrowers and lenders can always unwind positions.
///
///      Operator:
///      - An optional operator address can call emergency/agile functions alongside the
///        owner. Set to address(0) to disable.
contract BasedLoansCore is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =============================================================
    //                             ERRORS
    // =============================================================

    error Paused();
    error ZeroAddress();
    error ZeroAmount();
    error AssetNotActive();
    error InsufficientOracleSources(uint8 valid, uint8 required);
    error ExcessivePriceDeviation(uint256 actual, uint256 maximum);
    error LoanTooSmall(uint256 amount, uint256 minimum);
    error InvalidTermIndex();
    error InvalidTermConfig();
    error PythFeeTooLow(uint256 provided, uint256 required);
    error NotBorrower();
    error LoanExpired();
    error LoanInactive();
    error BelowMinBuyback(uint256 amount, uint256 minimum);
    error BuybackExceedsRemaining(uint256 amount, uint256 remaining);
    error ExposureCapExceeded(address asset, uint256 current, uint256 cap);
    error EthRefundFailed();
    error ShortfallTooLarge(uint256 funded, uint256 requested, uint256 maxShortfallBps);
    error ShortfallTooLoose(uint256 borrowerBps, uint256 globalMaxBps);
    error NotOperatorOrOwner();
    error InvalidClaimBatch();
    error InvalidContract(address);

    // =============================================================
    //                             STRUCTS
    // =============================================================

    struct Loan {
        address borrower;
        address asset;
        address ledgerAtOpen;         // Q-03: ledger used when this loan was opened; settlement always routes here
        uint256 collateralAmount;     // Original collateral deposited
        uint256 collateralRemaining;  // Collateral still held by Core
        uint256 totalFunded;          // Total USDC locked from lenders
        uint256 buybackPrice;         // Fixed full repayment amount (set at origination)
        uint256 buybackRemaining;     // Unpaid portion of buybackPrice
        uint256 exposureRemaining;    // L-04: per-loan exposure tracking (avoids assetExposure dust)
        uint32 createdAt;
        uint32 expiryTimestamp;
        bool active;                  // False once fully bought back
        address[] lenders;
        uint256[] amounts;            // Original USDC funded per lender (parallel to lenders)
    }

    // =============================================================
    //                            CONSTANTS
    // =============================================================

    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum USDC loan amount (50 USDC, 6 decimals).
    uint256 public constant MIN_LOAN_USDC = 50e6;

    /// @notice Minimum USDC buyback payment (1 USDC, 6 decimals).
    uint256 public constant MIN_BUYBACK_USDC = 1e6;

    /// @notice Number of supported loan terms.
    uint8 public constant TERM_COUNT = 3;

    /// @notice Sentinel value for borrowerMaxShortfallBps meaning "use the protocol global default."
    ///         Allows borrowers to request exact fill (0) without ambiguity with the default case.
    ///         Frontend should pass this value when no per-loan shortfall override is desired.
    uint256 public constant USE_GLOBAL_SHORTFALL = type(uint16).max;

    // =============================================================
    //                           STORAGE
    // =============================================================

    /// @notice Optional operator address for emergency/agile functions.
    ///         Set to address(0) to disable operator access.
    address public operator;

    IAssetManager public assetManager;
    IOracleManager public oracleManager;
    ILendingLedger public ledger;
    IFeeDistributor public feeDistributor;
    IERC20 public immutable USDC;

    /// @notice Pyth contract used to push price updates before oracle reads.
    IPyth public pyth;

    bool public paused;

    /// @notice Duration in seconds for each term index (0=short, 1=mid, 2=long).
    uint32[3] public termDurations;

    /// @notice Premium in BPS charged to borrowers for each term index.
    uint16[3] public termPremiumsBps;

    uint256 public nextLoanId;

    /// @notice Maximum acceptable shortfall in BPS when liquidity is less than requested.
    ///         If (maxLoanUsdc - totalFunded) / maxLoanUsdc > maxShortfallBps, the loan reverts.
    ///         Default 2500 = 25%. Configurable by owner.
    uint16 public maxShortfallBps = 2500;

    mapping(uint256 => Loan) private _loans;
    mapping(address => uint256[]) private _borrowerLoans;

    /// @notice Tracks whether each lender has claimed their collateral for a defaulted loan.
    mapping(uint256 => mapping(address => bool)) public collateralClaimed;

    /// @notice True once writeOffPosition has been called for all lenders on a defaulted loan.
    mapping(uint256 => bool) public loanSettled;

    /// @notice Snapshot of collateralRemaining at first-claim time for a defaulted loan.
    ///         Fixed base used for all per-lender share calculations to eliminate claim-order dependence.
    mapping(uint256 => uint256) public defaultCollateralBase;

    /// @notice Total USDC currently in active loans per collateral asset.
    mapping(address => uint256) public assetExposure;

    // =============================================================
    //                             EVENTS
    // =============================================================

    /// @dev `core` = address(this). Indexed fields: core, loanId, borrower.
    event LoanOpened(
        address indexed core,
        uint256 indexed loanId,
        address indexed borrower,
        address asset,
        uint256 collateralAmount,
        uint256 totalFunded,
        uint256 netDisbursed,
        uint256 buybackPrice,
        uint32 createdAt,
        uint32 expiryTimestamp
    );
    event BuybackMade(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 payment,
        uint256 collateralReturned,
        uint256 buybackRemaining
    );
    event LoanFullyRepaid(uint256 indexed loanId, address indexed borrower);
    event CollateralClaimed(uint256 indexed loanId, address indexed lender, uint256 collateralAmount);
    event LoanSettled(uint256 indexed loanId);
    event PausedStateChanged(bool paused);
    event OperatorUpdated(address oldOperator, address newOperator);
    event ContractsUpdated(
        address assetManager,
        address oracleManager,
        address ledger,
        address feeDistributor,
        address pyth
    );
    event TermsUpdated(uint32[3] durations, uint16[3] premiumsBps);

    // =============================================================
    //                           MODIFIERS
    // =============================================================

    modifier onlyOperatorOrOwner() {
        if (msg.sender != owner() && (operator == address(0) || msg.sender != operator)) {
            revert NotOperatorOrOwner();
        }
        _;
    }

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    /// @notice Deploys Core with all dependent contract addresses and initial term configuration.
    /// @param _usdc USDC token contract address.
    /// @param _assetManager AssetManager contract address.
    /// @param _oracleManager OracleManager contract address.
    /// @param _ledger LendingLedger contract address.
    /// @param _feeDistributor FeeDistributor contract address.
    /// @param _pyth Pyth oracle contract address (may be zero if no Pyth adapters are used).
    /// @param _owner Address that will own this contract.
    /// @param _operator Optional operator address (address(0) to disable).
    /// @param _termDurations Initial loan durations in seconds for each term index.
    /// @param _termPremiumsBps Initial premiums in BPS for each term index.
    constructor(
        address _usdc,
        address _assetManager,
        address _oracleManager,
        address _ledger,
        address _feeDistributor,
        address _pyth,
        address _owner,
        address _operator,
        uint32[3] memory _termDurations,
        uint16[3] memory _termPremiumsBps
    ) Ownable(_owner) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_assetManager == address(0)) revert ZeroAddress();
        if (_oracleManager == address(0)) revert ZeroAddress();
        if (_ledger == address(0)) revert ZeroAddress();
        if (_feeDistributor == address(0)) revert ZeroAddress();

        if (_assetManager.code.length == 0) revert InvalidContract(_assetManager);
        if (_oracleManager.code.length == 0) revert InvalidContract(_oracleManager);
        if (_ledger.code.length == 0) revert InvalidContract(_ledger);
        if (_feeDistributor.code.length == 0) revert InvalidContract(_feeDistributor);

        USDC = IERC20(_usdc);
        assetManager = IAssetManager(_assetManager);
        oracleManager = IOracleManager(_oracleManager);
        ledger = ILendingLedger(_ledger);
        feeDistributor = IFeeDistributor(_feeDistributor);
        pyth = IPyth(_pyth);
        operator = _operator;

        _setTerms(_termDurations, _termPremiumsBps);
    }

    // =============================================================
    //                       OWNER FUNCTIONS
    // =============================================================

    /// @notice Updates all dependent contract addresses in one call.
    /// @dev Pass address(0) for pyth if no Pyth adapters are in use.
    function setContracts(
        address _assetManager,
        address _oracleManager,
        address _ledger,
        address _feeDistributor,
        address _pyth
    ) external onlyOwner {
        if (_assetManager == address(0)) revert ZeroAddress();
        if (_oracleManager == address(0)) revert ZeroAddress();
        if (_ledger == address(0)) revert ZeroAddress();
        if (_feeDistributor == address(0)) revert ZeroAddress();

        if (_assetManager.code.length == 0) revert InvalidContract(_assetManager);
        if (_oracleManager.code.length == 0) revert InvalidContract(_oracleManager);
        if (_ledger.code.length == 0) revert InvalidContract(_ledger);
        if (_feeDistributor.code.length == 0) revert InvalidContract(_feeDistributor);

        // Updates module addresses for future operations. Existing loans continue settling through their ledgerAtOpen.
        assetManager = IAssetManager(_assetManager);
        oracleManager = IOracleManager(_oracleManager);
        ledger = ILendingLedger(_ledger);
        feeDistributor = IFeeDistributor(_feeDistributor);
        pyth = IPyth(_pyth);

        emit ContractsUpdated(_assetManager, _oracleManager, _ledger, _feeDistributor, _pyth);
    }

    /// @notice Updates loan term durations and premiums.
    /// @param _termDurations Duration in seconds for each term (must be > 0).
    /// @param _termPremiumsBps Premium in BPS for each term (must be > 0).
    function setTerms(uint32[3] calldata _termDurations, uint16[3] calldata _termPremiumsBps) external onlyOwner {
        _setTerms(_termDurations, _termPremiumsBps);
        emit TermsUpdated(_termDurations, _termPremiumsBps);
    }

    /// @notice Sets the operator address. Only callable by the owner.
    /// @param _operator New operator address (address(0) to disable operator access).
    function setOperator(address _operator) external onlyOwner {
        address old = operator;
        operator = _operator;
        emit OperatorUpdated(old, _operator);
    }

    /// @notice Pauses or unpauses new loan origination.
    /// @dev Only openLoan is gated. Buybacks and collateral claims remain active.
    /// @param _paused True to pause, false to unpause.
    function setPaused(bool _paused) external onlyOperatorOrOwner {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    /// @notice Maximum allowed value for maxShortfallBps (40%).
    uint16 public constant MAX_SHORTFALL_CEILING = 4000;

    /// @notice Sets the maximum acceptable shortfall for partial fills.
    /// @param _maxShortfallBps Maximum shortfall in BPS (0 = exact fill only, max 4000 = 40%).
    function setMaxShortfall(uint16 _maxShortfallBps) external onlyOwner {
        if (_maxShortfallBps > MAX_SHORTFALL_CEILING) revert InvalidTermConfig();
        maxShortfallBps = _maxShortfallBps;
    }

    // =============================================================
    //                         MAIN FUNCTIONS
    // =============================================================

    /// @notice Opens a new loan by depositing collateral and receiving USDC.
    /// @dev Calls Pyth updatePriceFeeds if pythUpdateData is non-empty. Any excess ETH
    ///      (above the Pyth update fee) is returned to msg.sender. Loan fills as much
    ///      liquidity as available up to the maximum LTV amount; partial fills are accepted
    ///      provided the funded amount meets MIN_LOAN_USDC.
    /// @param asset Collateral token address (must be active in AssetManager).
    /// @param collateralAmount Amount of collateral tokens to deposit.
    /// @param requestedGrossUsdc Maximum gross USDC to borrow (0 = use max from collateral value).
    ///        Pass the gross amount (before protocol fee) so the contract caps the lender request
    ///        and returns excess collateral. This prevents price-movement surprises between
    ///        UI estimation and on-chain execution.
    /// @param termIndex Loan term: 0 = short, 1 = medium, 2 = long.
    /// @param pythUpdateData Encoded Pyth price update payloads. Pass empty array if not needed.
    /// @return loanId The ID of the newly created loan.
    function openLoan(
        address asset,
        uint256 collateralAmount,
        uint256 requestedGrossUsdc,
        uint8 termIndex,
        uint256 borrowerMaxShortfallBps,
        bytes[] calldata pythUpdateData
    ) external payable nonReentrant returns (uint256 loanId) {
        if (paused) revert Paused();
        if (collateralAmount == 0) revert ZeroAmount();
        if (termIndex >= TERM_COUNT) revert InvalidTermIndex();

        // Push Pyth price updates before any oracle read
        if (pythUpdateData.length > 0 && address(pyth) != address(0)) {
            uint256 pythFee = pyth.getUpdateFee(pythUpdateData);
            if (msg.value < pythFee) revert PythFeeTooLow(msg.value, pythFee);
            pyth.updatePriceFeeds{value: pythFee}(pythUpdateData);
            // Return excess ETH
            if (msg.value > pythFee) {
                (bool ok,) = msg.sender.call{value: msg.value - pythFee}("");
                if (!ok) revert EthRefundFailed();
            }
        } else if (msg.value > 0) {
            // No Pyth data but ETH was sent — return it
            (bool ok,) = msg.sender.call{value: msg.value}("");
            if (!ok) revert EthRefundFailed();
        }

        // Fetch oracle params and validate asset is active
        uint256 maxExposureUsdc;
        OraclePath[] memory sources;
        OraclePath[] memory wethSources;
        uint256 maxDeviationBps;
        uint16 maxLtvBps;
        uint8 minSources;
        {
            bool active;
            (sources, wethSources, maxDeviationBps, maxLtvBps, minSources, active, maxExposureUsdc) =
                assetManager.getOracleParams(asset);
            if (!active) revert AssetNotActive();
        }

        // Get aggregated price report
        (uint256 minPriceUsdc18,, uint256 deviationBps, uint8 validCount) =
            oracleManager.getPriceReport(sources, wethSources);

        if (validCount < minSources) revert InsufficientOracleSources(validCount, minSources);
        if (deviationBps > maxDeviationBps) revert ExcessivePriceDeviation(deviationBps, maxDeviationBps);

        // Calculate prices and collateral math
        uint8 tokenDecimals = IERC20Metadata(asset).decimals();
        uint256 tokenScale = 10 ** tokenDecimals;
        uint256 collateralValueUsdc6 = minPriceUsdc18.mulDiv(collateralAmount, tokenScale * 1e12);
        // maxLtvBps is principal LTV. It caps the USDC principal
        // disbursed to the borrower, not the total buyback obligation. The fixed buyback price
        // is calculated separately after funding using the selected term premium and may exceed
        // this principal cap by the disclosed premium. This matches the pawn shop model.
        uint256 maxPrincipalUsdc = collateralValueUsdc6.mulDiv(maxLtvBps, BPS_DENOMINATOR);

        // Determine target USDC and how much collateral to pull.
        // When requestedGrossUsdc is specified, work backwards from the USDC amount
        // to compute exactly how many tokens are needed at the current price.
        // collateralAmount acts as a safety cap (like amountInMaximum on a swap).
        uint256 targetUsdc;
        uint256 neededCollateral;

        if (requestedGrossUsdc > 0) {
            // Compute tokens needed for the requested USDC at current on-chain price (round up)
            {
                // Round up: tokens needed = requestedUsdc * BPS * tokenScale * 1e12 / (ltv * price)
                neededCollateral = (requestedGrossUsdc * BPS_DENOMINATOR).mulDiv(
                    tokenScale * 1e12, maxLtvBps * minPriceUsdc18, Math.Rounding.Ceil
                );
            }

            if (neededCollateral <= collateralAmount) {
                // User's cap covers it — exact fill
                targetUsdc = requestedGrossUsdc;
            } else {
                // Cap exceeded — use max from the capped collateral amount
                targetUsdc = maxPrincipalUsdc;
                neededCollateral = collateralAmount;
            }
        } else {
            // No specific request: derive target from collateral valuation.
            targetUsdc = maxPrincipalUsdc;
            neededCollateral = collateralAmount;
        }

        // Assign loanId before requestLiquidity so the Ledger can record per-loan share locks.
        loanId = nextLoanId++;

        (uint256 totalFunded, address[] memory lenders, uint256[] memory amounts, uint256 foundCount) =
            ledger.requestLiquidity(asset, targetUsdc, 0, 0, loanId);

        if (totalFunded < MIN_LOAN_USDC) revert LoanTooSmall(totalFunded, MIN_LOAN_USDC);

        // Check per-asset exposure cap
        if (maxExposureUsdc > 0) {
            uint256 newExposure = assetExposure[asset] + totalFunded;
            if (newExposure > maxExposureUsdc) {
                revert ExposureCapExceeded(asset, assetExposure[asset], maxExposureUsdc);
            }
        }

        // Check shortfall — revert if liquidity dropped too far below requested.
        // USE_GLOBAL_SHORTFALL (type(uint16).max) = use protocol default; 0 = exact fill only;
        // any other value must be <= maxShortfallBps (borrower can only be stricter, not looser).
        if (borrowerMaxShortfallBps != USE_GLOBAL_SHORTFALL && borrowerMaxShortfallBps > maxShortfallBps) {
            revert ShortfallTooLoose(borrowerMaxShortfallBps, maxShortfallBps);
        }
        uint256 effectiveShortfallBps = borrowerMaxShortfallBps == USE_GLOBAL_SHORTFALL
            ? maxShortfallBps
            : borrowerMaxShortfallBps;
        if (totalFunded < targetUsdc) {
            uint256 shortfall = (targetUsdc - totalFunded) * BPS_DENOMINATOR / targetUsdc;
            if (shortfall > effectiveShortfallBps) {
                revert ShortfallTooLarge(totalFunded, targetUsdc, effectiveShortfallBps);
            }
        }

        // Compute actual collateral to pull — proportional to what was funded.
        // Round up so partial fills never under-collateralize the protocol.
        uint256 actualCollateral = totalFunded < targetUsdc
            ? neededCollateral.mulDiv(totalFunded, targetUsdc, Math.Rounding.Ceil)
            : neededCollateral;

        // Calculate protocol fee (rounded up) and net disbursement
        uint256 feeBps = feeDistributor.getGlobalFee();
        uint256 fee = (totalFunded * feeBps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        uint256 netDisbursed = totalFunded - fee;

        // Calculate fixed buyback price (principal + premium)
        uint256 premiumBps = termPremiumsBps[termIndex];
        uint256 buybackPrice = totalFunded + totalFunded * premiumBps / BPS_DENOMINATOR;
        uint32 expiryTimestamp = uint32(block.timestamp) + termDurations[termIndex];

        // Store loan — only copy the valid lender entries
        Loan storage loan = _loans[loanId];
        loan.borrower = msg.sender;
        loan.asset = asset;
        loan.collateralAmount = actualCollateral;
        loan.collateralRemaining = actualCollateral;
        loan.ledgerAtOpen = address(ledger);
        loan.totalFunded = totalFunded;
        loan.buybackPrice = buybackPrice;
        loan.buybackRemaining = buybackPrice;
        loan.exposureRemaining = totalFunded;
        loan.createdAt = uint32(block.timestamp);
        loan.expiryTimestamp = expiryTimestamp;
        loan.active = true;
        assetExposure[asset] += totalFunded;

        for (uint256 i = 0; i < foundCount; i++) {
            loan.lenders.push(lenders[i]);
            loan.amounts.push(amounts[i]);
        }

        _borrowerLoans[msg.sender].push(loanId);

        // Pull only the proportional collateral from borrower
        IERC20(asset).safeTransferFrom(msg.sender, address(this), actualCollateral);

        // Disburse USDC: LendingLedger → Core → (FeeDistributor + borrower)
        ledger.disburseLoan(address(this), totalFunded);

        USDC.safeTransfer(address(feeDistributor), fee);
        feeDistributor.distributeFees(asset, fee);

        USDC.safeTransfer(msg.sender, netDisbursed);

        emit LoanOpened(address(this), loanId, msg.sender, asset, actualCollateral, totalFunded, netDisbursed, buybackPrice, uint32(block.timestamp), expiryTimestamp);
    }

    /// @notice Repays some or all of the buyback price to reclaim a proportional share of collateral.
    /// @dev May be called multiple times (partial buybacks). Each payment unlocks
    ///      `collateralAmount * payment / buybackPrice` collateral tokens. The yield premium
    ///      is distributed proportionally to lenders via loanProceeds in LendingLedger.
    ///      Minimum payment is MIN_BUYBACK_USDC (1 USDC).
    /// @param loanId The loan to buy back against.
    /// @param payment USDC amount to pay. Capped at buybackRemaining.
    function buyback(uint256 loanId, uint256 payment) external nonReentrant {
        Loan storage loan = _loans[loanId];

        if (!loan.active) revert LoanInactive();
        if (msg.sender != loan.borrower) revert NotBorrower();
        if (block.timestamp > loan.expiryTimestamp) revert LoanExpired();
        if (payment > loan.buybackRemaining) revert BuybackExceedsRemaining(payment, loan.buybackRemaining);
        if (payment < MIN_BUYBACK_USDC && payment != loan.buybackRemaining) {
            revert BelowMinBuyback(payment, MIN_BUYBACK_USDC);
        }

        bool isFinal = payment == loan.buybackRemaining;

        // Collateral to return: proportional to payment vs original buyback price
        uint256 collateralToReturn = isFinal
            ? loan.collateralRemaining
            : loan.collateralAmount * payment / loan.buybackPrice;

        loan.collateralRemaining -= collateralToReturn;
        loan.buybackRemaining -= payment;

        // L-04: reduce assetExposure by the delta of per-loan exposureRemaining.
        // Using the delta (not a fresh proportional formula) ensures that on the final payment
        // all remaining dust is swept from assetExposure rather than left behind by floor rounding.
        {
            uint256 oldExposure = loan.exposureRemaining;
            uint256 newExposure = isFinal
                ? 0
                : loan.totalFunded * loan.buybackRemaining / loan.buybackPrice;
            // oldExposure >= newExposure always holds: we are paying down, never up.
            uint256 exposureReduction = oldExposure - newExposure;
            if (exposureReduction > assetExposure[loan.asset]) {
                assetExposure[loan.asset] = 0;
            } else {
                assetExposure[loan.asset] -= exposureReduction;
            }
            loan.exposureRemaining = newExposure;
        }

        // Pull payment USDC from borrower FIRST via LendingLedger (borrower approves Ledger, not Core)
        // Q-03: always route through the ledger that was active when this loan was opened.
        ILendingLedger loanLedger = ILendingLedger(loan.ledgerAtOpen);
        loanLedger.pullBuybackPayment(msg.sender, payment, loanId);

        // Distribute payment to lenders: each gets their proportional share
        // Last lender absorbs any integer-division dust
        uint256 lenderCount = loan.lenders.length;
        uint256 remaining = payment;

        for (uint256 i = 0; i < lenderCount; i++) {
            address lender = loan.lenders[i];
            uint256 funded = loan.amounts[i];

            uint256 lenderPayment;
            if (i == lenderCount - 1) {
                lenderPayment = remaining;
            } else {
                lenderPayment = funded * payment / loan.totalFunded;
                remaining -= lenderPayment;
            }

            // Principal controls locked-share release in LendingLedger.
            // On the final buyback, force principal = funded so the Ledger's clamp
            // (principalLockedRelease = min(computed, remainingShares)) absorbs any
            // rounding dust accumulated across partial repayments. Without this,
            // funded * payment / buybackPrice floors at integer division and can leave
            // 1–2 shares locked even after the loan is fully repaid.
            // On partial buybacks, clamp principal to lenderPayment so it never exceeds
            // what was actually paid (they are separate accounting concepts, so the
            // clamp is only needed when proportional math could exceed the payment itself).
            uint256 principal;
            if (isFinal) {
                principal = funded;
            } else {
                principal = funded * payment / loan.buybackPrice;
                if (principal > lenderPayment) principal = lenderPayment;
            }

            // LendingLedger handles the auto-redeploy toggle internally:
            // ON  → principal unlocks to idle, yield added to idle (all auto-redeployed)
            // OFF → principal + yield both go to claimable proceeds
            loanLedger.settleBuybackForLender(loanId, lender, loan.asset, principal, lenderPayment, funded);
        }

        // Return collateral to borrower
        IERC20(loan.asset).safeTransfer(msg.sender, collateralToReturn);

        if (isFinal) {
            loan.active = false;
            emit LoanFullyRepaid(loanId, msg.sender);
        }

        emit BuybackMade(loanId, msg.sender, payment, collateralToReturn, loan.buybackRemaining);
    }

    /// @notice Maximum loan IDs per batch claimCollateral call.
    uint8 public constant MAX_CLAIM_BATCH = 50;

    /// @notice Claims collateral from one or more expired, unredeemed loans.
    /// @dev Silently skips loans that are already claimed, not expired, or where caller is not a lender.
    ///      Settlement (writeOff) happens on the first claim per loan.
    /// @param loanIds The loan IDs to claim collateral from (max MAX_CLAIM_BATCH).
    function claimCollateral(uint256[] calldata loanIds) external nonReentrant {
        if (loanIds.length == 0 || loanIds.length > MAX_CLAIM_BATCH) revert InvalidClaimBatch();

        for (uint256 j; j < loanIds.length; j++) {
            uint256 loanId = loanIds[j];
            Loan storage loan = _loans[loanId];

            if (!loan.active) continue;
            if (block.timestamp <= loan.expiryTimestamp) continue;
            if (collateralClaimed[loanId][msg.sender]) continue;

            // Find caller's lender index
            uint256 lenderCount = loan.lenders.length;
            uint256 lenderIndex = type(uint256).max;
            for (uint256 i = 0; i < lenderCount; i++) {
                if (loan.lenders[i] == msg.sender) {
                    lenderIndex = i;
                    break;
                }
            }
            if (lenderIndex == type(uint256).max) continue;

            // On first claim: write off all lender positions and clear remaining exposure
            if (!loanSettled[loanId]) {
                // L-04: use per-loan exposureRemaining for accurate dust-free accounting.
                uint256 remainingExposure = loan.exposureRemaining;
                if (remainingExposure > assetExposure[loan.asset]) {
                    assetExposure[loan.asset] = 0;
                } else {
                    assetExposure[loan.asset] -= remainingExposure;
                }
                loan.exposureRemaining = 0;

                // Q-03: route write-offs through the ledger that was active at loan open.
                ILendingLedger loanLedger = ILendingLedger(loan.ledgerAtOpen);
                for (uint256 i = 0; i < lenderCount; i++) {
                    address lender = loan.lenders[i];
                    uint256 remainingPrincipal = loan.amounts[i] * loan.buybackRemaining / loan.buybackPrice;
                    // Always call — Ledger uses _loanUsdcRemaining to clear exact tracked state
                    // even when remainingPrincipal rounds to zero on partial-buyback dust.
                    loanLedger.writeOffPosition(loanId, lender, loan.asset, remainingPrincipal);
                }
                defaultCollateralBase[loanId] = loan.collateralRemaining;
                loanSettled[loanId] = true;
                emit LoanSettled(loanId);
            }

            // Calculate collateral share from the fixed defaultCollateralBase so claim order
            // cannot affect proportional entitlement. collateralRemaining is only decremented
            // for transfer accounting, with the final claimant receiving any rounding dust.
            uint256 collateralShare;
            {
                // Count unclaimed lenders to detect the last one
                uint256 unclaimedCount;
                for (uint256 i = 0; i < lenderCount; i++) {
                    if (!collateralClaimed[loanId][loan.lenders[i]]) unclaimedCount++;
                }
                if (unclaimedCount == 1) {
                    // Last claimant gets whatever remains (absorbs integer-division dust)
                    collateralShare = loan.collateralRemaining;
                } else {
                    collateralShare = defaultCollateralBase[loanId] * loan.amounts[lenderIndex] / loan.totalFunded;
                    if (collateralShare > loan.collateralRemaining) collateralShare = loan.collateralRemaining;
                }
            }
            // Mark claimed unconditionally so unclaimedCount decrements even on zero share.
            // Without this, zero-share lenders permanently block the last-claimant dust path.
            collateralClaimed[loanId][msg.sender] = true;

            if (collateralShare > 0) {
                loan.collateralRemaining -= collateralShare;
                IERC20(loan.asset).safeTransfer(msg.sender, collateralShare);
            }

            emit CollateralClaimed(loanId, msg.sender, collateralShare);
        }
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    /// @dev Validates and stores term configuration.
    function _setTerms(uint32[3] memory _durations, uint16[3] memory _premiums) internal {
        for (uint256 i = 0; i < TERM_COUNT; i++) {
            if (_durations[i] == 0 || _premiums[i] == 0) revert InvalidTermConfig();
        }
        termDurations = _durations;
        termPremiumsBps = _premiums;
    }

    // =============================================================
    //                        VIEW FUNCTIONS
    // =============================================================

    /// @notice Returns all configured loan term durations and premiums in one call.
    /// @return durations Duration in seconds for each term index.
    /// @return premiumsBps Premium in BPS for each term index.
    function getTermConfig()
        external
        view
        returns (uint32[3] memory durations, uint16[3] memory premiumsBps)
    {
        return (termDurations, termPremiumsBps);
    }

    /// @notice Returns all loan IDs opened by a borrower in origination order.
    /// @param borrower The borrower address to query.
    function getBorrowerLoans(address borrower) external view returns (uint256[] memory) {
        return _borrowerLoans[borrower];
    }

    /// @notice Returns the collateral amount a lender can currently claim from a defaulted loan.
    /// @dev Returns 0 if the loan is not yet expired, already fully bought back, already claimed,
    ///      or the caller is not a lender on this loan.
    /// @param loanId The loan to check.
    /// @param lender The lender address to check.
    /// @return The collateral token amount claimable, or 0 if not eligible.
    function getClaimableCollateral(uint256 loanId, address lender) external view returns (uint256) {
        Loan storage loan = _loans[loanId];

        if (!loan.active) return 0;
        if (block.timestamp <= loan.expiryTimestamp) return 0;
        if (collateralClaimed[loanId][lender]) return 0;

        uint256 lenderCount = loan.lenders.length;
        for (uint256 i = 0; i < lenderCount; i++) {
            if (loan.lenders[i] == lender) {
                // Use fixed base if settlement has happened; otherwise use live collateralRemaining
                uint256 base = loanSettled[loanId] ? defaultCollateralBase[loanId] : loan.collateralRemaining;
                // Check if this is the last unclaimed lender (absorbs dust)
                uint256 unclaimedCount;
                for (uint256 j = 0; j < lenderCount; j++) {
                    if (!collateralClaimed[loanId][loan.lenders[j]]) unclaimedCount++;
                }
                if (unclaimedCount == 1) return loan.collateralRemaining;
                uint256 share = base * loan.amounts[i] / loan.totalFunded;
                if (share > loan.collateralRemaining) share = loan.collateralRemaining;
                return share;
            }
        }
        return 0;
    }

    /// @notice Returns the full loan details for a given loan ID.
    /// @param loanId The loan to query.
    /// @return borrower Borrower address.
    /// @return asset Collateral token address.
    /// @return collateralAmount Original collateral deposited.
    /// @return collateralRemaining Collateral still held by Core.
    /// @return totalFunded Total USDC locked from lenders at origination.
    /// @return buybackPrice Fixed full repayment amount.
    /// @return buybackRemaining Unpaid portion of the buyback price.
    /// @return createdAt Unix timestamp when the loan was created.
    /// @return expiryTimestamp Unix timestamp when the loan expires.
    /// @return active False if fully bought back.
    /// @return lenders Array of lender addresses who funded the loan.
    /// @return amounts Original USDC funded per lender.
    function getLoan(uint256 loanId)
        external
        view
        returns (
            address borrower,
            address asset,
            uint256 collateralAmount,
            uint256 collateralRemaining,
            uint256 totalFunded,
            uint256 buybackPrice,
            uint256 buybackRemaining,
            uint32 createdAt,
            uint32 expiryTimestamp,
            bool active,
            address[] memory lenders,
            uint256[] memory amounts
        )
    {
        Loan storage loan = _loans[loanId];
        return (
            loan.borrower,
            loan.asset,
            loan.collateralAmount,
            loan.collateralRemaining,
            loan.totalFunded,
            loan.buybackPrice,
            loan.buybackRemaining,
            loan.createdAt,
            loan.expiryTimestamp,
            loan.active,
            loan.lenders,
            loan.amounts
        );
    }

    /// @notice Returns the per-loan exposure remaining (L-04: avoids accumulated division dust).
    function getExposureRemaining(uint256 loanId) external view returns (uint256) {
        return _loans[loanId].exposureRemaining;
    }

    /// @notice Returns the ledger address recorded when this loan was opened (Q-03).
    function getLoanLedger(uint256 loanId) external view returns (address) {
        return _loans[loanId].ledgerAtOpen;
    }

    /// @notice Computes the current collateral value in USDC using a fresh oracle read.
    /// @dev Useful for UI display. Does not update Pyth — call with up-to-date prices on-chain only.
    /// @param loanId The loan to value.
    /// @return collateralValueUsdc6 Current collateral value in USDC (6 decimals).
    function getLoanCollateralValue(uint256 loanId) external view returns (uint256 collateralValueUsdc6) {
        Loan storage loan = _loans[loanId];
        (OraclePath[] memory sources, OraclePath[] memory wethSources,,,,,) =
            assetManager.getOracleParams(loan.asset);
        (uint256 minPriceUsdc18,,,) = oracleManager.getPriceReport(sources, wethSources);
        uint8 tokenDecimals = IERC20Metadata(loan.asset).decimals();
        collateralValueUsdc6 = minPriceUsdc18.mulDiv(loan.collateralRemaining, (10 ** tokenDecimals) * 1e12);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IOracleAdapter.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BasedLoansOracleManager
/// @notice Stateless oracle router and price aggregator for Based Loans.
/// @dev Accepts a generic array of typed OraclePath sources and aggregates them into a
///      normalized USDC price report. Soft-fails individual adapter calls — stale or broken
///      sources are skipped rather than reverting, subject to the caller enforcing minSources.
///
///      Price normalization:
///      - DIRECT_USD      → price used as-is (already USD/USDC, scaled to 1e18)
///      - TOKEN_USDC_POOL → price used as-is (already USDC-denominated, scaled to 1e18)
///      - TOKEN_WETH_POOL → price × wethPriceUsdc18 / 1e18 (requires valid WETH sources)
///
///      WETH pricing:
///      - Only fetched if at least one source is TOKEN_WETH_POOL.
///      - Aggregated as the minimum of all valid WETH source responses (conservative).
///      - If all WETH sources fail, reverts — WETH price unavailability is not soft-failed.
///
///      Caller responsibility:
///      - Checking validCount >= minSources (enforced in Core, not here).
///      - Checking maxDeviationBps <= asset.maxDeviationBps.
contract BasedLoansOracleManager is Ownable {
    using Math for uint256;

    // =============================================================
    //                            CONSTANTS
    // =============================================================

    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10000;

    // =============================================================
    //                             EVENTS
    // =============================================================

    event AdapterApproved(address indexed adapter, bool approved);
    event OperatorUpdated(address oldOperator, address newOperator);
    event StalenessParamsUpdated(uint32 maxPythAge, uint32 minTwapWindow);

    // =============================================================
    //                             ERRORS
    // =============================================================

    error WethPriceUnavailable();
    error NotOperatorOrOwner();
    error InvalidStalenessParams();
    error ZeroAddress();
    error InvalidAdapter(address adapter);

    // =============================================================
    //                           STORAGE
    // =============================================================

    /// @notice Optional operator address for emergency/agile functions.
    address public operator;

    /// @notice Protocol-level ceiling for Pyth maxAge (seconds). Sources configured with
    ///         a higher maxAge are skipped at query time. Default: 300 (5 minutes).
    uint32 public maxPythAge = 300;

    /// @notice Protocol-level floor for TWAP observation window (seconds). Sources configured
    ///         with a shorter window are skipped at query time. Default: 1800 (30 minutes).
    uint32 public minTwapWindow = 1800;

    mapping(address => bool) public approvedAdapters;

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

    /// @notice Deploys the OracleManager.
    /// @param _owner Address that will own this contract.
    /// @param _operator Optional operator address (address(0) to disable).
    constructor(address _owner, address _operator) Ownable(_owner) {
        if (_owner == address(0)) revert ZeroAddress();
        operator = _operator;
    }

    // =============================================================
    //                       ADMIN FUNCTIONS
    // =============================================================

    /// @notice Sets the operator address. Only callable by the owner.
    /// @param _operator New operator address (address(0) to disable operator access).
    function setOperator(address _operator) external onlyOwner {
        address old = operator;
        operator = _operator;
        emit OperatorUpdated(old, _operator);
    }

    /// @notice Approves or revokes an adapter contract for use in price queries.
    /// @dev Unapproved adapters are silently skipped during price aggregation.
    /// @param adapter The adapter contract address.
    /// @param status True to approve, false to revoke.
    function approveAdapter(address adapter, bool status) external onlyOperatorOrOwner {
        if (status && (adapter == address(0) || adapter.code.length == 0)) {
            revert InvalidAdapter(adapter);
        }
        approvedAdapters[adapter] = status;
        emit AdapterApproved(adapter, status);
    }

    /// @notice Sets protocol-level oracle staleness thresholds.
    /// @dev Sources whose configured freshness exceeds these bounds are skipped at query time.
    ///      maxPythAge caps how stale a Pyth price can be. minTwapWindow floors how short a
    ///      TWAP window can be. Both must be > 0.
    /// @param _maxPythAge Maximum Pyth maxAge in seconds (ceiling). Must be in [1, 3600].
    /// @param _minTwapWindow Minimum TWAP window in seconds (floor). Must be in [1, 7200].
    function setStalenessParams(uint32 _maxPythAge, uint32 _minTwapWindow) external onlyOwner {
        if (_maxPythAge == 0 || _maxPythAge > 3600) revert InvalidStalenessParams();
        if (_minTwapWindow == 0 || _minTwapWindow > 7200) revert InvalidStalenessParams();
        maxPythAge = _maxPythAge;
        minTwapWindow = _minTwapWindow;
        emit StalenessParamsUpdated(_maxPythAge, _minTwapWindow);
    }

    // =============================================================
    //                        MAIN FUNCTIONS
    // =============================================================

    /// @notice Aggregates a normalized USDC price report from a set of typed oracle sources.
    /// @dev Individual adapter failures are soft-failed (skipped). WETH price failure is a
    ///      hard revert. The caller is responsible for checking validCount against minSources
    ///      and maxDeviationBps against the asset's configured threshold.
    ///
    ///      Pass an empty `wethSources` array when no source is TOKEN_WETH_POOL — WETH
    ///      fetching is skipped entirely in that case, avoiding unnecessary external calls.
    ///
    /// @param sources Array of oracle paths for the collateral token (from AssetManager).
    /// @param wethSources Array of DIRECT_USD oracle paths for WETH/USD pricing (from AssetManager).
    /// @return minPriceUsdc18 Minimum valid source price, USDC-denominated scaled to 1e18.
    /// @return maxPriceUsdc18 Maximum valid source price, USDC-denominated scaled to 1e18.
    /// @return maxDeviationBps Spread between min and max as a fraction of min, in BPS.
    /// @return validCount Number of sources that returned a valid, usable price.
    function getPriceReport(OraclePath[] calldata sources, OraclePath[] calldata wethSources)
        external
        view
        returns (
            uint256 minPriceUsdc18,
            uint256 maxPriceUsdc18,
            uint256 maxDeviationBps,
            uint8 validCount
        )
    {
        // Determine upfront whether any source needs WETH normalization
        bool needsWeth = _hasWethPoolSource(sources);

        // Fetch and aggregate WETH/USD price only when required
        uint256 wethPriceUsdc18;
        if (needsWeth) {
            wethPriceUsdc18 = _aggregateWethPrice(wethSources);
        }

        uint256 len = sources.length;
        for (uint256 i = 0; i < len; i++) {
            OraclePath calldata path = sources[i];

            // Skip unapproved adapters without reverting
            if (!approvedAdapters[path.adapter]) continue;

            // Skip sources whose staleness config exceeds protocol thresholds
            if (!_checkSourceFreshness(path)) continue;

            uint256 rawPrice;
            try IOracleAdapter(path.adapter).getPrice(path.data) returns (uint256 p) {
                if (p == 0) continue;
                rawPrice = p;
            } catch {
                continue;
            }

            uint256 priceUsdc18;
            if (path.sourceType == SourceType.TOKEN_WETH_POOL) {
                // wethPriceUsdc18 is guaranteed non-zero here (reverted above if unavailable)
                priceUsdc18 = rawPrice.mulDiv(wethPriceUsdc18, PRICE_SCALE);
                if (priceUsdc18 == 0) continue;
            } else {
                priceUsdc18 = rawPrice;
            }

            (minPriceUsdc18, maxPriceUsdc18, validCount) =
                _accumulatePrice(priceUsdc18, minPriceUsdc18, maxPriceUsdc18, validCount);
        }

        if (validCount > 1) {
            maxDeviationBps =
                (maxPriceUsdc18 - minPriceUsdc18).mulDiv(BPS_DENOMINATOR, minPriceUsdc18);
        }
    }

    /// @notice Converts a USDC18 price to native USDC 6-decimal representation.
    /// @dev Convenience helper for UI and off-chain formatting only.
    /// @param priceUsdc18 Price scaled to 1e18.
    /// @return Price scaled to 1e6 (native USDC decimals).
    function toUsdc6(uint256 priceUsdc18) external pure returns (uint256) {
        return priceUsdc18 / 1e12;
    }

    /// @notice Fetches a raw price directly from a single adapter without aggregation.
    /// @dev Useful for testing and diagnosing individual adapter configurations.
    /// @param adapter The adapter contract address.
    /// @param data ABI-encoded adapter call data.
    /// @return price The raw price returned by the adapter, scaled to 1e18.
    function getRawPrice(address adapter, bytes calldata data) external view returns (uint256 price) {
        return IOracleAdapter(adapter).getPrice(data);
    }

    // =============================================================
    //                      INTERNAL FUNCTIONS
    // =============================================================

    /// @dev Iterates wethSources with soft-fail per entry. Returns the minimum valid price
    ///      (conservative: lower WETH price → lower collateral valuation → protects lenders).
    ///      Reverts with WethPriceUnavailable if no source returns a valid price.
    function _aggregateWethPrice(OraclePath[] calldata wethSources) internal view returns (uint256) {
        uint256 minPrice;
        uint8 validCount;

        uint256 len = wethSources.length;
        for (uint256 i = 0; i < len; i++) {
            OraclePath calldata path = wethSources[i];

            if (!approvedAdapters[path.adapter]) continue;
            if (!_checkSourceFreshness(path)) continue;

            try IOracleAdapter(path.adapter).getPrice(path.data) returns (uint256 p) {
                if (p > 0) {
                    if (validCount == 0 || p < minPrice) {
                        minPrice = p;
                    }
                    validCount++;
                }
            } catch {}
        }

        if (validCount == 0) revert WethPriceUnavailable();

        return minPrice;
    }

    /// @dev Returns true if any source in the array has type TOKEN_WETH_POOL.
    function _hasWethPoolSource(OraclePath[] calldata sources) internal pure returns (bool) {
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].sourceType == SourceType.TOKEN_WETH_POOL) return true;
        }
        return false;
    }

    /// @dev Checks whether an oracle source's staleness configuration is within protocol bounds.
    ///      Returns false (skip this source) if the source is configured too permissively:
    ///      - DIRECT_USD: Pyth maxAge exceeds the protocol ceiling.
    ///      - TOKEN_USDC_POOL / TOKEN_WETH_POOL: TWAP window is below the protocol floor.
    ///      Sources with data too short to decode are passed through (non-standard adapters
    ///      handle their own validation).
    function _checkSourceFreshness(OraclePath calldata path) internal view returns (bool) {
        if (path.sourceType == SourceType.DIRECT_USD) {
            // Pyth data: abi.encode(bytes32 priceId, uint256 maxAge) = 64 bytes
            if (path.data.length < 64) return true;
            (, uint256 configuredMaxAge) = abi.decode(path.data, (bytes32, uint256));
            return configuredMaxAge <= maxPythAge;
        } else {
            // UniswapV3 / Algebra data: abi.encode(address pool, uint32 twapWindow, ...) = 128 bytes
            if (path.data.length < 128) return true;
            (, uint32 configuredWindow,,) = abi.decode(path.data, (address, uint32, address, address));
            return configuredWindow >= minTwapWindow;
        }
    }

    /// @dev Updates running min/max and increments count for a new valid price observation.
    function _accumulatePrice(uint256 price, uint256 currentMin, uint256 currentMax, uint8 currentCount)
        internal
        pure
        returns (uint256 newMin, uint256 newMax, uint8 newCount)
    {
        if (currentCount == 0) {
            return (price, price, 1);
        }

        newMin = price < currentMin ? price : currentMin;
        newMax = price > currentMax ? price : currentMax;
        newCount = currentCount + 1;
    }
}

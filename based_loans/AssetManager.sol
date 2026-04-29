// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IOracleAdapter.sol";

/// @notice Minimal interface for V3-compatible pools to increase observation cardinality.
interface IV3Pool {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @title BasedLoansAssetManager
/// @notice Manages asset configurations, oracle source paths, and risk parameters for Based Loans.
/// @dev An asset is considered configured if it has at least one oracle source. All view functions
///      revert if the asset is not configured.
///
///      Each asset has two source arrays:
///      - `sources`     — the oracle paths used to price the collateral token itself.
///      - `wethSources` — oracle paths used to fetch the WETH/USD price, required when any
///                        entry in `sources` is TOKEN_WETH_POOL. Must all be DIRECT_USD type.
///                        May be empty if no TOKEN_WETH_POOL sources are configured.
contract BasedLoansAssetManager is Ownable {
    // =============================================================
    // STRUCTS
    // =============================================================

    struct AssetConfig {
        OraclePath[] sources;
        OraclePath[] wethSources;
        uint256 maxDeviationBps;
        uint16 maxLtvBps;
        uint8 minSources;
        bool isActive;
        uint256 maxExposureUsdc; // Max total USDC in active loans against this asset (0 = unlimited)
    }

    // =============================================================
    // EVENTS
    // =============================================================

    event AssetConfigured(
        address indexed asset,
        uint256 sourceCount,
        uint256 wethSourceCount,
        uint256 maxDeviationBps,
        uint16 maxLtvBps,
        uint8 minSources,
        bool active
    );
    event AssetSourcesUpdated(address indexed asset, uint256 sourceCount);
    event AssetWethSourcesUpdated(address indexed asset, uint256 wethSourceCount);
    event AssetRiskParamsUpdated(address indexed asset, uint256 maxDeviationBps, uint16 maxLtvBps, uint8 minSources);
    event AssetStatusUpdated(address indexed asset, bool active);
    event AssetLtvUpdated(address indexed asset, uint16 maxLtvBps);
    event AssetRemoved(address indexed asset);
    event AssetExposureUpdated(address indexed asset, uint256 maxExposureUsdc);
    event OperatorUpdated(address oldOperator, address newOperator);

    // =============================================================
    // ERRORS
    // =============================================================

    error ZeroAddress();
    error InvalidContract(address target);
    error NoSourcesConfigured();
    error TooManySources(uint256 provided, uint256 maxAllowed);
    error InvalidDeviationBps(uint256 provided, uint256 maxAllowed);
    error InvalidLtv(uint16 provided, uint16 minAllowed, uint16 maxAllowed);
    error InvalidMinSources(uint8 provided, uint8 minAllowed, uint8 maxAllowed);
    error InvalidSource(uint256 index);
    error DuplicateSource(uint256 firstIndex, uint256 secondIndex);
    error AssetNotConfigured(address asset);
    error AssetInactive(address asset);
    error SourceIndexOutOfBounds(uint256 index, uint256 length);
    error WethSourcesRequired();
    error InvalidWethSourceType(uint256 index);
    error NotOperatorOrOwner();

    // =============================================================
    // IMMUTABLE GUARDRAILS (Hardcoded)
    // =============================================================

    uint256 public constant MAX_DEVIATION_BPS_CAP = 1000; // 10%
    uint8 public constant MIN_SOURCES_FLOOR = 1;
    uint8 public constant MAX_SOURCES_CAP = 5;

    uint16 public constant MIN_LTV_FLOOR = 2000;   // 20%
    uint16 public constant MAX_LTV_CEILING = 8500; // 85%

    // =============================================================
    // STORAGE
    // =============================================================

    /// @notice Optional operator address for emergency/agile functions.
    address public operator;

    mapping(address => AssetConfig) internal assetConfigs;

    // =============================================================
    // MODIFIERS
    // =============================================================

    modifier onlyOperatorOrOwner() {
        if (msg.sender != owner() && (operator == address(0) || msg.sender != operator)) {
            revert NotOperatorOrOwner();
        }
        _;
    }

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /// @notice Deploys the AssetManager.
    /// @param initialOwner Address that will own this contract.
    /// @param _operator Optional operator address (address(0) to disable).
    constructor(address initialOwner, address _operator) Ownable(initialOwner) {
        operator = _operator;
    }

    // =============================================================
    // ADMIN FUNCTIONS
    // =============================================================

    /// @notice Sets the operator address. Only callable by the owner.
    /// @param _operator New operator address (address(0) to disable operator access).
    function setOperator(address _operator) external onlyOwner {
        address old = operator;
        operator = _operator;
        emit OperatorUpdated(old, _operator);
    }

    /// @notice Creates or fully replaces the configuration for an asset.
    /// @dev If any entry in `sources` is TOKEN_WETH_POOL, `wethSources` must be non-empty.
    ///      All entries in `wethSources` must be DIRECT_USD type.
    /// @param asset The collateral asset address to configure.
    /// @param sources Oracle paths used to price the collateral token (1–5 entries).
    /// @param wethSources Oracle paths used to fetch WETH/USD price (0–5 entries, all DIRECT_USD).
    /// @param maxDeviationBps Maximum acceptable price deviation across sources in BPS.
    /// @param maxLtvBps Maximum principal LTV in basis points (2000–8500). Caps the USDC principal
    ///        that may be disbursed against collateral value. Does not cap the final buyback price,
    ///        which includes the fixed term premium and is disclosed upfront at loan open time.
    /// @param minSources Minimum number of valid oracle sources required for a price.
    /// @param active Whether the asset is immediately active for borrowing.
    function setAssetConfig(
        address asset,
        OraclePath[] calldata sources,
        OraclePath[] calldata wethSources,
        uint256 maxDeviationBps,
        uint16 maxLtvBps,
        uint8 minSources,
        bool active
    ) external onlyOperatorOrOwner {
        _validateAsset(asset);
        _validateSources(sources);
        _validateWethSources(wethSources);
        _requireWethSourcesIfNeeded(sources, wethSources);
        _validateRiskParams(maxDeviationBps, maxLtvBps, minSources, uint8(sources.length));

        AssetConfig storage cfg = assetConfigs[asset];

        delete cfg.sources;
        delete cfg.wethSources;

        for (uint256 i = 0; i < sources.length; i++) {
            cfg.sources.push(sources[i]);
        }
        for (uint256 i = 0; i < wethSources.length; i++) {
            cfg.wethSources.push(wethSources[i]);
        }

        _bootstrapTwapCardinality(sources);

        cfg.maxDeviationBps = maxDeviationBps;
        cfg.maxLtvBps = maxLtvBps;
        cfg.minSources = minSources;
        cfg.isActive = active;

        emit AssetConfigured(asset, sources.length, wethSources.length, maxDeviationBps, maxLtvBps, minSources, active);
    }

    /// @notice Replaces the oracle sources for an already-configured asset.
    /// @dev Cross-validates new sources against existing wethSources in storage.
    ///      If any new source is TOKEN_WETH_POOL, wethSources must already be configured.
    /// @param asset The collateral asset address to update.
    /// @param sources New oracle paths (1–5 entries).
    function setAssetSources(address asset, OraclePath[] calldata sources) external onlyOperatorOrOwner {
        _validateAsset(asset);

        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        _validateSources(sources);
        _validateRiskParams(cfg.maxDeviationBps, cfg.maxLtvBps, cfg.minSources, uint8(sources.length));

        // Cross-validate: if new sources need WETH, existing wethSources must cover it
        if (_hasWethPoolSource(sources) && cfg.wethSources.length == 0) {
            revert WethSourcesRequired();
        }

        delete cfg.sources;
        for (uint256 i = 0; i < sources.length; i++) {
            cfg.sources.push(sources[i]);
        }

        _bootstrapTwapCardinality(sources);

        emit AssetSourcesUpdated(asset, sources.length);
    }

    /// @notice Replaces the WETH/USD oracle sources for an already-configured asset.
    /// @dev All entries must be DIRECT_USD type. Cannot be set to empty if any asset source
    ///      is TOKEN_WETH_POOL, as that would leave WETH pricing without a source.
    /// @param asset The collateral asset address to update.
    /// @param wethSources New WETH/USD oracle paths (0–5 entries, all DIRECT_USD).
    function setAssetWethSources(address asset, OraclePath[] calldata wethSources) external onlyOperatorOrOwner {
        _validateAsset(asset);

        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        _validateWethSources(wethSources);

        // Cannot remove wethSources while TOKEN_WETH_POOL sources are still active
        if (wethSources.length == 0 && _hasWethPoolSourceStorage(cfg.sources)) {
            revert WethSourcesRequired();
        }

        delete cfg.wethSources;
        for (uint256 i = 0; i < wethSources.length; i++) {
            cfg.wethSources.push(wethSources[i]);
        }

        emit AssetWethSourcesUpdated(asset, wethSources.length);
    }

    /// @notice Updates the risk parameters for an already-configured asset.
    /// @param asset The collateral asset address to update.
    /// @param maxDeviationBps Maximum acceptable price deviation in BPS.
    /// @param maxLtvBps Maximum principal LTV in BPS (2000–8500). Caps disbursed principal only.
    /// @param minSources Minimum number of oracle sources required.
    function setAssetRiskParams(
        address asset,
        uint256 maxDeviationBps,
        uint16 maxLtvBps,
        uint8 minSources
    ) external onlyOwner {
        _validateAsset(asset);

        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        _validateRiskParams(maxDeviationBps, maxLtvBps, minSources, uint8(cfg.sources.length));

        cfg.maxDeviationBps = maxDeviationBps;
        cfg.maxLtvBps = maxLtvBps;
        cfg.minSources = minSources;

        emit AssetRiskParamsUpdated(asset, maxDeviationBps, maxLtvBps, minSources);
    }

    /// @notice Updates only the principal LTV for an already-configured asset.
    /// @param asset The collateral asset address to update.
    /// @param maxLtvBps New maximum principal LTV in BPS (2000–8500). Caps disbursed principal only.
    function setAssetLtv(address asset, uint16 maxLtvBps) external onlyOperatorOrOwner {
        _validateAsset(asset);

        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        if (maxLtvBps < MIN_LTV_FLOOR || maxLtvBps > MAX_LTV_CEILING) {
            revert InvalidLtv(maxLtvBps, MIN_LTV_FLOOR, MAX_LTV_CEILING);
        }

        cfg.maxLtvBps = maxLtvBps;
        emit AssetLtvUpdated(asset, maxLtvBps);
    }

    /// @notice Updates the maximum total USDC exposure for active loans against an asset.
    /// @param asset The collateral asset address.
    /// @param maxExposureUsdc Maximum USDC in active loans (0 = unlimited).
    function setAssetExposure(address asset, uint256 maxExposureUsdc) external onlyOperatorOrOwner {
        _validateAsset(asset);

        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        cfg.maxExposureUsdc = maxExposureUsdc;
        emit AssetExposureUpdated(asset, maxExposureUsdc);
    }

    /// @notice Activates or deactivates an asset for borrowing.
    /// @param asset The collateral asset address.
    /// @param active True to enable, false to disable.
    function setAssetStatus(address asset, bool active) external onlyOperatorOrOwner {
        _validateAsset(asset);

        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        cfg.isActive = active;

        emit AssetStatusUpdated(asset, active);
    }

    /// @notice Permanently removes an asset configuration.
    /// @param asset The collateral asset address to remove.
    function removeAsset(address asset) external onlyOwner {
        _validateAsset(asset);

        if (!_isConfiguredStorage(assetConfigs[asset])) revert AssetNotConfigured(asset);

        delete assetConfigs[asset];

        emit AssetRemoved(asset);
    }

    // =============================================================
    // VIEW FUNCTIONS
    // =============================================================

    /// @notice Returns the full configuration for an asset.
    /// @param asset The collateral asset address to query.
    /// @return cfg The full AssetConfig struct including both source arrays and risk params.
    function getAssetConfig(address asset) external view returns (AssetConfig memory cfg) {
        cfg = assetConfigs[asset];
        if (!_isConfiguredMemory(cfg)) revert AssetNotConfigured(asset);
    }

    /// @notice Returns the full configuration for an asset, reverting if it is inactive.
    /// @param asset The collateral asset address to query.
    /// @return cfg The full AssetConfig struct.
    function getActiveAssetConfig(address asset) external view returns (AssetConfig memory cfg) {
        cfg = assetConfigs[asset];
        if (!_isConfiguredMemory(cfg)) revert AssetNotConfigured(asset);
        if (!cfg.isActive) revert AssetInactive(asset);
    }

    /// @notice Returns all oracle paths and risk parameters needed to call OracleManager.
    /// @param asset The collateral asset address to query.
    /// @return sources Oracle paths for the collateral token.
    /// @return wethSources Oracle paths for WETH/USD pricing (empty if no TOKEN_WETH_POOL sources).
    /// @return maxDeviationBps Maximum acceptable price deviation in BPS.
    /// @return maxLtvBps Maximum loan-to-value ratio in BPS.
    /// @return minSources Minimum number of required valid oracle sources.
    /// @return active Whether the asset is currently active.
    /// @return maxExposureUsdc Maximum total USDC in active loans (0 = unlimited).
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
        )
    {
        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        sources = cfg.sources;
        wethSources = cfg.wethSources;
        maxDeviationBps = cfg.maxDeviationBps;
        maxLtvBps = cfg.maxLtvBps;
        minSources = cfg.minSources;
        active = cfg.isActive;
        maxExposureUsdc = cfg.maxExposureUsdc;
    }

    /// @notice Returns only the risk parameters for an asset.
    /// @param asset The collateral asset address to query.
    /// @return maxDeviationBps Maximum acceptable price deviation in BPS.
    /// @return maxLtvBps Maximum loan-to-value ratio in BPS.
    /// @return minSources Minimum number of required valid oracle sources.
    /// @return active Whether the asset is currently active.
    function getRiskParams(address asset)
        external
        view
        returns (uint256 maxDeviationBps, uint16 maxLtvBps, uint8 minSources, bool active)
    {
        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);

        maxDeviationBps = cfg.maxDeviationBps;
        maxLtvBps = cfg.maxLtvBps;
        minSources = cfg.minSources;
        active = cfg.isActive;
    }

    /// @notice Returns the number of oracle sources configured for an asset.
    /// @param asset The collateral asset address to query.
    /// @return The number of oracle sources.
    function getSourceCount(address asset) external view returns (uint256) {
        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);
        return cfg.sources.length;
    }

    /// @notice Returns the oracle path at a specific index for an asset.
    /// @param asset The collateral asset address to query.
    /// @param index Zero-based index into the sources array.
    /// @return adapter The adapter contract address.
    /// @return data The ABI-encoded adapter call data.
    /// @return sourceType How the returned price should be interpreted.
    function getSourceAt(address asset, uint256 index)
        external
        view
        returns (address adapter, bytes memory data, SourceType sourceType)
    {
        AssetConfig storage cfg = assetConfigs[asset];
        if (!_isConfiguredStorage(cfg)) revert AssetNotConfigured(asset);
        if (index >= cfg.sources.length) revert SourceIndexOutOfBounds(index, cfg.sources.length);

        OraclePath storage source = cfg.sources[index];
        adapter = source.adapter;
        data = source.data;
        sourceType = source.sourceType;
    }

    /// @notice Returns whether an asset has been configured.
    /// @param asset The collateral asset address to query.
    /// @return True if the asset has at least one oracle source configured.
    function isConfigured(address asset) external view returns (bool) {
        return _isConfiguredStorage(assetConfigs[asset]);
    }

    /// @notice Returns whether an asset is configured and currently active.
    /// @param asset The collateral asset address to query.
    /// @return True if the asset is configured and active.
    function isActive(address asset) external view returns (bool) {
        AssetConfig storage cfg = assetConfigs[asset];
        return _isConfiguredStorage(cfg) && cfg.isActive;
    }

    // =============================================================
    // INTERNAL FUNCTIONS
    // =============================================================

    /// @dev Reverts if the asset address is zero or not a contract.
    function _validateAsset(address asset) internal view {
        if (asset == address(0)) revert ZeroAddress();
        if (asset.code.length == 0) revert InvalidContract(asset);
    }

    /// @dev Validates length, adapter addresses, data presence, contract existence, and uniqueness.
    function _validateSources(OraclePath[] calldata sources) internal view {
        uint256 length = sources.length;

        if (length == 0) revert NoSourcesConfigured();
        if (length > MAX_SOURCES_CAP) revert TooManySources(length, MAX_SOURCES_CAP);

        for (uint256 i = 0; i < length; i++) {
            OraclePath calldata source = sources[i];

            if (source.adapter == address(0) || source.data.length == 0) {
                revert InvalidSource(i);
            }
            if (source.adapter.code.length == 0) {
                revert InvalidContract(source.adapter);
            }

            for (uint256 j = i + 1; j < length; j++) {
                if (
                    source.adapter == sources[j].adapter
                        && keccak256(source.data) == keccak256(sources[j].data)
                ) {
                    revert DuplicateSource(i, j);
                }
            }
        }
    }

    /// @dev Validates wethSources: may be empty; if non-empty, all entries must be DIRECT_USD.
    function _validateWethSources(OraclePath[] calldata wethSources) internal view {
        uint256 length = wethSources.length;

        if (length > MAX_SOURCES_CAP) revert TooManySources(length, MAX_SOURCES_CAP);

        for (uint256 i = 0; i < length; i++) {
            OraclePath calldata source = wethSources[i];

            if (source.adapter == address(0) || source.data.length == 0) {
                revert InvalidSource(i);
            }
            if (source.adapter.code.length == 0) {
                revert InvalidContract(source.adapter);
            }
            if (source.sourceType != SourceType.DIRECT_USD) {
                revert InvalidWethSourceType(i);
            }

            for (uint256 j = i + 1; j < length; j++) {
                if (
                    source.adapter == wethSources[j].adapter
                        && keccak256(source.data) == keccak256(wethSources[j].data)
                ) {
                    revert DuplicateSource(i, j);
                }
            }
        }
    }

    /// @dev Reverts if any source is TOKEN_WETH_POOL but no wethSources are provided.
    function _requireWethSourcesIfNeeded(
        OraclePath[] calldata sources,
        OraclePath[] calldata wethSources
    ) internal pure {
        if (wethSources.length > 0) return;

        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].sourceType == SourceType.TOKEN_WETH_POOL) {
                revert WethSourcesRequired();
            }
        }
    }

    /// @dev Validates deviation cap, LTV bounds, and minSources against sourceCount.
    function _validateRiskParams(
        uint256 maxDeviationBps,
        uint16 maxLtvBps,
        uint8 minSources,
        uint8 sourceCount
    ) internal pure {
        if (maxDeviationBps > MAX_DEVIATION_BPS_CAP) {
            revert InvalidDeviationBps(maxDeviationBps, MAX_DEVIATION_BPS_CAP);
        }
        if (maxLtvBps < MIN_LTV_FLOOR || maxLtvBps > MAX_LTV_CEILING) {
            revert InvalidLtv(maxLtvBps, MIN_LTV_FLOOR, MAX_LTV_CEILING);
        }
        if (minSources < MIN_SOURCES_FLOOR || minSources > sourceCount) {
            revert InvalidMinSources(minSources, MIN_SOURCES_FLOOR, sourceCount);
        }
    }

    /// @dev Returns true if any calldata source has type TOKEN_WETH_POOL.
    function _hasWethPoolSource(OraclePath[] calldata sources) internal pure returns (bool) {
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].sourceType == SourceType.TOKEN_WETH_POOL) return true;
        }
        return false;
    }

    /// @dev Returns true if any storage source has type TOKEN_WETH_POOL.
    function _hasWethPoolSourceStorage(OraclePath[] storage sources) internal view returns (bool) {
        for (uint256 i = 0; i < sources.length; i++) {
            if (sources[i].sourceType == SourceType.TOKEN_WETH_POOL) return true;
        }
        return false;
    }

    function _isConfiguredStorage(AssetConfig storage cfg) internal view returns (bool) {
        return cfg.sources.length > 0;
    }

    function _isConfiguredMemory(AssetConfig memory cfg) internal pure returns (bool) {
        return cfg.sources.length > 0;
    }

    /// @dev For any TWAP pool source (TOKEN_USDC_POOL or TOKEN_WETH_POOL), requests the pool
    ///      to increase its observation cardinality to at least 2000. This ensures reliable
    ///      30-minute TWAP windows even on low-activity pools (2000 obs × 2s blocks = 66 min).
    ///      Uses try/catch so it is a no-op if the pool already has sufficient cardinality or
    ///      does not support the call. Also bootstraps the two-hop pool if present in the data.
    ///      Silently skips sources whose data is too short to contain a pool address.
    function _bootstrapTwapCardinality(OraclePath[] calldata sources) internal {
        for (uint256 i = 0; i < sources.length; i++) {
            SourceType st = sources[i].sourceType;
            if (st == SourceType.TOKEN_USDC_POOL || st == SourceType.TOKEN_WETH_POOL) {
                bytes calldata d = sources[i].data;
                // Standard encoding: abi.encode(address pool, uint32 twapWindow, address baseToken, address quoteToken)
                // = 4 × 32 = 128 bytes minimum. Skip if data is too short to decode.
                if (d.length < 128) continue;
                address pool = abi.decode(d[:32], (address));
                try IV3Pool(pool).increaseObservationCardinalityNext(2000) {} catch {}
                // Two-hop: if 7-param encoding, also bootstrap the hop pool (param 6, offset 160)
                if (d.length >= 224) {
                    address hopPool = abi.decode(d[160:192], (address));
                    if (hopPool != address(0)) {
                        try IV3Pool(hopPool).increaseObservationCardinalityNext(2000) {} catch {}
                    }
                }
            }
        }
    }
}

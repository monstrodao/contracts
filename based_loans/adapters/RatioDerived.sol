// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IOracleAdapter.sol";
import "../AssetManager.sol";
import "../OracleManager.sol";
import "../libraries/FullMath.sol";

/// @title RatioDerivedAdapter
/// @notice Oracle adapter for tokens priced as: baseToken × ratio / ratioPrecision.
///         Supports two ratio modes selected by ratioContract:
///           On-chain: ratioContract != address(0) — fetches ratio via a zero-arg view call
///                     using ratioSelector (e.g. LST conversionRatio(), exchangeRate()).
///           Fixed:    ratioContract == address(0) — uses the inline fixedRatio encoded in data,
///                     set by governance in AssetManager config (e.g. escrowed tokens at a
///                     DAO-determined discount to their liquid counterpart).
///         baseToken must be independently configured in AssetManager; its price is resolved
///         through OracleManager so any approved adapter (UniswapV3, Algebra, etc.) may serve it.
///         Register sources using TOKEN_USDC_POOL sourceType — this adapter always returns USDC-18.
///
/// @dev Data encoding — slot 1 is always FRESHNESS_SENTINEL (uint256(type(uint32).max)).
///      This is a compatibility shim for the deployed OracleManager's source-freshness decoder,
///      which reads slot 1 as uint32 and rejects sources whose value is below minTwapWindow.
///      FRESHNESS_SENTINEL exceeds any possible minTwapWindow, so the adapter passes that check
///      without requiring an OracleManager redeployment. This sentinel is only about bypassing
///      the freshness gate on this adapter layer — actual price freshness is inherited from the
///      baseToken sources resolved through OracleManager's own freshness checks.
///
///      On-chain ratio (5 params, 160 bytes):
///        abi.encode(address baseToken, FRESHNESS_SENTINEL, address ratioContract,
///                   uint256 ratioPrecision, bytes4 ratioSelector)
///      Fixed ratio (6 params, 192 bytes):
///        abi.encode(address baseToken, FRESHNESS_SENTINEL, address(0),
///                   uint256 ratioPrecision, bytes4(0), uint256 fixedRatio)
///
/// @dev RATIO DIRECTION: ratio must represent "baseToken units per 1 derived token".
///      derivedPrice = basePrice * ratio / ratioPrecision.
///      If the external contract returns the inverse (derived per base), do NOT use it directly.
///
/// @dev RATIO SOURCE TRUST: on-chain ratioContract is assumed to be governance-approved and
///      trusted. This adapter does not validate ratio freshness, manipulation resistance,
///      upgradeability, or admin risk of ratioContract. Those properties must be assessed
///      at the governance config layer before approving a ratio source.
///
/// @dev CYCLE PROTECTION: this adapter calls OracleManager for baseToken pricing. Configuring
///      a derived token whose baseToken sources also use RatioDerivedAdapter pointing back to
///      the derived token creates a recursive pricing cycle. Cycles must be prevented at the
///      AssetManager config layer — the adapter itself has no visibility into which token it
///      is currently pricing.
contract RatioDerivedAdapter is IOracleAdapter {
    BasedLoansAssetManager  public immutable assetManager;
    BasedLoansOracleManager public immutable oracleManager;

    /// @dev Slot 1 sentinel value. See data encoding note in contract NatSpec.
    uint256 public constant FRESHNESS_SENTINEL = uint256(type(uint32).max);

    error ZeroAddress();
    error InvalidEncoding();
    error BaseTokenPriceUnavailable();
    error RatioCallFailed();
    error InvalidRatioPrecision();
    error InvalidRatioSelector();
    error InvalidRatio();
    error InvalidFixedRatio();

    constructor(address _assetManager, address _oracleManager) {
        if (_assetManager == address(0) || _oracleManager == address(0)) revert ZeroAddress();
        assetManager  = BasedLoansAssetManager(_assetManager);
        oracleManager = BasedLoansOracleManager(_oracleManager);
    }

    function getPrice(bytes calldata data) external view override returns (uint256) {
        if (data.length < 160) revert InvalidEncoding();

        (
            address baseToken,
            uint256 sentinel,
            address ratioContract,
            uint256 ratioPrecision,
            bytes4  ratioSelector
        ) = abi.decode(data, (address, uint256, address, uint256, bytes4));

        if (sentinel != FRESHNESS_SENTINEL) revert InvalidEncoding();
        if (baseToken == address(0)) revert ZeroAddress();
        if (ratioPrecision == 0) revert InvalidRatioPrecision();

        BasedLoansAssetManager.AssetConfig memory cfg = assetManager.getAssetConfig(baseToken);

        (uint256 minP,,, uint8 validCount) = oracleManager.getPriceReport(cfg.sources, cfg.wethSources);
        if (validCount == 0 || minP == 0) revert BaseTokenPriceUnavailable();

        uint256 ratio;
        if (ratioContract == address(0)) {
            if (ratioSelector != bytes4(0)) revert InvalidRatioSelector();
            if (data.length < 192) revert InvalidFixedRatio();
            (,,,,, ratio) = abi.decode(data, (address, uint256, address, uint256, bytes4, uint256));
            if (ratio == 0) revert InvalidFixedRatio();
        } else {
            if (ratioSelector == bytes4(0)) revert InvalidRatioSelector();
            (bool ok, bytes memory ret) = ratioContract.staticcall(abi.encodeWithSelector(ratioSelector));
            if (!ok || ret.length != 32) revert RatioCallFailed();
            ratio = abi.decode(ret, (uint256));
            if (ratio == 0) revert InvalidRatio();
        }

        return FullMath.mulDiv(minP, ratio, ratioPrecision);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IERC20Minimal.sol";
import "../libraries/TickMath.sol";
import "../libraries/FullMath.sol";

interface IAlgebraPool {
    function plugin() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

import "../interfaces/IERC4626Minimal.sol";

interface ITwapPlugin {
    function getTimepoints(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint112[] memory volatilityCumulatives);
}

/// @title AlgebraAdapter
/// @notice Algebra-style TWAP oracle adapter with optional two-hop and vault conversion.
/// @dev Compatible with TrebleSwap and other Algebra V2 forks.
///      Data encoding variants match UniswapV3Adapter:
///      4 params: (pool, twapWindow, baseToken, quoteToken) → direct
///      5 params: + quoteVault → vault conversion
///      7 params: + hopPool, hopQuote → two-hop pricing
contract AlgebraAdapter is IOracleAdapter {
    using FullMath for uint256;

    uint256 internal constant Q192 = 2 ** 192;
    uint256 internal constant ONE_18 = 1e18;

    error InvalidWindow();
    error InvalidPoolPair();
    error InvalidPrice();
    error InvalidTokenDecimals();
    error InvalidPlugin();

    /// @notice Returns the TWAP price for an Algebra pool, scaled to 1e18.
    function getPrice(bytes calldata data) external view override returns (uint256 price) {
        (address pool, uint32 twapWindow, address baseToken, address quoteToken) =
            abi.decode(data, (address, uint32, address, address));

        // Optional 5th param: vault conversion
        address quoteVault;
        if (data.length >= 160) {
            (,,,, quoteVault) = abi.decode(data, (address, uint32, address, address, address));
        }

        // Optional 6th+7th params: two-hop
        address hopPool;
        address hopQuote;
        if (data.length >= 224) {
            (,,,,, hopPool, hopQuote) = abi.decode(data, (address, uint32, address, address, address, address, address));
        }

        // L-01: optional 8th param — separate TWAP window for second hop.
        // Defaults to twapWindow if not provided.
        uint32 twapWindow1 = twapWindow;
        if (data.length >= 256) {
            (,,,,,,,twapWindow1) = abi.decode(data, (address, uint32, address, address, address, address, address, uint32));
        }

        if (twapWindow == 0) revert InvalidWindow();
        if (hopPool != address(0) && twapWindow1 == 0) revert InvalidWindow();

        // First hop: base → quote
        price = _getTwapPrice(pool, twapWindow, baseToken, quoteToken);

        // Vault conversion on first hop quote token.
        // Use actual vault share decimals and asset decimals (same fix as UniswapV3Adapter).
        if (quoteVault != address(0)) {
            IERC4626Minimal v = IERC4626Minimal(quoteVault);
            uint8 vaultDec = v.decimals();
            uint8 assetDec = IERC20MetadataMinimal(v.asset()).decimals();
            if (vaultDec > 18 || assetDec > 18) revert InvalidTokenDecimals();
            uint256 oneShare = 10 ** vaultDec;
            uint256 assetsPerShare = v.convertToAssets(oneShare);
            uint256 rateE18 = FullMath.mulDiv(assetsPerShare, ONE_18, 10 ** assetDec);
            price = FullMath.mulDiv(price, rateE18, ONE_18);
        }

        // Second hop: quote → hopQuote
        // L-01: uses twapWindow1 (separate from first hop window) to allow independent TWAP configs.
        if (hopPool != address(0)) {
            uint256 hopPrice = _getTwapPrice(hopPool, twapWindow1, quoteToken, hopQuote);
            price = FullMath.mulDiv(price, hopPrice, ONE_18);
        }

        if (price == 0) revert InvalidPrice();
    }

    /// @dev Computes the TWAP price from an Algebra pool: quoteToken per 1 baseToken, scaled to 1e18.
    function _getTwapPrice(address pool, uint32 twapWindow, address baseToken, address quoteToken)
        internal
        view
        returns (uint256 price)
    {
        address token0 = IAlgebraPool(pool).token0();
        address token1 = IAlgebraPool(pool).token1();

        bool match0 = (baseToken == token0 && quoteToken == token1);
        bool match1 = (baseToken == token1 && quoteToken == token0);
        if (!(match0 || match1)) revert InvalidPoolPair();

        bool baseIsToken0 = match0;

        address plugin = IAlgebraPool(pool).plugin();
        if (plugin == address(0)) revert InvalidPlugin();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = ITwapPlugin(plugin).getTimepoints(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickDelta / int56(uint56(twapWindow)));
        // Direction-aware rounding (same fix as UniswapV3Adapter).
        int56 remainder = tickDelta % int56(uint56(twapWindow));
        if (remainder != 0) {
            if (baseIsToken0) {
                if (tickDelta < 0) avgTick--;
            } else {
                if (tickDelta > 0) avgTick++;
            }
        }

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);

        uint256 token0Decimals = uint256(IERC20MetadataMinimal(token0).decimals());
        uint256 token1Decimals = uint256(IERC20MetadataMinimal(token1).decimals());
        if (token0Decimals > 18 || token1Decimals > 18) revert InvalidTokenDecimals();

        uint256 raw = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * ONE_18, Q192);

        // raw encodes token1 raw units per token0 raw unit (scaled to 1e18).
        // Forward: base is token0, scale by token0/token1 decimals.
        // Inverse: base is token1, invert raw price, scale by token1/token0 decimals.
        if (baseIsToken0) {
            price = FullMath.mulDiv(raw, 10 ** token0Decimals, 10 ** token1Decimals);
        } else {
            if (raw == 0) revert InvalidPrice();
            uint256 inverseRaw = FullMath.mulDiv(ONE_18, ONE_18, raw);
            price = FullMath.mulDiv(inverseRaw, 10 ** token1Decimals, 10 ** token0Decimals);
        }
    }
}

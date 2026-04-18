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

        if (twapWindow == 0) revert InvalidWindow();

        // First hop: base → quote
        price = _getTwapPrice(pool, twapWindow, baseToken, quoteToken);

        // Vault conversion on first hop quote token
        if (quoteVault != address(0)) {
            uint256 rate = IERC4626Minimal(quoteVault).convertToAssets(ONE_18);
            price = FullMath.mulDiv(price, rate, ONE_18);
        }

        // Second hop: quote → hopQuote
        if (hopPool != address(0)) {
            uint256 hopPrice = _getTwapPrice(hopPool, twapWindow, quoteToken, hopQuote);
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
        if (tickDelta < 0 && (tickDelta % int56(uint56(twapWindow)) != 0)) avgTick--;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);

        uint8 baseDecimals = IERC20MetadataMinimal(baseToken).decimals();
        uint8 quoteDecimals = IERC20MetadataMinimal(quoteToken).decimals();
        if (baseDecimals > 18 || quoteDecimals > 18) revert InvalidTokenDecimals();

        uint256 raw = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * ONE_18, Q192);

        if (baseIsToken0) {
            price = FullMath.mulDiv(raw, 10 ** uint256(baseDecimals), 10 ** uint256(quoteDecimals));
        } else {
            if (raw == 0) revert InvalidPrice();
            raw = FullMath.mulDiv(ONE_18, ONE_18, raw);
            price = FullMath.mulDiv(raw, 10 ** uint256(baseDecimals), 10 ** uint256(quoteDecimals));
        }
    }
}

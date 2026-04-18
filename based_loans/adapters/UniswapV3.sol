// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IERC20Minimal.sol";
import "../libraries/FullMath.sol";
import "../libraries/TickMath.sol";

interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

import "../interfaces/IERC4626Minimal.sol";

/// @title UniswapV3Adapter
/// @notice Universal Uniswap V3 TWAP oracle adapter with optional two-hop and vault conversion.
/// @dev Data encoding variants:
///      4 params: abi.encode(pool, twapWindow, baseToken, quoteToken)
///         → Direct TWAP price (e.g. TOKEN/USDC pool)
///      5 params: abi.encode(pool, twapWindow, baseToken, quoteToken, quoteVault)
///         → TWAP price × vault exchange rate (e.g. TOKEN/mUSDC pool, converts to USDC)
///      7 params: abi.encode(pool, twapWindow, baseToken, quoteToken, quoteVault, hopPool, hopQuote)
///         → Two-hop: TWAP from pool1 (base/intermediate), then TWAP from pool2 (intermediate/hopQuote)
///         → Result is price in hopQuote token (e.g. WETH). Use TOKEN_WETH_POOL source type for USD conversion.
///         → quoteVault can still be set for vault conversion on the first hop.
contract UniswapV3Adapter is IOracleAdapter {
    uint256 internal constant Q192 = 1 << 192;
    uint256 internal constant ONE_18 = 1e18;

    error InvalidWindow();
    error InvalidPoolPair();
    error InvalidPrice();
    error InvalidDecimals();

    /// @notice Returns the TWAP price for a Uniswap V3 pool, scaled to 1e18.
    function getPrice(bytes calldata data) external view override returns (uint256 price) {
        (address pool, uint32 twapWindow, address baseToken, address quoteToken) =
            abi.decode(data, (address, uint32, address, address));

        // Optional 5th param: vault address for quote token conversion (e.g. mUSDC → USDC)
        address quoteVault;
        if (data.length >= 160) {
            (,,,, quoteVault) = abi.decode(data, (address, uint32, address, address, address));
        }

        // Optional 6th+7th params: second pool for two-hop pricing (e.g. PLAZM/ESHARE → ESHARE/WETH)
        address hopPool;
        address hopQuote;
        if (data.length >= 224) {
            (,,,,, hopPool, hopQuote) = abi.decode(data, (address, uint32, address, address, address, address, address));
        }

        if (twapWindow == 0) revert InvalidWindow();

        // First hop: base → quote (e.g. PLAZM → ESHARE)
        price = _getTwapPrice(pool, twapWindow, baseToken, quoteToken);

        // Vault conversion on first hop quote token (e.g. mUSDC → USDC)
        if (quoteVault != address(0)) {
            uint256 rate = IERC4626Minimal(quoteVault).convertToAssets(ONE_18);
            price = FullMath.mulDiv(price, rate, ONE_18);
        }

        // Second hop: quote → hopQuote (e.g. ESHARE → WETH)
        if (hopPool != address(0)) {
            uint256 hopPrice = _getTwapPrice(hopPool, twapWindow, quoteToken, hopQuote);
            price = FullMath.mulDiv(price, hopPrice, ONE_18);
        }

        if (price == 0) revert InvalidPrice();
    }

    /// @dev Computes the TWAP price from a V3 pool: quoteToken per 1 baseToken, scaled to 1e18.
    function _getTwapPrice(address pool, uint32 twapWindow, address baseToken, address quoteToken)
        internal
        view
        returns (uint256 price)
    {
        address t0 = IUniswapV3Pool(pool).token0();
        address t1 = IUniswapV3Pool(pool).token1();

        bool baseIsT0;
        if (baseToken == t0 && quoteToken == t1) {
            baseIsT0 = true;
        } else if (baseToken == t1 && quoteToken == t0) {
            baseIsT0 = false;
        } else {
            revert InvalidPoolPair();
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickDelta / int56(uint56(twapWindow)));
        if (tickDelta < 0 && (tickDelta % int56(uint56(twapWindow)) != 0)) avgTick--;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);

        uint256 baseDec = uint256(IERC20MetadataMinimal(baseToken).decimals());
        uint256 quoteDec = uint256(IERC20MetadataMinimal(quoteToken).decimals());
        if (baseDec > 18 || quoteDec > 18) revert InvalidDecimals();

        uint256 rawP18 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * ONE_18, Q192);

        if (baseIsT0) {
            price = rawP18;
        } else {
            if (rawP18 == 0) revert InvalidPrice();
            price = FullMath.mulDiv(ONE_18, ONE_18, rawP18);
        }

        if (quoteDec >= baseDec) {
            price = price / (10 ** (quoteDec - baseDec));
        } else {
            price = price * (10 ** (baseDec - quoteDec));
        }
    }
}

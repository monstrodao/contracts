// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Classifies how an oracle source's raw price should be interpreted.
/// @dev DIRECT_USD  — adapter returns a USD price directly (Pyth, Chainlink, RedStone, DIA).
///      TOKEN_USDC_POOL — adapter returns a token/USDC DEX TWAP; already USDC-denominated.
///      TOKEN_WETH_POOL — adapter returns a token/WETH DEX TWAP; requires WETH/USD normalization.
enum SourceType {
    DIRECT_USD,
    TOKEN_USDC_POOL,
    TOKEN_WETH_POOL
}

/// @notice A single oracle source: the adapter to call, its encoded parameters, and how to interpret the result.
struct OraclePath {
    address adapter;
    bytes data;
    SourceType sourceType;
}

/// @title IOracleAdapter
/// @notice Interface that all Based Loans oracle adapters must implement.
interface IOracleAdapter {
    /// @notice Returns the current price for the asset encoded in `data`, scaled to 1e18.
    /// @dev The encoding of `data` is adapter-specific. See each adapter's implementation
    ///      for the expected abi.encode() format.
    /// @param data ABI-encoded adapter parameters (pool address, price feed ID, TWAP window, etc.).
    /// @return price Asset price in 1e18 fixed-point (interpretation depends on SourceType).
    function getPrice(bytes calldata data) external view returns (uint256 price);
}

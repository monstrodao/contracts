// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IOracleAdapter.sol";

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
}

/// @title PythAdapter
/// @notice Oracle adapter that fetches asset prices from the Pyth network.
/// @dev Returns prices normalized to 1e18. The Pyth exponent is typically negative,
///      so the scaling is: price * 10^(18 + expo).
contract PythAdapter is IOracleAdapter {
    IPyth public immutable pyth;

    error InvalidPrice();

    /// @notice Deploys the adapter pointing at a Pyth contract.
    /// @param _pyth Address of the Pyth oracle contract.
    constructor(address _pyth) {
        pyth = IPyth(_pyth);
    }

    /// @notice Returns the Pyth price for the asset encoded in `data`, scaled to 1e18.
    /// @dev data encoding: abi.encode(bytes32 priceId, uint256 maxAge)
    ///      Pyth expo is typically negative (e.g. -8). Handles both positive and negative
    ///      exponents safely without risking underflow or overflow on the exponent cast.
    /// @param data ABI-encoded (priceId, maxAge).
    /// @return Price in 1e18 fixed-point representation.
    function getPrice(bytes calldata data) external view override returns (uint256) {
        (bytes32 priceId, uint256 maxAge) = abi.decode(data, (bytes32, uint256));

        IPyth.Price memory p = pyth.getPriceNoOlderThan(priceId, maxAge);

        if (p.price <= 0) revert InvalidPrice();

        uint256 price = uint256(uint64(p.price));

        if (p.expo < 0) {
            uint256 factor = 10 ** uint256(uint32(-p.expo));
            return price * 1e18 / factor;
        } else {
            uint256 factor = 10 ** uint256(uint32(p.expo));
            return price * factor * 1e18;
        }
    }
}

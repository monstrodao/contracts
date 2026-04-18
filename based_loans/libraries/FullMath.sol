// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FullMath
/// @notice Overflow-safe multiplication and division for uint256.
/// @dev Ported from Uniswap V3. Uses assembly to compute a * b as a 512-bit integer
///      before dividing, avoiding intermediate overflow.
library FullMath {
    error DivisionByZero();
    error Overflow();

    /// @notice Computes floor(a × b ÷ denominator) with full 512-bit precision.
    /// @dev Reverts on division by zero or if the result overflows uint256.
    /// @param a Multiplicand.
    /// @param b Multiplier.
    /// @param denominator Divisor. Must be greater than zero and greater than the high bits of a × b.
    /// @return result floor(a × b ÷ denominator).
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                if (denominator == 0) revert DivisionByZero();
                return prod0 / denominator;
            }
            if (denominator <= prod1) revert Overflow();
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            result = prod0 * inv;
        }
    }
}

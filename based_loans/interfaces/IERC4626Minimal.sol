// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC4626Minimal {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

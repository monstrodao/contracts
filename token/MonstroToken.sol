// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MonstroToken (MONSTRO)
 * @dev Security-optimized ERC20 token with fixed supply and burn functionality.
 * 
 * Security Features:
 * - Fixed supply (400M tokens, no mint function)
 * - Burnable (reduces total supply)
 * - Permit support (EIP-2612 for gasless approvals)
 * - No transfer restrictions
 * - No blacklist functionality
 * - No fees or taxes
 * - Ownership renounced at deployment
 * - No admin functions
 * - Standard ERC20 compliance
 */
contract MonstroToken is ERC20, ERC20Burnable, ERC20Permit, Ownable {
    
    // Fixed supply - set at deployment, cannot be increased
    uint256 public constant INITIAL_SUPPLY = 400_000_000 * 10**18; // 400M tokens
    
    /**
     * @dev Constructor mints total supply and renounces ownership
     * @param _initialOwner Address to receive all tokens (typically deployer)
     */
    constructor(address _initialOwner) 
        ERC20("Monstro DeFi", "MONSTRO") 
        ERC20Permit("Monstro DeFi")
        Ownable(_initialOwner) 
    {
        require(_initialOwner != address(0), "Initial owner cannot be zero address");
        
        // Mint entire supply to initial owner
        _mint(_initialOwner, INITIAL_SUPPLY);
        
        // Renounce ownership for full trustlessness
        _transferOwnership(address(0));
    }
    
    /**
     * @dev Returns amount of tokens burned
     */
    function totalBurned() external view returns (uint256 burned) {
        burned = INITIAL_SUPPLY - totalSupply();
    }
}

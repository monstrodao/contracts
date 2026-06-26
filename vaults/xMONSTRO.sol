// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal interface for MONSTRO's burn function.
interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title xMONSTRO
/// @notice Bonding-curve vault token backed by MONSTRO. Each mint costs BASE_PRICE +
///         supply * PRICE_STEP MONSTRO. 75% of every mint cost is permanently burned via
///         MONSTRO's burn() function; 25% enters the vault. Holders redeem 1 xMONSTRO for
///         their pro-rata vault share minus a 10% fee that stays in the vault, growing the
///         rate for remaining holders. The final xMONSTRO holder pays no redeem fee and
///         receives the full vault balance. Anyone may add MONSTRO to the vault by sending it directly.
/// @dev Not upgradeable and fully permissionless: no owner, no admin, no operator, no roles. All
///      parameters are immutable constants. The vault's MONSTRO is read LIVE via MONSTRO.balanceOf(address(this)) —
///      there is no internal balance counter — so any MONSTRO in the contract (a mint's retained 25%
///      or a direct transfer/donation) counts toward the redemption rate. Minimal surface by design.
/// @dev MONSTRO must be a standard ERC20 with a burn(uint256) function: no fee-on-transfer,
///      no rebasing, no transfer hooks, no blocklist.
/// @dev mint() and mintBatch() call MONSTRO.burn() and revert if it reverts. MONSTRO is
///      non-upgradeable and non-pausable with a permissionless burn().
contract xMONSTRO is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Immutables ---

    /// @notice The MONSTRO token (18 decimals).
    IERC20 public immutable MONSTRO;

    // --- Constants ---

    /// @notice Cost of the first xMONSTRO: 10,000 MONSTRO.
    uint256 public constant BASE_PRICE = 10_000e18;

    /// @notice Price increase per mint (and decrease per redeem): 1,000 MONSTRO.
    uint256 public constant PRICE_STEP = 1_000e18;

    /// @notice Fraction of each mint cost permanently burned via MONSTRO.burn(): 75%.
    uint256 public constant BURN_BPS = 7_500;

    /// @notice Fraction of each redemption gross kept in vault as fee: 10%.
    ///         Not applied to the final holder (supply == 1 at redeem time).
    uint256 public constant REDEEM_FEE_BPS = 1_000;

    /// @notice Maximum xMONSTRO mintable in a single mintBatch call.
    /// @dev Total xMONSTRO ever mintable is bounded near 894: MONSTRO supply is capped at 400M
    ///      and only deflates, so the cumulative bonding-curve cost exhausts the supply at that
    ///      point. The cap limits how far a single transaction can advance the curve.
    uint256 public constant MAX_BATCH = 100;

    uint256 private constant BPS = 10_000;

    // --- Errors ---

    error ZeroSupply();
    /// @dev Reverted when the pro-rata vault share rounds to zero.
    error ZeroPayout();
    error SlippageExceeded();
    error ZeroAmount();
    error ZeroAddress();
    error BatchTooLarge();

    // --- Events ---

    event MintedBatch(address indexed minter, uint256 amount, uint256 totalCost, uint256 burned, uint256 vaulted);
    event RedeemedBatch(address indexed redeemer, uint256 amount, uint256 totalPayout);
    event PresaleMinted(address indexed recipient, uint256 amount);

    // --- Constructor ---

    /// @param _monstro Address of the MONSTRO token (must be non-zero).
    /// @param _preMintAmount xMONSTRO to pre-mint at deploy for the community pre-sale (0 to skip).
    ///        Advances the bonding curve so the first public mint costs BASE_PRICE + _preMintAmount * PRICE_STEP,
    ///        reserving the cheap early slots for pre-sale participants instead of snipers.
    /// @param _presaleRecipient Recipient of the pre-minted xMONSTRO (required non-zero if _preMintAmount > 0);
    ///        typically the Labs/DAO wallet that distributes to pre-sale participants.
    /// @dev No MONSTRO is collected or burned on-chain for the pre-mint. The pre-sale MONSTRO is handled
    ///      OFF-CHAIN: burn 75% via MONSTRO.burn() and transfer the remaining 25% directly to this contract
    ///      (counted live via balanceOf). Send that matching 25% BEFORE distributing the pre-minted tokens,
    ///      so holders can redeem at the correct rate.
    constructor(address _monstro, uint256 _preMintAmount, address _presaleRecipient)
        ERC20("xMONSTRO", "xMONSTRO")
    {
        if (_monstro == address(0)) revert ZeroAddress();
        MONSTRO = IERC20(_monstro);

        if (_preMintAmount > 0) {
            if (_presaleRecipient == address(0)) revert ZeroAddress();
            _mint(_presaleRecipient, _preMintAmount);
            emit PresaleMinted(_presaleRecipient, _preMintAmount);
        }
    }

    // --- ERC20 override ---

    /// @notice xMONSTRO is a whole-unit token; decimals is 0.
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    // --- View ---

    /// @notice MONSTRO cost to mint the next xMONSTRO.
    /// @dev Rises by PRICE_STEP with each mint; falls by PRICE_STEP after each redeem.
    /// @return MONSTRO cost (18 decimals) of the next mint.
    function mintCost() public view returns (uint256) {
        return BASE_PRICE + totalSupply() * PRICE_STEP;
    }

    /// @notice Vault MONSTRO per xMONSTRO (gross, before redeem fee).
    /// @return Vault MONSTRO (18 decimals) per xMONSTRO, before redeem fee. 0 when supply is 0.
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return MONSTRO.balanceOf(address(this)) / supply;
    }

    /// @notice MONSTRO a holder receives for redeeming 1 xMONSTRO.
    ///         Returns the full vault share when the caller would be the last holder (supply == 1).
    /// @return MONSTRO (18 decimals) paid for redeeming 1 xMONSTRO. 0 when supply is 0.
    function redeemPayout() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 gross = MONSTRO.balanceOf(address(this)) / supply;
        if (supply == 1) return gross;
        return gross - gross * REDEEM_FEE_BPS / BPS;
    }

    // --- Actions ---

    /// @notice Mint `amount` xMONSTRO in one transaction. Total cost is the arithmetic
    ///         series of individual mint prices from current supply to supply + amount - 1.
    ///         Same burn/vault split as single mint. Total cost is computed from totalSupply()
    ///         at execution time; the maxTotalCost guard reverts if it exceeds the limit.
    /// @param amount Number of xMONSTRO to mint (must be > 0).
    /// @param maxTotalCost Revert if total cost exceeds this value (slippage guard).
    /// @return totalCost Total MONSTRO paid by caller.
    function mintBatch(uint256 amount, uint256 maxTotalCost) external nonReentrant returns (uint256 totalCost) {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_BATCH) revert BatchTooLarge();

        uint256 supply = totalSupply();
        // Arithmetic series: sum of (BASE + (supply+i)*STEP) for i in [0, amount)
        totalCost = amount * BASE_PRICE + PRICE_STEP * (amount * supply + amount * (amount - 1) / 2);
        if (totalCost > maxTotalCost) revert SlippageExceeded();

        uint256 toBurn  = totalCost * BURN_BPS / BPS;
        uint256 toVault = totalCost - toBurn; // 25%, left live in the contract as vault backing

        // CEI: mint shares (state) before external calls; the 25% remains as live MONSTRO balance.
        _mint(msg.sender, amount);

        MONSTRO.safeTransferFrom(msg.sender, address(this), totalCost);
        IBurnable(address(MONSTRO)).burn(toBurn);

        emit MintedBatch(msg.sender, amount, totalCost, toBurn, toVault);
    }

    /// @notice Redeem `amount` xMONSTRO in one transaction for the cumulative MONSTRO payout.
    ///         Economically identical to calling redeem() `amount` times in a row: the rate falls as
    ///         each unit is redeemed, and the per-unit 10% fee applies — except a unit that brings the
    ///         GLOBAL supply to its last token is fee-free and sweeps the remaining vault. Settles in a
    ///         single transfer (symmetric with mintBatch's single transferFrom).
    /// @param amount Number of xMONSTRO to redeem (> 0, <= MAX_BATCH, <= totalSupply()).
    /// @param minTotalPayout Revert if the cumulative payout < minTotalPayout (slippage guard).
    /// @return totalPayout Total MONSTRO delivered to the caller.
    function redeemBatch(uint256 amount, uint256 minTotalPayout) external nonReentrant returns (uint256 totalPayout) {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_BATCH) revert BatchTooLarge();

        uint256 supply = totalSupply();
        if (amount > supply) revert ZeroSupply(); // cannot redeem more than exist (also guards div-by-zero below)

        // Replay the per-unit redeem against a local copy of the live vault, so the rate falls each
        // step exactly as sequential redeem() calls would; settle with a single transfer at the end.
        uint256 localVault = MONSTRO.balanceOf(address(this));
        for (uint256 i = 0; i < amount; i++) {
            uint256 gross  = localVault / supply;
            uint256 payout = (supply == 1) ? gross : gross - gross * REDEEM_FEE_BPS / BPS;
            if (payout == 0) revert ZeroPayout();
            localVault  -= payout;
            totalPayout += payout;
            unchecked { --supply; } // supply >= 1 in every iteration since amount <= totalSupply()
        }

        if (totalPayout < minTotalPayout) revert SlippageExceeded();

        // CEI: burn the caller's shares (reverts if they hold < amount) before transferring MONSTRO out.
        _burn(msg.sender, amount);
        MONSTRO.safeTransfer(msg.sender, totalPayout);

        emit RedeemedBatch(msg.sender, amount, totalPayout);
    }
}

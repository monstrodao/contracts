// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MonstroUSDC (mUSDC)
/// @notice ERC-4626 vault wrapping USDC into mUSDC. Exchange rate increases via hardcoded
///         mint/redeem fees and external USDC deposits (e.g. AutoBurnSplitter) without
///         corresponding share mints.
/// @dev Not upgradeable. Not pausable. Fees are immutable constants. Fee USDC stays in the
///      vault, increasing the exchange rate for all holders. First-depositor inflation attack
///      is mitigated by ensuring non-zero initial supply via constructor seed to dead address.
contract MonstroUSDC is ERC4626 {
    using Math for uint256;

    // --- Constants ---

    /// @notice Mint (deposit) fee: 0.05% (5 bps). Immutable.
    uint16 public constant MINT_FEE_BPS = 5;

    /// @notice Redeem (withdraw) fee: 0.25% (25 bps). Immutable.
    uint16 public constant REDEEM_FEE_BPS = 25;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Initial deposit to dead address for inflation attack mitigation.
    uint256 private constant SEED_AMOUNT = 1e6;

    // --- Errors ---

    error ZeroShares();

    // --- Constructor ---

    /// @param _usdc Address of the USDC token (the underlying asset).
    /// @dev Seeds the vault with SEED_AMOUNT to address(0xdead) to ensure non-zero initial
    ///      supply, mitigating ERC-4626 inflation attacks. Requires deployer approval for
    ///      SEED_AMOUNT via deterministic address prediction (CREATE2/CREATE3).
    constructor(address _usdc)
        ERC4626(IERC20(_usdc))
        ERC20("Monstro USDC", "mUSDC")
    {
        // Seed vault: non-zero initial supply prevents first-depositor share manipulation.
        SafeERC20.safeTransferFrom(IERC20(_usdc), msg.sender, address(this), SEED_AMOUNT);
        _mint(address(0xdead), SEED_AMOUNT);
    }

    // --- Fee helpers ---

    /// @dev Deduct mint fee from assets, returning net amount that enters the vault.
    /// @param assets Gross USDC deposited by user.
    /// @return net USDC credited to vault after fee. @return fee USDC retained as fee.
    function _deductMintFee(uint256 assets) internal pure returns (uint256 net, uint256 fee) {
        fee = assets * MINT_FEE_BPS / BPS_DENOMINATOR;
        net = assets - fee;
    }

    /// @dev Inverse of _deductMintFee. Returns gross such that _deductMintFee(gross).net >= netAssets.
    /// @param netAssets Target net USDC after fee.
    function _grossForMintFee(uint256 netAssets) internal pure returns (uint256) {
        return netAssets.mulDiv(BPS_DENOMINATOR, BPS_DENOMINATOR - MINT_FEE_BPS, Math.Rounding.Ceil);
    }

    /// @dev Deduct redeem fee from gross assets, returning net to user.
    /// @param grossAssets USDC equivalent of shares being redeemed (before fee).
    /// @return net USDC sent to receiver. @return fee USDC retained in vault.
    function _deductRedeemFee(uint256 grossAssets) internal pure returns (uint256 net, uint256 fee) {
        fee = grossAssets * REDEEM_FEE_BPS / BPS_DENOMINATOR;
        net = grossAssets - fee;
    }

    /// @dev Inverse of _deductRedeemFee. Returns gross such that _deductRedeemFee(gross).net >= netAssets.
    /// @param netAssets Target net USDC after fee.
    function _grossForRedeemFee(uint256 netAssets) internal pure returns (uint256) {
        return netAssets.mulDiv(BPS_DENOMINATOR, BPS_DENOMINATOR - REDEEM_FEE_BPS, Math.Rounding.Ceil);
    }

    // --- Preview overrides (fee-aware) ---

    /// @notice Preview shares received for depositing `assets` USDC (mint fee deducted).
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        (uint256 net,) = _deductMintFee(assets);
        return _convertToShares(net, Math.Rounding.Floor);
    }

    /// @notice Preview USDC required to mint exactly `shares` mUSDC (mint fee added).
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        return _grossForMintFee(netAssets);
    }

    /// @notice Preview shares burned to withdraw exactly `assets` USDC after redeem fee.
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 gross = _grossForRedeemFee(assets);
        return _convertToShares(gross, Math.Rounding.Ceil);
    }

    /// @notice Preview USDC received for redeeming `shares` mUSDC (redeem fee deducted).
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 gross = _convertToAssets(shares, Math.Rounding.Floor);
        (uint256 net,) = _deductRedeemFee(gross);
        return net;
    }

    // --- Public deposit/mint/withdraw/redeem (fee collection) ---

    /// @notice Deposit USDC, receive mUSDC shares. Mint fee stays in the vault (grows rate).
    /// @param assets USDC amount to deposit (fee deducted internally).
    /// @param receiver Address receiving the mUSDC shares.
    /// @return shares Number of shares minted.
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        (uint256 net,) = _deductMintFee(assets);
        uint256 shares = _convertToShares(net, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares();

        SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), assets);
        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /// @notice Mint exact mUSDC shares by depositing USDC. Mint fee stays in the vault.
    /// @param shares Exact shares to mint.
    /// @param receiver Address receiving the mUSDC shares.
    /// @return gross USDC pulled from caller (including mint fee).
    function mint(uint256 shares, address receiver) public virtual override returns (uint256) {
        if (shares == 0) revert ZeroShares();
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        }

        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        uint256 gross = _grossForMintFee(netAssets);

        // Pull ALL gross USDC into vault. Fee portion stays, growing totalAssets.
        SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), gross);
        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, gross, shares);

        return gross;
    }

    /// @notice Withdraw exact USDC. Burns enough shares to cover gross (including redeem fee).
    /// @param assets Exact USDC to deliver to receiver.
    /// @param receiver Address receiving the USDC.
    /// @param _owner Address whose shares are burned.
    /// @return shares Number of shares burned.
    function withdraw(uint256 assets, address receiver, address _owner)
        public
        virtual
        override
        returns (uint256)
    {
        uint256 maxAssets = maxWithdraw(_owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(_owner, assets, maxAssets);
        }

        uint256 gross = _grossForRedeemFee(assets);
        uint256 shares = _convertToShares(gross, Math.Rounding.Ceil);

        if (_msgSender() != _owner) {
            _spendAllowance(_owner, _msgSender(), shares);
        }
        _burn(_owner, shares);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit Withdraw(_msgSender(), receiver, _owner, assets, shares);

        return shares;
    }

    /// @notice Redeem mUSDC shares for USDC. Redeem fee deducted from output.
    /// @param shares Number of shares to redeem.
    /// @param receiver Address receiving the USDC.
    /// @param _owner Address whose shares are burned.
    /// @return net USDC delivered to receiver (after redeem fee).
    function redeem(uint256 shares, address receiver, address _owner)
        public
        virtual
        override
        returns (uint256)
    {
        uint256 maxShares = maxRedeem(_owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(_owner, shares, maxShares);
        }

        uint256 gross = _convertToAssets(shares, Math.Rounding.Floor);

        _withdrawWithFee(_msgSender(), receiver, _owner, gross, shares);

        (uint256 net,) = _deductRedeemFee(gross);
        return net;
    }

    // --- Internal overrides ---

    /// @dev Redeem path: burns shares, deducts fee from gross, sends net to receiver.
    ///      Fee stays in vault, increasing exchange rate for remaining holders.
    function _withdrawWithFee(
        address caller,
        address receiver,
        address _owner,
        uint256 grossAssets,
        uint256 shares
    ) internal {
        if (caller != _owner) {
            _spendAllowance(_owner, caller, shares);
        }

        _burn(_owner, shares);

        (uint256 net,) = _deductRedeemFee(grossAssets);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, net);

        emit Withdraw(caller, receiver, _owner, net, shares);
    }

    // --- Max functions (fee-aware) ---

    /// @notice Maximum USDC withdrawable by owner (net after redeem fee).
    /// @dev Verifies the round-trip: withdraw(maxWithdraw(owner)) must not require more
    ///      shares than the owner holds. Decrements by 1 if ceiling rounding would overflow.
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        uint256 ownerBal = balanceOf(_owner);
        if (ownerBal == 0) return 0;
        uint256 gross = _convertToAssets(ownerBal, Math.Rounding.Floor);
        (uint256 net,) = _deductRedeemFee(gross);
        for (uint256 i; i < 8 && net > 0; i++) {
            uint256 grossCheck = _grossForRedeemFee(net);
            uint256 sharesNeeded = _convertToShares(grossCheck, Math.Rounding.Ceil);
            if (sharesNeeded <= ownerBal) break;
            net -= 1;
        }
        return net;
    }

    /// @notice Maximum shares redeemable by owner. Fee-aware: returns actual balance since
    ///         redeem() handles fee deduction from the output, not from shares burned.
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        return balanceOf(_owner);
    }
}

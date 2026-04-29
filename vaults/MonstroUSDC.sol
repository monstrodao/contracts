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

    /// @dev Closed-form gross required to mint exactly `shares` when fee lands in vault
    ///      before share pricing. Derived from the invariant:
    ///      shares / (totalSupply + 1) == net / (totalAssets + fee + 1),
    ///      with net = gross * (BPS - MINT_FEE_BPS) / BPS and fee = gross * MINT_FEE_BPS / BPS.
    function _mintGross(uint256 shares) private view returns (uint256) {
        uint256 T = totalAssets();
        uint256 S = totalSupply();
        uint256 denom = (S + 1) * (BPS_DENOMINATOR - MINT_FEE_BPS) - shares * MINT_FEE_BPS;
        return shares.mulDiv((T + 1) * BPS_DENOMINATOR, denom, Math.Rounding.Ceil);
    }

    /// @dev Shares required to withdraw exactly `assets` USDC, honoring the last-redeemer
    ///      skip-fee rule. If burning `sharesNoFee` would leave only dead shares, the fee
    ///      would be lost entirely to dead shares; in that case we burn `sharesNoFee` instead.
    ///
    ///      The LLR condition uses `sharesNoFee` (not `sharesWithFee`) because that is the
    ///      quantity actually burned on the no-fee path. Using `sharesWithFee` here created a
    ///      dead zone where previewWithdraw() claimed no fee was needed, but redeem() applied it
    ///      because the post-burn supply still exceeded SEED_AMOUNT. This made
    ///      previewWithdraw(X) and redeem(previewWithdraw(X)) inconsistent for any X in the
    ///      range (balance*0.9975, balance).
    function _sharesForWithdraw(uint256 assets) internal view returns (uint256) {
        uint256 sharesNoFee = _convertToShares(assets, Math.Rounding.Ceil);
        uint256 gross = _grossForRedeemFee(assets);
        uint256 sharesWithFee = _convertToShares(gross, Math.Rounding.Ceil);
        if (totalSupply() <= sharesNoFee + SEED_AMOUNT) {
            return sharesNoFee;
        }
        return sharesWithFee;
    }

    // --- Preview overrides (fee-aware) ---

    /// @notice Preview shares received for depositing `assets` USDC (mint fee deducted).
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        if (totalSupply() == SEED_AMOUNT) {
            return _convertToShares(assets, Math.Rounding.Floor);
        }
        (uint256 net, uint256 fee) = _deductMintFee(assets);
        return net.mulDiv(totalSupply() + 1, totalAssets() + fee + 1, Math.Rounding.Floor);
    }

    /// @notice Preview USDC required to mint exactly `shares` mUSDC (mint fee added).
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        if (shares == 0) return 0;
        if (totalSupply() == SEED_AMOUNT) {
            return _convertToAssets(shares, Math.Rounding.Ceil);
        }
        return _mintGross(shares);
    }

    /// @notice Preview shares burned to withdraw exactly `assets` USDC after redeem fee.
    /// @dev Matches withdraw() exactly: last live redeemer (leaves only dead shares) pays no fee.
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        return _sharesForWithdraw(assets);
    }

    /// @notice Preview USDC received for redeeming `shares` mUSDC (redeem fee deducted).
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 gross = _convertToAssets(shares, Math.Rounding.Floor);
        if (totalSupply() <= shares + SEED_AMOUNT) {
            return gross;
        }
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

        uint256 shares;
        if (totalSupply() == SEED_AMOUNT) {
            // Only dead shares present: skip fee so fee is not lost entirely to dead shares.
            shares = _convertToShares(assets, Math.Rounding.Floor);
            if (shares == 0) revert ZeroShares();
            SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), assets);
        } else {
            (uint256 net, uint256 fee) = _deductMintFee(assets);
            if (fee > 0) {
                // Transfer fee first so it is reflected in totalAssets before pricing shares.
                SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), fee);
            }
            shares = _convertToShares(net, Math.Rounding.Floor);
            if (shares == 0) revert ZeroShares();
            SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), net);
        }

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

        uint256 gross;
        if (totalSupply() == SEED_AMOUNT) {
            // Only dead shares present: skip fee so fee is not lost entirely to dead shares.
            gross = _convertToAssets(shares, Math.Rounding.Ceil);
        } else {
            gross = _mintGross(shares);
        }

        // Pull ALL gross USDC into vault. Fee portion stays, growing totalAssets.
        SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), gross);
        _mint(receiver, shares);

        emit Deposit(_msgSender(), receiver, gross, shares);

        return gross;
    }

    /// @notice Withdraw exact USDC. Burns shares according to fee and LLR rules.
    /// @dev When the owner holds all non-dead supply (last live redeemer), the redeem fee
    ///      would flow entirely to dead shares with no benefit to any living holder. In that
    ///      case the fee is waived for ALL amounts ≤ maxWithdraw (not just the final full
    ///      redemption). This ensures withdraw(amount) is executable for every
    ///      amount ≤ maxWithdraw, satisfying the ERC-4626 invariant. For non-LLR owners the
    ///      fee-inclusive path (_sharesForWithdraw) is used as normal.
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

        uint256 shares;
        if (totalSupply() <= balanceOf(_owner) + SEED_AMOUNT) {
            // Owner is the last live redeemer: fee goes to dead shares only, so waive it.
            shares = _convertToShares(assets, Math.Rounding.Ceil);
        } else {
            shares = _sharesForWithdraw(assets);
        }

        if (_msgSender() != _owner) {
            _spendAllowance(_owner, _msgSender(), shares);
        }
        _burn(_owner, shares);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit Withdraw(_msgSender(), receiver, _owner, assets, shares);

        return shares;
    }

    /// @notice Owner-aware preview of shares that withdraw(assets, *, owner) would burn.
    /// @dev Unlike previewWithdraw, this accounts for the owner's LLR status. Use this
    ///      when computing the exact share count for a known owner's withdrawal (e.g. to
    ///      lock the correct share count at loan origination in LendingLedger).
    function previewWithdrawFrom(address owner, uint256 assets) public view returns (uint256) {
        if (totalSupply() <= balanceOf(owner) + SEED_AMOUNT) {
            return _convertToShares(assets, Math.Rounding.Ceil);
        }
        return _sharesForWithdraw(assets);
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
        // Last live redeemer (leaves only dead shares) pays no fee; align return with payout.
        bool skipFee = totalSupply() <= shares + SEED_AMOUNT;

        _withdrawWithFee(_msgSender(), receiver, _owner, gross, shares);

        if (skipFee) return gross;
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

        // If only dead shares remain, skip fee: there is no holder left to benefit from it.
        uint256 payout;
        if (totalSupply() <= SEED_AMOUNT) {
            payout = grossAssets;
        } else {
            (payout,) = _deductRedeemFee(grossAssets);
        }
        SafeERC20.safeTransfer(IERC20(asset()), receiver, payout);

        emit Withdraw(caller, receiver, _owner, payout, shares);
    }

    // --- Max functions (fee-aware) ---

    /// @notice Maximum shares that can be minted in a single call without reverting.
    /// @dev `_mintGross` has two failure modes we must avoid:
    ///      1. Overflow in `shares * (totalAssets() + 1) * BPS_DENOMINATOR`.
    ///      2. Underflow in `(S+1)*(BPS - MINT_FEE_BPS) - shares*MINT_FEE_BPS` when
    ///         `shares * MINT_FEE_BPS > (S+1) * (BPS - MINT_FEE_BPS)`.
    ///      In the seed-only state, mint() uses _convertToAssets() not _mintGross(), so the
    ///      underflow bound does not apply; only the overflow bound constrains the result.
    function maxMint(address) public view virtual override returns (uint256) {
        uint256 T = totalAssets();
        if (T == 0) return 0;

        uint256 overflowBound = type(uint256).max / (BPS_DENOMINATOR * (T + 1));

        // In seed-only state, mint() uses _convertToAssets() not _mintGross(),
        // so the _mintGross denominator underflow bound does not apply.
        if (totalSupply() == SEED_AMOUNT) {
            return overflowBound;
        }

        uint256 underflowBound = (totalSupply() + 1).mulDiv(
            BPS_DENOMINATOR - MINT_FEE_BPS,
            MINT_FEE_BPS,
            Math.Rounding.Floor
        );

        uint256 cap = overflowBound < underflowBound ? overflowBound : underflowBound;
        return cap == 0 ? 0 : cap - 1;
    }

    /// @notice Maximum USDC withdrawable by owner.
    /// @dev Last live redeemer (owner holds all non-dead supply) pays no fee, so we return
    ///      gross. Otherwise, return a net amount whose round-trip through previewWithdraw
    ///      fits within owner balance.
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        uint256 ownerBal = balanceOf(_owner);
        if (ownerBal == 0) return 0;

        // Last live redeemer: burning all owner shares leaves only dead shares, so no fee.
        if (totalSupply() <= ownerBal + SEED_AMOUNT) {
            return _convertToAssets(ownerBal, Math.Rounding.Floor);
        }

        uint256 gross = _convertToAssets(ownerBal, Math.Rounding.Floor);
        (uint256 net,) = _deductRedeemFee(gross);
        for (uint256 i; i < 8 && net > 0; i++) {
            if (previewWithdraw(net) <= ownerBal) break;
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

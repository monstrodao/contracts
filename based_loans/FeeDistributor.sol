// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAutoExecutable {
    function executeBurns() external;
}

/// @title BasedLoansFeeDistributor
/// @notice Three-tier fee splitting. Tier 1 and tier 2 each route to a fixed recipient;
///         tier 3 supports per-asset sub-recipients. Fees accumulate into unclaimed balances
///         and are pulled via claim(). The authorized Core contract triggers distributeFees().
contract BasedLoansFeeDistributor is Ownable {
    using SafeERC20 for IERC20;

    // --- Errors ---

    error Unauthorized();
    error ZeroAddress();
    error FeeTooHigh();
    error InvalidBpsSum();
    error InvalidRecipientCount();
    error NothingToClaim();
    error NotOperatorOrOwner();

    // --- Structs ---

    struct Tier1Recipient {
        address recipient;
        uint16 weightBps;    // share of tier1 bucket (all weights must sum to 10000)
    }

    struct GrowthSub {
        address recipient;
        uint16 bps;          // share of tier3 bucket (all subs must sum to 10000)
        uint64 endTimestamp;  // 0 = no expiry, past block.timestamp = inactive → share to tier1
    }

    // --- State Variables ---

    uint16 public globalFeeBps; // e.g., 249 = 2.49%
    address public authorizedCore;
    IERC20 public immutable USDC;

    /// @notice Optional operator address for agile management of growth subs.
    address public operator;

    /// @notice Cumulative USDC fees received by the protocol since deployment.
    uint256 public totalFeesCollected;

    // 3-tier config (global)
    uint16 public tier1Bps;
    uint16 public tier2Bps;
    uint16 public tier3Bps;
    address public tier2Recipient;

    // Tier 1 multi-recipient (max 5, weights sum to 10000)
    Tier1Recipient[] private _tier1Recipients;

    // Per-asset growth sub-recipients (under tier3)
    mapping(address => GrowthSub[]) private _growthSubs;

    mapping(address => uint256) public unclaimedBalances;

    // --- Events ---

    event TierConfigUpdated(uint16[3] bps, address tier2Recipient);
    event Tier1RecipientsUpdated(Tier1Recipient[] recipients);
    event GrowthSubsUpdated(address indexed asset, GrowthSub[] subs);
    event FeeDistributed(address indexed asset, uint256 amount, uint256 tier1Amount, uint256 tier2Amount, uint256 tier3Amount);
    event Claimed(address indexed recipient, uint256 amount);
    event GlobalFeeUpdated(uint16 oldFee, uint16 newFee);
    event CoreAuthorized(address indexed oldCore, address indexed newCore);
    event OperatorUpdated(address oldOperator, address newOperator);

    // --- Modifiers ---

    modifier onlyOperatorOrOwner() {
        if (msg.sender != owner() && (operator == address(0) || msg.sender != operator)) {
            revert NotOperatorOrOwner();
        }
        _;
    }

    // --- Constructor ---

    /// @param _usdc Address of the USDC token contract.
    /// @param _owner Address that will own this contract.
    /// @param _operator Optional operator address (address(0) to disable).
    /// @param _tierBps Array of [tier1Bps, tier2Bps, tier3Bps] that must sum to 10000.
    /// @param _tier1Recips Initial tier 1 recipients with weights summing to 10000.
    /// @param _tier2Recipient Tier 2 recipient address.
    constructor(
        address _usdc,
        address _owner,
        address _operator,
        uint16[3] memory _tierBps,
        Tier1Recipient[] memory _tier1Recips,
        address _tier2Recipient
    ) Ownable(_owner) {
        if (_usdc == address(0) || _owner == address(0)) revert ZeroAddress();
        if (_tier2Recipient == address(0)) revert ZeroAddress();
        if (uint256(_tierBps[0]) + uint256(_tierBps[1]) + uint256(_tierBps[2]) != 10000) revert InvalidBpsSum();
        if (_tier1Recips.length == 0 || _tier1Recips.length > 5) revert InvalidRecipientCount();

        uint256 totalWeight;
        for (uint256 i = 0; i < _tier1Recips.length; i++) {
            if (_tier1Recips[i].recipient == address(0)) revert ZeroAddress();
            totalWeight += _tier1Recips[i].weightBps;
            _tier1Recipients.push(_tier1Recips[i]);
        }
        if (totalWeight != 10000) revert InvalidBpsSum();

        USDC = IERC20(_usdc);
        operator = _operator;

        tier1Bps = _tierBps[0];
        tier2Bps = _tierBps[1];
        tier3Bps = _tierBps[2];
        tier2Recipient = _tier2Recipient;
    }

    // --- Core Authorization ---

    /// @notice Updates the Core contract authorized to trigger fee distributions.
    function setCore(address _newCore) external onlyOwner {
        if (_newCore == address(0)) revert ZeroAddress();
        address oldCore = authorizedCore;
        authorizedCore = _newCore;
        emit CoreAuthorized(oldCore, _newCore);
    }

    // --- Core Interaction ---

    /// @notice Returns the global fee in basis points for Core to use in its calculations.
    function getGlobalFee() external view returns (uint16) {
        return globalFeeBps;
    }

    /// @notice Distributes a USDC fee amount received from Core across the 3-tier system.
    /// @param asset The collateral asset address (determines growth sub-recipients).
    /// @param amount The USDC amount to distribute (already transferred to this contract).
    function distributeFees(address asset, uint256 amount) external {
        if (msg.sender != authorizedCore) revert Unauthorized();

        totalFeesCollected += amount;

        if (amount == 0) {
            emit FeeDistributed(asset, 0, 0, 0, 0);
            return;
        }

        // Tier 1 and 2 get their BPS share; tier3 gets the remainder to avoid rounding loss
        uint256 t1Amount = (amount * tier1Bps) / 10000;
        uint256 t2Amount = (amount * tier2Bps) / 10000;
        uint256 t3Amount = amount - t1Amount - t2Amount;

        // Credit tier1 (split among weighted recipients) and tier2
        _distributeTier1(t1Amount);
        unclaimedBalances[tier2Recipient] += t2Amount;

        // Distribute tier3 among growth subs for this asset
        _distributeGrowthPool(asset, t3Amount);

        emit FeeDistributed(asset, amount, t1Amount, t2Amount, t3Amount);
    }

    // --- Admin Functions ---

    /// @notice Sets the operator address. Only callable by the owner.
    function setOperator(address _operator) external onlyOwner {
        address old = operator;
        operator = _operator;
        emit OperatorUpdated(old, _operator);
    }

    /// @notice Updates the global protocol fee.
    /// @param _newFee New fee in BPS (e.g. 200 = 2.00%). Capped at 1000 (10%).
    function setGlobalFee(uint16 _newFee) external onlyOwner {
        if (_newFee > 1000) revert FeeTooHigh();
        uint16 oldFee = globalFeeBps;
        globalFeeBps = _newFee;
        emit GlobalFeeUpdated(oldFee, _newFee);
    }

    /// @notice Updates the 3-tier BPS configuration and tier 2 recipient address.
    /// @param bps Array of [tier1Bps, tier2Bps, tier3Bps] that must sum to 10000.
    /// @param _tier2Addr Tier 2 recipient address (non-zero).
    function setTierConfig(uint16[3] calldata bps, address _tier2Addr) external onlyOwner {
        if (_tier2Addr == address(0)) revert ZeroAddress();
        if (uint256(bps[0]) + uint256(bps[1]) + uint256(bps[2]) != 10000) revert InvalidBpsSum();

        tier1Bps = bps[0];
        tier2Bps = bps[1];
        tier3Bps = bps[2];
        tier2Recipient = _tier2Addr;

        emit TierConfigUpdated(bps, _tier2Addr);
    }

    /// @notice Sets the tier 1 multi-recipient configuration.
    /// @dev Pass the full array each time; overwrites previous config. Weights must sum to 10000.
    ///      Max 5 recipients. All addresses must be non-zero.
    /// @param recipients Array of Tier1Recipient structs.
    function setTier1Recipients(Tier1Recipient[] calldata recipients) external onlyOwner {
        if (recipients.length == 0 || recipients.length > 5) revert InvalidRecipientCount();

        uint256 totalWeight;
        delete _tier1Recipients;

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].recipient == address(0)) revert ZeroAddress();
            totalWeight += recipients[i].weightBps;
            _tier1Recipients.push(recipients[i]);
        }

        if (totalWeight != 10000) revert InvalidBpsSum();

        emit Tier1RecipientsUpdated(recipients);
    }

    /// @notice Configures growth sub-recipients for an asset's tier3 share.
    /// @dev Pass full array each time; overwrites previous config. BPS must sum to 10000.
    ///      Max 5 subs per asset. All recipient addresses must be non-zero.
    /// @param asset The collateral asset address.
    /// @param subs Array of GrowthSub structs.
    function setGrowthSubs(address asset, GrowthSub[] calldata subs) external onlyOperatorOrOwner {
        if (subs.length == 0 || subs.length > 5) revert InvalidRecipientCount();

        uint256 totalBps;
        delete _growthSubs[asset];

        for (uint256 i = 0; i < subs.length; i++) {
            if (subs[i].recipient == address(0)) revert ZeroAddress();
            totalBps += subs[i].bps;
            _growthSubs[asset].push(subs[i]);
        }

        if (totalBps != 10000) revert InvalidBpsSum();

        emit GrowthSubsUpdated(asset, subs);
    }

    // --- Claims ---

    /// @notice Transfers the caller's entire unclaimed USDC fee balance to their wallet.
    function claim() external {
        uint256 amount = unclaimedBalances[msg.sender];
        if (amount == 0) revert NothingToClaim();

        unclaimedBalances[msg.sender] = 0;
        USDC.safeTransfer(msg.sender, amount);

        // Auto-trigger burns when tier 2 (AutoBurnSplitter) claims its USDC.
        // Code-size check ensures no revert on EOA; try/catch handles contract failures.
        if (msg.sender == tier2Recipient && msg.sender.code.length > 0) {
            try IAutoExecutable(msg.sender).executeBurns() {} catch {}
        }

        emit Claimed(msg.sender, amount);
    }

    // --- Views ---

    /// @notice Returns the tier 1 multi-recipient configuration.
    function getTier1Recipients() external view returns (Tier1Recipient[] memory) {
        return _tier1Recipients;
    }

    /// @notice Returns the growth sub-recipients configured for an asset.
    function getGrowthSubs(address asset) external view returns (GrowthSub[] memory) {
        return _growthSubs[asset];
    }

    // --- Internal ---

    /// @dev Distributes the tier1 amount among weighted recipients.
    function _distributeTier1(uint256 t1Amount) internal {
        if (t1Amount == 0) return;

        Tier1Recipient[] storage recips = _tier1Recipients;
        uint256 len = recips.length;
        uint256 distributed;

        for (uint256 i = 0; i < len; i++) {
            uint256 share;
            if (i == len - 1) {
                share = t1Amount - distributed;
            } else {
                share = (t1Amount * recips[i].weightBps) / 10000;
            }
            distributed += share;
            unclaimedBalances[recips[i].recipient] += share;
        }
    }

    /// @dev Distributes the tier3 amount among growth subs. Expired/unconfigured shares go to tier1.
    function _distributeGrowthPool(address asset, uint256 t3Amount) internal {
        if (t3Amount == 0) return;

        GrowthSub[] storage subs = _growthSubs[asset];
        uint256 len = subs.length;

        // No subs configured: entire tier3 goes to tier1
        if (len == 0) {
            _distributeTier1(t3Amount);
            return;
        }

        uint256 distributed;
        uint256 overflowToTier1;

        for (uint256 i = 0; i < len; i++) {
            GrowthSub memory s = subs[i];
            uint256 subShare;

            // Last sub gets remainder to avoid rounding loss
            if (i == len - 1) {
                subShare = t3Amount - distributed;
            } else {
                subShare = (t3Amount * s.bps) / 10000;
            }

            distributed += subShare;

            // Active if endTimestamp == 0 OR endTimestamp > block.timestamp
            if (s.endTimestamp == 0 || s.endTimestamp > block.timestamp) {
                unclaimedBalances[s.recipient] += subShare;
            } else {
                overflowToTier1 += subShare;
            }
        }

        // Credit overflow from expired subs to tier1
        if (overflowToTier1 > 0) {
            _distributeTier1(overflowToTier1);
        }
    }
}

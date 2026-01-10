// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IERC20Burnable is IERC20 {
    function burn(uint256 amount) external;
}

/**
 * @title MonstroStaking
 * @notice Unified staking contract for $MONSTRO with time-based penalties and emissions
 * @dev All stakes have 2-year penalty period (75% → 0%). One stake per wallet.
 * 
 * Features:
 * - Universal 2-year penalty decay (75% → 0% linearly)
 * - One stake per wallet (add-on adjusts time-weighted)
 * - $MONSTRO emissions with tier multipliers (Vault, Fortress, Kingdom)
 * - Merkle-based auto-stakes with 6-month or 12-month expiry
 * - Early withdrawal penalties allocate to: burn, treasury, refill emissions
 * - Transfer stake, gift stake, and compound functions
 * - Pause toggle (deploys paused for safe launch)
 * - DAO-updatable parameters and emergency emissions recovery
 */
contract MonstroStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Burnable;

    // =============================================================
    //                           CONSTANTS
    // =============================================================

    uint256 public constant PENALTY_PERIOD = 730 days; // 2 years
    uint256 public constant MAX_PENALTY_BPS = 7500; // 75%
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // =============================================================
    //                            STORAGE
    // =============================================================

    IERC20Burnable public immutable monstroToken;
    
    // Emissions
    uint256 public emissionsPerSecond; // ~1.286 tokens/second for 60M over 18 months
    uint256 public remainingEmissions;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;
    
    // Penalty distribution
    uint256 public penaltyBurnBps = 5000; // 50%
    uint256 public penaltyTreasuryBps = 2500; // 25%
    uint256 public penaltyRefillBps = 2500; // 25%
    address public daoTreasury;
    
    // Tier multipliers (in BPS, added on top of base)
    uint256 public vaultMultiplierBps = 300; // +3%
    uint256 public fortressMultiplierBps = 1500; // +15%
    uint256 public kingdomMultiplierBps = 3000; // +30%
    
    // Tier thresholds for dynamic tier calculation
    uint256[] public tierThresholds = [300000 * 1e18, 1500000 * 1e18, 3000000 * 1e18]; // Thresholds for Vault, Fortress, Kingdom
    
    uint256 public constant MIN_STAKE = 1e18; // 1 token minimum for new stakes
    
    // Pause state (default paused)
    bool public paused = true;
    
    // Merkle roots for auto-stakes
    bytes32 public merkleRoot6Month;
    bytes32 public merkleRoot12Month;
    uint256 public merkleExpiry6Month;
    uint256 public merkleExpiry12Month;
    
    // Auto-stake pools (track total unassigned allocations)
    uint256 public unassigned6MonthPool;
    uint256 public unassigned12MonthPool;
    uint256 public expiredAllocationsPool;
    
    // Pending treasury payments mapping for pull pattern
    mapping(address => uint256) public pendingTreasuryPayments;
    
    // Claim tracking for each pool
    mapping(address => bool) public claimed6Month;
    mapping(address => bool) public claimed12Month;
    
    // =============================================================
    //                            STRUCTS
    // =============================================================

    enum StatusTier {
        None,
        Vault,
        Fortress,
        Kingdom
    }
    
    struct StakeInfo {
        uint256 amount;
        uint256 startTime; // When penalty countdown started
        uint256 rewardPerTokenPaid;
        uint256 rewards;
        bool exists;
    }
    
    struct AutoStakeAllocation {
        uint256 amount;
        bool is12Month; // true = 12 month expiry, false = 6 month expiry
    }
    
    // =============================================================
    //                            MAPPINGS
    // =============================================================

    mapping(address => StakeInfo) public stakes;
    mapping(address => bool) public hasClaimedAutoStake;
    
    // =============================================================
    //                            EVENTS
    // =============================================================

    event Staked(address indexed user, uint256 amount, uint256 newTotal);
    event AddedToStake(address indexed user, uint256 amount, uint256 newTotal);
    event Compounded(address indexed user, uint256 amount, uint256 newTotal);
    event Withdrawn(address indexed user, uint256 amount, uint256 penalty);
    event RewardsClaimed(address indexed user, uint256 amount);
    event AutoStakeActivated(address indexed user, uint256 amount);
    event StakeGifted(address indexed sender, address indexed recipient, uint256 amount);
    event StakeTransferred(address indexed from, address indexed to, uint256 amount);
    event PenaltyDistributed(uint256 burned, uint256 treasury, uint256 emissions);
    event EmissionsFunded(address indexed funder, uint256 amount);
    event PoolExpired(bool is12Month, uint256 amount);
    event ExpiredAllocationsDistributed(uint256 burned, uint256 toTreasury, uint256 refilled);
    event TierThresholdsUpdated(uint256 vaultThreshold, uint256 fortressThreshold, uint256 kingdomThreshold);
    event EmissionsPerSecondUpdated(uint256 newRate);
    event PenaltySplitsUpdated(uint256 burnBps, uint256 treasuryBps, uint256 emissionsBps);
    event TierMultipliersUpdated(uint256 vaultBps, uint256 fortressBps, uint256 kingdomBps);
    event TreasuryUpdated(address newTreasury);
    event Paused();
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event TreasuryPaymentWithdrawn(address indexed treasury, uint256 amount);
    
    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor(
        address _token,
        address _treasury,
        uint256 _emissionsPerSecond,
        uint256 _totalEmissions,
        uint256 _pool6Month,
        uint256 _pool12Month,
        bytes32 _merkleRoot6Month,
        bytes32 _merkleRoot12Month,
        uint256 _expiry6Month,
        uint256 _expiry12Month
    ) Ownable(msg.sender) { // Deployer is initial owner
        monstroToken = IERC20Burnable(_token);
        daoTreasury = _treasury;
        emissionsPerSecond = _emissionsPerSecond;
        remainingEmissions = _totalEmissions;
        lastUpdateTime = block.timestamp;
        
        unassigned6MonthPool = _pool6Month;
        unassigned12MonthPool = _pool12Month;
        merkleRoot6Month = _merkleRoot6Month;
        merkleRoot12Month = _merkleRoot12Month;
        merkleExpiry6Month = _expiry6Month;
        merkleExpiry12Month = _expiry12Month;
        
        transferOwnership(_treasury);
    }

    // =============================================================
    //                          MODIFIERS
    // =============================================================

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }
    
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        
        if (account != address(0)) {
            StakeInfo storage userStake = stakes[account];
            if (userStake.exists) {
                userStake.rewards = earned(account);
                userStake.rewardPerTokenPaid = rewardPerTokenStored;
            }
        }
        _;
    }
    
    // =============================================================
    //                      STAKING FUNCTIONS
    // =============================================================

    /**
     * @notice Stake MONSTRO tokens
     * @param amount Amount to stake
     * @dev Removed tier parameter - now calculated dynamically based on stake amount
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        StakeInfo storage userStake = stakes[msg.sender];
        
        if (!userStake.exists) {
            require(amount >= MIN_STAKE, "Minimum 1 token for new stake");
        } else {
            require(amount > 0, "Cannot stake 0");
        }
        
        if (!userStake.exists) {
            // New stake
            userStake.amount = amount;
            userStake.startTime = block.timestamp;
            userStake.exists = true;
            
            emit Staked(msg.sender, amount, amount);
        } else {
            // Adding to existing stake - time-weighted adjustment
            uint256 oldAmount = userStake.amount;
            uint256 oldStartTime = userStake.startTime;
            uint256 newTotal = oldAmount + amount;
            
            // Time-weighted start time: (old_amount * old_time + new_amount * current_time) / total
            uint256 newStartTime = (oldAmount * oldStartTime + amount * block.timestamp) / newTotal;
            
            userStake.amount = newTotal;
            userStake.startTime = newStartTime;
            
            emit AddedToStake(msg.sender, amount, newTotal);
        }
        
        totalStaked += amount;
        monstroToken.safeTransferFrom(msg.sender, address(this), amount);
    }
    
    /**
     * @notice Activate auto-stake allocation via merkle proof (one-time "proof of life")
     * @param amount6Month Allocated amount for 6-month expiry
     * @param proof6Month Merkle proof for 6-month expiry
     * @param amount12Month Allocated amount for 12-month expiry
     * @param proof12Month Merkle proof for 12-month expiry
     * @dev Removed tier parameter - tier calculated dynamically from amount
     */
    function activateAutoStake(
        uint256 amount6Month,
        bytes32[] calldata proof6Month,
        uint256 amount12Month,
        bytes32[] calldata proof12Month
    ) external nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 totalClaimAmount = 0;
        
        // Try to claim 6-month allocation
        if (amount6Month > 0 && block.timestamp < merkleExpiry6Month && !claimed6Month[msg.sender]) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount6Month, false))));
            if (MerkleProof.verify(proof6Month, merkleRoot6Month, leaf)) {
                require(unassigned6MonthPool >= amount6Month, "6-month pool depleted");
                unassigned6MonthPool -= amount6Month;
                claimed6Month[msg.sender] = true;
                totalClaimAmount += amount6Month;
            }
        }
        
        // Try to claim 12-month allocation
        if (amount12Month > 0 && block.timestamp < merkleExpiry12Month && !claimed12Month[msg.sender]) {
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount12Month, true))));
            if (MerkleProof.verify(proof12Month, merkleRoot12Month, leaf)) {
                require(unassigned12MonthPool >= amount12Month, "12-month pool depleted");
                unassigned12MonthPool -= amount12Month;
                claimed12Month[msg.sender] = true;
                totalClaimAmount += amount12Month;
            }
        }
        
        require(totalClaimAmount > 0, "No valid allocation to claim");
        
        StakeInfo storage userStake = stakes[msg.sender];
        
        if (!userStake.exists) {
            // Create new stake
            userStake.amount = totalClaimAmount;
            userStake.startTime = block.timestamp;
            userStake.exists = true;
            
            emit AutoStakeActivated(msg.sender, totalClaimAmount);
        } else {
            // Add to existing stake with time-weighted adjustment
            uint256 oldAmount = userStake.amount;
            uint256 oldStartTime = userStake.startTime;
            uint256 newTotal = oldAmount + totalClaimAmount;
            
            // Time-weighted start time calculation
            uint256 newStartTime = (oldAmount * oldStartTime + totalClaimAmount * block.timestamp) / newTotal;
            
            userStake.amount = newTotal;
            userStake.startTime = newStartTime;
            
            emit AutoStakeActivated(msg.sender, totalClaimAmount);
            emit AddedToStake(msg.sender, totalClaimAmount, newTotal);
        }
        
        totalStaked += totalClaimAmount;
    }
    
    /**
     * @notice Withdraw staked tokens (applies penalty if within 2-year period)
     * @param withdrawAmount Amount to withdraw (0 = withdraw all)
     */
    function withdraw(uint256 withdrawAmount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.exists, "No stake");
        
        uint256 amount = withdrawAmount == 0 ? userStake.amount : withdrawAmount;
        require(amount > 0 && amount <= userStake.amount, "Invalid amount");

        _processRewardClaim(msg.sender, userStake.amount);
        
        // Calculate penalty
        uint256 penalty = calculatePenalty(msg.sender, amount);
        uint256 amountAfterPenalty = amount - penalty;
        
        // Update stake
        userStake.amount -= amount;
        totalStaked -= amount;
        
        if (userStake.amount == 0) {
            delete stakes[msg.sender];
        }
        
        // Process penalty
        if (penalty > 0) {
            _distributePenalty(penalty);
        }
        
        // Transfer tokens
        IERC20(address(monstroToken)).safeTransfer(msg.sender, amountAfterPenalty);
        
        emit Withdrawn(msg.sender, amountAfterPenalty, penalty);
    }
    
    /**
     * @notice Claim accumulated rewards
     */
    function claimRewards() external nonReentrant whenNotPaused updateReward(msg.sender) {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.exists, "No stake");
        
        _processRewardClaim(msg.sender, userStake.amount);
    }
    
    /**
     * @notice Compound pending rewards into stake (no withdrawal)
     * @dev Calculates rewards with tier bonus and adds to stake without token transfer
     */
    function compound() external nonReentrant whenNotPaused updateReward(msg.sender) {
        StakeInfo storage userStake = stakes[msg.sender];
        require(userStake.exists, "No stake");
        require(userStake.rewards > 0, "No rewards");
        
        uint256 reward = userStake.rewards;
        StatusTier currentTier = getTierForAmount(userStake.amount);
        uint256 multiplierBps = _getTierMultiplier(currentTier);
        uint256 bonus = (reward * multiplierBps) / BPS_DENOMINATOR;
        uint256 totalReward = reward + bonus;
        
        // Cap at remaining emissions
        if (totalReward > remainingEmissions) {
            totalReward = remainingEmissions;
            uint256 actualBasePaid = (totalReward * BPS_DENOMINATOR) / (BPS_DENOMINATOR + multiplierBps);
            userStake.rewards = reward - actualBasePaid;
        } else {
            userStake.rewards = 0;
        }
        
        require(totalReward > 0, "No emissions available");
        remainingEmissions -= totalReward;
        
        // Add to stake with time-weighted adjustment (tokens stay in contract)
        uint256 oldAmount = userStake.amount;
        uint256 oldStartTime = userStake.startTime;
        uint256 newTotal = oldAmount + totalReward;
        
        uint256 newStartTime = (oldAmount * oldStartTime + totalReward * block.timestamp) / newTotal;
        
        userStake.amount = newTotal;
        userStake.startTime = newStartTime;
        totalStaked += totalReward;
        
        emit Compounded(msg.sender, totalReward, newTotal);
    }
    
    /**
     * @notice Transfer entire stake to another wallet
     * @param to Recipient address (must not have an existing stake)
     */
    function transferStake(address to) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(to != address(0), "Invalid recipient");
        require(to != msg.sender, "Cannot transfer to self");
        
        StakeInfo storage fromStake = stakes[msg.sender];
        require(fromStake.exists, "No stake to transfer");
        
        StakeInfo storage toStake = stakes[to];
        require(!toStake.exists, "Recipient already has a stake");
        
        // Transfer stake data
        toStake.amount = fromStake.amount;
        toStake.startTime = fromStake.startTime;
        toStake.rewardPerTokenPaid = fromStake.rewardPerTokenPaid;
        toStake.rewards = fromStake.rewards;
        toStake.exists = true;
        
        emit StakeTransferred(msg.sender, to, fromStake.amount);
        
        // Clear sender's stake
        delete stakes[msg.sender];
    }
    
    /**
     * @notice Gift tokens to create or add to another wallet's stake
     * @param to Recipient address
     * @param amount Amount to gift
     * @dev Removed tier parameter - tier calculated dynamically
     */
    function giftStake(address to, uint256 amount) external nonReentrant whenNotPaused updateReward(to) {
        require(to != address(0), "Invalid recipient");
        require(to != msg.sender, "Cannot gift to self");
        require(amount > 0, "Cannot gift 0");
        
        StakeInfo storage toStake = stakes[to];
        
        if (!toStake.exists) {
            // Create new stake for recipient
            toStake.amount = amount;
            toStake.startTime = block.timestamp;
            toStake.exists = true;
        } else {
            // Add to existing stake with time-weighted adjustment
            uint256 oldAmount = toStake.amount;
            uint256 oldStartTime = toStake.startTime;
            uint256 newTotal = oldAmount + amount;
            
            uint256 newStartTime = (oldAmount * oldStartTime + amount * block.timestamp) / newTotal;
            
            toStake.amount = newTotal;
            toStake.startTime = newStartTime;
        }
        
        totalStaked += amount;
        monstroToken.safeTransferFrom(msg.sender, address(this), amount);
        
        emit StakeGifted(msg.sender, to, amount);
    }
    
    // =============================================================
    //                    EXPIRED ALLOCATION PROCESSING
    // =============================================================

    /**
     * @notice Expire 6-month pool and move to expired pool (anyone can call after expiry)
     */
    function expire6MonthPool() external {
        require(block.timestamp >= merkleExpiry6Month, "6-month period not expired");
        require(unassigned6MonthPool > 0, "No tokens in 6-month pool");

        uint256 amount = unassigned6MonthPool;
        expiredAllocationsPool += amount;
        unassigned6MonthPool = 0;

        emit PoolExpired(false, amount);
    }

    /**
     * @notice Expire 12-month pool and move to expired pool (anyone can call after expiry)
     */
    function expire12MonthPool() external {
        require(block.timestamp >= merkleExpiry12Month, "12-month period not expired");
        require(unassigned12MonthPool > 0, "No tokens in 12-month pool");

        uint256 amount = unassigned12MonthPool;
        expiredAllocationsPool += amount;
        unassigned12MonthPool = 0;

        emit PoolExpired(true, amount);
    }

    /**
     * @notice Distribute expired allocations (anyone can call)
     */
    function distributeExpiredAllocations() external nonReentrant {
        uint256 amount = expiredAllocationsPool;
        require(amount > 0, "No expired allocations to distribute");

        expiredAllocationsPool = 0;

        uint256 burnAmount = (amount * penaltyBurnBps) / BPS_DENOMINATOR;
        uint256 treasuryAmount = (amount * penaltyTreasuryBps) / BPS_DENOMINATOR;
        uint256 refillAmount = amount - burnAmount - treasuryAmount;

        remainingEmissions += refillAmount;

        monstroToken.burn(burnAmount);
        
        pendingTreasuryPayments[daoTreasury] += treasuryAmount;

        emit ExpiredAllocationsDistributed(burnAmount, treasuryAmount, refillAmount);
    }

    // =============================================================
    //                    CALCULATION FUNCTIONS
    // =============================================================

    /**
     * @notice Calculate current penalty for a stake
     * @param user User address
     * @param amount Amount being withdrawn
     * @return Penalty amount
     */
    function calculatePenalty(address user, uint256 amount) public view returns (uint256) {
        StakeInfo memory userStake = stakes[user];
        if (!userStake.exists) return 0;
        
        uint256 elapsed = block.timestamp - userStake.startTime;
        
        // After 2 years, no penalty
        if (elapsed >= PENALTY_PERIOD) {
            return 0;
        }
        
        // Linear decay: penalty = 75% * (remainingTime / 2 years)
        uint256 remainingTime = PENALTY_PERIOD - elapsed;
        
        // (amount * MAX_PENALTY_BPS * remainingTime) / (PENALTY_PERIOD * BPS_DENOMINATOR)
        return (amount * MAX_PENALTY_BPS * remainingTime) / (PENALTY_PERIOD * BPS_DENOMINATOR);
    }
    
    /**
     * @notice Calculate reward per token
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        
        uint256 timeSinceLastUpdate = block.timestamp - lastUpdateTime;
        uint256 newRewards = timeSinceLastUpdate * emissionsPerSecond;
        
        // Cap by remaining emissions
        if (newRewards > remainingEmissions) {
            newRewards = remainingEmissions;
        }
        
        return rewardPerTokenStored + (newRewards * 1e18 / totalStaked);
    }
    
    /**
     * @notice Calculate earned rewards for a user
     */
    function earned(address user) public view returns (uint256) {
        StakeInfo storage userStake = stakes[user];
        if (!userStake.exists) return 0;
        
        uint256 rewardPerTokenDelta = rewardPerToken() - userStake.rewardPerTokenPaid;
        uint256 newRewards = (userStake.amount * rewardPerTokenDelta) / 1e18;
        
        return userStake.rewards + newRewards;
    }
    
    /**
     * @notice Get time remaining until 0% penalty
     */
    function timeUntilNoPenalty(address user) external view returns (uint256) {
        StakeInfo storage userStake = stakes[user];
        if (!userStake.exists) return 0;
        
        uint256 elapsed = block.timestamp - userStake.startTime;
        if (elapsed >= PENALTY_PERIOD) return 0;
        
        return PENALTY_PERIOD - elapsed;
    }
    
    // =============================================================
    //                    COMPREHENSIVE GETTERS
    // =============================================================

    /**
     * @notice Get complete stake information for a user
     * @param user User address
     * @return amount Staked amount
     * @return startTime When penalty countdown started
     * @return tier Status tier
     * @return exists Whether stake exists
     * @return timeRemaining Time until 0% penalty
     * @return currentPenaltyBps Current penalty percentage in BPS
     */
    function getStakeInfo(address user) external view returns (
        uint256 amount,
        uint256 startTime,
        StatusTier tier,
        bool exists,
        uint256 timeRemaining,
        uint256 currentPenaltyBps
    ) {
        StakeInfo memory userStake = stakes[user];
        
        amount = userStake.amount;
        startTime = userStake.startTime;
        exists = userStake.exists;
        
        if (exists) {
            tier = getTierForAmount(amount); // Calculate tier dynamically
            uint256 elapsed = block.timestamp - startTime;
            if (elapsed >= PENALTY_PERIOD) {
                timeRemaining = 0;
                currentPenaltyBps = 0;
            } else {
                timeRemaining = PENALTY_PERIOD - elapsed;
                currentPenaltyBps = (MAX_PENALTY_BPS * timeRemaining) / PENALTY_PERIOD;
            }
        }
    }
    
    /**
     * @notice Get penalty information for a potential withdrawal
     * @param user User address
     * @param amount Amount to withdraw (0 = all)
     * @return penaltyAmount Penalty tokens that would be deducted
     * @return afterPenaltyAmount Amount user would receive
     * @return penaltyBps Current penalty percentage in BPS
     */
    function getPenaltyInfo(address user, uint256 amount) external view returns (
        uint256 penaltyAmount,
        uint256 afterPenaltyAmount,
        uint256 penaltyBps
    ) {
        StakeInfo memory userStake = stakes[user];
        if (!userStake.exists) return (0, 0, 0);
        
        uint256 withdrawAmount = amount == 0 ? userStake.amount : amount;
        
        uint256 elapsed = block.timestamp - userStake.startTime;
        if (elapsed >= PENALTY_PERIOD) {
            return (0, withdrawAmount, 0);
        }
        
        uint256 remainingTime = PENALTY_PERIOD - elapsed;
        penaltyBps = (MAX_PENALTY_BPS * remainingTime) / PENALTY_PERIOD;
        penaltyAmount = (withdrawAmount * penaltyBps) / BPS_DENOMINATOR;
        afterPenaltyAmount = withdrawAmount - penaltyAmount;
    }
    
    /**
     * @notice Get claimable rewards with tier bonus calculated
     * @param user User address
     * @return baseRewards Rewards before tier bonus
     * @return bonus Tier bonus amount
     * @return total Total claimable (base + bonus)
     */
    function getClaimableRewards(address user) external view returns (
        uint256 baseRewards,
        uint256 bonus,
        uint256 total
    ) {
        StakeInfo memory userStake = stakes[user];
        if (!userStake.exists) return (0, 0, 0);
        
        baseRewards = earned(user);
        StatusTier currentTier = getTierForAmount(userStake.amount); // Calculate tier dynamically
        uint256 multiplierBps = _getTierMultiplier(currentTier);
        bonus = (baseRewards * multiplierBps) / BPS_DENOMINATOR;
        total = baseRewards + bonus;
    }
    
    /**
     * @notice Get comprehensive user status and stats
     * @param user User address
     * @return hasStake Whether user has an active stake
     * @return stakedAmount Amount currently staked
     * @return claimableRewards Total claimable rewards (with bonus)
     * @return currentPenaltyBps Current penalty in BPS
     * @return daysUntilNoPenalty Days remaining until 0% penalty
     * @return tier Status tier
     */
    function getUserStatus(address user) external view returns (
        bool hasStake,
        uint256 stakedAmount,
        uint256 claimableRewards,
        uint256 currentPenaltyBps,
        uint256 daysUntilNoPenalty,
        StatusTier tier
    ) {
        StakeInfo memory userStake = stakes[user];
        
        hasStake = userStake.exists;
        stakedAmount = userStake.amount;
        
        if (hasStake) {
            tier = getTierForAmount(stakedAmount); // Calculate tier dynamically
            // Calculate claimable with bonus
            uint256 baseRewards = earned(user);
            uint256 multiplierBps = _getTierMultiplier(tier);
            uint256 bonus = (baseRewards * multiplierBps) / BPS_DENOMINATOR;
            claimableRewards = baseRewards + bonus;
            
            // Calculate penalty
            uint256 elapsed = block.timestamp - userStake.startTime;
            if (elapsed >= PENALTY_PERIOD) {
                currentPenaltyBps = 0;
                daysUntilNoPenalty = 0;
            } else {
                uint256 remainingTime = PENALTY_PERIOD - elapsed;
                currentPenaltyBps = (MAX_PENALTY_BPS * remainingTime) / PENALTY_PERIOD;
                daysUntilNoPenalty = remainingTime / 1 days;
            }
        }
    }
    
    /**
     * @notice Get global staking statistics
     * @return _totalStaked Total tokens staked across all users
     * @return _remainingEmissions Remaining emissions pool
     * @return _emissionsPerSecond Current emissions rate
     * @return _rewardPerToken Current reward per token value
     * @return _isPaused Whether contract is paused
     */
    function getGlobalStats() external view returns (
        uint256 _totalStaked,
        uint256 _remainingEmissions,
        uint256 _emissionsPerSecond,
        uint256 _rewardPerToken,
        bool _isPaused
    ) {
        return (
            totalStaked,
            remainingEmissions,
            emissionsPerSecond,
            rewardPerToken(),
            paused
        );
    }
    
    /**
     * @notice Get pool balances
     */
    function getPoolBalances() external view returns (
        uint256 pool6m,
        uint256 pool12m,
        uint256 expired
    ) {
        return (unassigned6MonthPool, unassigned12MonthPool, expiredAllocationsPool);
    }
    
    /**
     * @notice Check if user can claim their auto-stake allocation
     * @param user User address
     * @param amount6Month Allocation amount for 6-month expiry
     * @param proof6Month Merkle proof for 6-month expiry
     * @param amount12Month Allocation amount for 12-month expiry
     * @param proof12Month Merkle proof for 12-month expiry
     * @return canClaim Whether user can claim
     * @return reason Reason if cannot claim
     */
    function canClaimAutoStake(
        address user,
        uint256 amount6Month,
        bytes32[] calldata proof6Month,
        uint256 amount12Month,
        bytes32[] calldata proof12Month
    ) external view returns (bool canClaim, string memory reason) {
        // Check if already claimed
        if (claimed6Month[user] || claimed12Month[user]) {
            return (false, "Already claimed");
        }
        
        uint256 expiryTime6Month = merkleExpiry6Month;
        uint256 expiryTime12Month = merkleExpiry12Month;
        if (block.timestamp >= expiryTime6Month && block.timestamp >= expiryTime12Month) {
            return (false, "All allocations expired");
        }
        
        // Check if paused
        if (paused) {
            return (false, "Contract paused");
        }
        
        bytes32 leaf6Month = keccak256(bytes.concat(keccak256(abi.encode(user, amount6Month, false))));
        bytes32 leaf12Month = keccak256(bytes.concat(keccak256(abi.encode(user, amount12Month, true))));
        
        if (amount6Month > 0 && block.timestamp < expiryTime6Month && !claimed6Month[user]) {
            if (!MerkleProof.verify(proof6Month, merkleRoot6Month, leaf6Month)) {
                return (false, "Invalid merkle proof for 6-month allocation");
            }
            
            // Check pool availability
            uint256 poolAmount6Month = unassigned6MonthPool;
            if (poolAmount6Month < amount6Month) {
                return (false, "6-month pool depleted");
            }
        }
        
        if (amount12Month > 0 && block.timestamp < expiryTime12Month && !claimed12Month[user]) {
            if (!MerkleProof.verify(proof12Month, merkleRoot12Month, leaf12Month)) {
                return (false, "Invalid merkle proof for 12-month allocation");
            }
            
            // Check pool availability
            uint256 poolAmount12Month = unassigned12MonthPool;
            if (poolAmount12Month < amount12Month) {
                return (false, "12-month pool depleted");
            }
        }
        
        return (true, "");
    }
    
    /**
     * @notice Preview compound operation results
     * @param user User address
     * @return willReceive Amount that will be compounded
     * @return newStakeAmount Total stake after compound
     * @return newPenaltyBps New penalty BPS after time-weighted adjustment
     * @return newTimeUntilNoPenalty New time until 0% penalty
     */
    function getCompoundPreview(address user) external view returns (
        uint256 willReceive,
        uint256 newStakeAmount,
        uint256 newPenaltyBps,
        uint256 newTimeUntilNoPenalty
    ) {
        StakeInfo memory userStake = stakes[user];
        if (!userStake.exists) return (0, 0, 0, 0);
        
        // Calculate claimable with bonus
        uint256 baseRewards = earned(user);
        StatusTier currentTier = getTierForAmount(userStake.amount); // Calculate tier dynamically
        uint256 multiplierBps = _getTierMultiplier(currentTier);
        uint256 bonus = (baseRewards * multiplierBps) / BPS_DENOMINATOR;
        uint256 totalReward = baseRewards + bonus;
        
        // Cap to remaining emissions
        if (totalReward > remainingEmissions) {
            totalReward = remainingEmissions;
        }
        
        willReceive = totalReward;
        newStakeAmount = userStake.amount + totalReward;
        
        uint256 newStartTime = (userStake.amount * userStake.startTime + totalReward * block.timestamp) / newStakeAmount;
        uint256 elapsed = block.timestamp - newStartTime;
        
        if (elapsed >= PENALTY_PERIOD) {
            newPenaltyBps = 0;
            newTimeUntilNoPenalty = 0;
        } else {
            uint256 remaining = PENALTY_PERIOD - elapsed;
            newPenaltyBps = (MAX_PENALTY_BPS * remaining) / PENALTY_PERIOD;
            newTimeUntilNoPenalty = remaining;
        }
    }

    /**
     * @notice Preview impact of adding to existing stake
     * @param user Address to check
     * @param additionalAmount Amount to add
     * @return newPenaltyStartTime New penalty start time after add-on
     * @return newPenaltyEndTime New penalty end time after add-on
     * @return currentPenaltyBps Current penalty percentage
     * @return newPenaltyBps New penalty percentage after add-on
     */
    function getAddStakeImpact(address user, uint256 additionalAmount) external view returns (
        uint256 newPenaltyStartTime,
        uint256 newPenaltyEndTime,
        uint256 currentPenaltyBps,
        uint256 newPenaltyBps
    ) {
        StakeInfo memory position = stakes[user];
        require(position.exists, "No existing stake");
        require(additionalAmount > 0, "Amount must be > 0");
        
        // Current penalty
        uint256 timeElapsed = block.timestamp - position.startTime;
        if (timeElapsed >= PENALTY_PERIOD) {
            currentPenaltyBps = 0;
        } else {
            uint256 remainingTime = PENALTY_PERIOD - timeElapsed;
            currentPenaltyBps = (MAX_PENALTY_BPS * remainingTime) / PENALTY_PERIOD;
        }
        
        // Calculate weighted average of start times instead of subtracting elapsed time
        uint256 totalAmount = position.amount + additionalAmount;
        newPenaltyStartTime = (position.amount * position.startTime + additionalAmount * block.timestamp) / totalAmount;
        newPenaltyEndTime = newPenaltyStartTime + PENALTY_PERIOD;
        
        // New penalty
        uint256 newTimeElapsed = block.timestamp - newPenaltyStartTime;
        if (newTimeElapsed >= PENALTY_PERIOD) {
            newPenaltyBps = 0;
        } else {
            uint256 newRemainingTime = PENALTY_PERIOD - newTimeElapsed;
            newPenaltyBps = (MAX_PENALTY_BPS * newRemainingTime) / PENALTY_PERIOD;
        }
    }

    /**
     * @notice Calculate current staking APR based on emissions and total staked
     * @return aprBps Annual percentage rate in BPS (e.g., 1250 = 12.5%)
     */
    function getStakingAPR() external view returns (uint256 aprBps) {
        if (totalStaked == 0) return 0;
        
        // Annual emissions = emissionsPerSecond * seconds per year
        uint256 annualEmissions = emissionsPerSecond * 365 days;
        
        // APR = (annual emissions / total staked) * 10000
        aprBps = (annualEmissions * BPS_DENOMINATOR) / totalStaked;
    }

    /**
     * @notice Get expiry information for auto-stake pools
     * @return sixMonthExpiry Timestamp when 6-month pool expires
     * @return twelveMonthExpiry Timestamp when 12-month pool expires
     * @return sixMonthExpired Whether 6-month pool has expired
     * @return twelveMonthExpired Whether 12-month pool has expired
     * @return sixMonthRemaining Unassigned amount in 6-month pool
     * @return twelveMonthRemaining Unassigned amount in 12-month pool
     */
    function getPoolExpiryInfo() external view returns (
        uint256 sixMonthExpiry,
        uint256 twelveMonthExpiry,
        bool sixMonthExpired,
        bool twelveMonthExpired,
        uint256 sixMonthRemaining,
        uint256 twelveMonthRemaining
    ) {
        sixMonthExpiry = merkleExpiry6Month;
        twelveMonthExpiry = merkleExpiry12Month;
        sixMonthExpired = block.timestamp >= sixMonthExpiry;
        twelveMonthExpired = block.timestamp >= twelveMonthExpiry;
        sixMonthRemaining = unassigned6MonthPool;
        twelveMonthRemaining = unassigned12MonthPool;
    }

    /**
     * @notice Calculate how long emissions will last at current rate
     * @return daysRemaining Days until emissions depleted (0 if already empty)
     * @return hoursRemaining Hours until emissions depleted
     */
    function getEmissionsRunway() external view returns (
        uint256 daysRemaining,
        uint256 hoursRemaining
    ) {
        if (remainingEmissions == 0 || emissionsPerSecond == 0) {
            return (0, 0);
        }
        
        uint256 secondsRemaining = remainingEmissions / emissionsPerSecond;
        daysRemaining = secondsRemaining / 1 days;
        hoursRemaining = secondsRemaining / 1 hours;
    }

    /**
     * @notice Calculate the circulating supply of MONSTRO tokens
     * @dev Subtracts locked tokens from total supply:
     *      - Unclaimed 6-month allocations
     *      - Unclaimed 12-month allocations
     *      - Expired but not yet redistributed allocations
     *      - Remaining emissions not yet distributed
     * @return circulating The number of tokens in circulation
     */
    function getCirculatingSupply() external view returns (uint256 circulating) {
        uint256 totalSupply = monstroToken.totalSupply();
        uint256 locked = unassigned6MonthPool 
            + unassigned12MonthPool 
            + expiredAllocationsPool 
            + remainingEmissions;
        return totalSupply - locked;
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @notice Internal function to process reward claims with tier bonuses
     * @param user Address of the user claiming rewards
     * @param stakeAmount Amount used to determine tier for bonus calculation
     * @return totalReward Total reward paid (base + bonus)
     */
    function _processRewardClaim(address user, uint256 stakeAmount) internal returns (uint256 totalReward) {
        StakeInfo storage userStake = stakes[user];
        
        uint256 reward = userStake.rewards;
        if (reward == 0) return 0;
        
        StatusTier currentTier = getTierForAmount(stakeAmount);
        uint256 multiplierBps = _getTierMultiplier(currentTier);
        uint256 bonus = (reward * multiplierBps) / BPS_DENOMINATOR;
        totalReward = reward + bonus;
        
        if (totalReward > remainingEmissions) {
            totalReward = remainingEmissions;
            uint256 actualBasePaid = (totalReward * BPS_DENOMINATOR) / (BPS_DENOMINATOR + multiplierBps);
            userStake.rewards = reward - actualBasePaid;
        } else {
            userStake.rewards = 0;
        }
        
        require(totalReward > 0, "No emissions available");
        remainingEmissions -= totalReward;
        
        monstroToken.safeTransfer(user, totalReward);
        emit RewardsClaimed(user, totalReward);
        
        return totalReward;
    }

    /**
     * @dev Distribute penalty: 50% burn, 25% treasury, 25% refill emissions
     */
    function _distributePenalty(uint256 penalty) internal {
        uint256 burnAmount = (penalty * penaltyBurnBps) / BPS_DENOMINATOR;
        uint256 treasuryAmount = (penalty * penaltyTreasuryBps) / BPS_DENOMINATOR;
        uint256 refillAmount = penalty - burnAmount - treasuryAmount;
        
        monstroToken.burn(burnAmount);
        
        pendingTreasuryPayments[daoTreasury] += treasuryAmount;
        
        // Refill emissions
        remainingEmissions += refillAmount;
        
        emit PenaltyDistributed(burnAmount, treasuryAmount, refillAmount);
    }
    
    /**
     * @dev Get tier multiplier in BPS
     */
    function _getTierMultiplier(StatusTier tier) internal view returns (uint256) {
        if (tier == StatusTier.Vault) return vaultMultiplierBps;
        if (tier == StatusTier.Fortress) return fortressMultiplierBps;
        if (tier == StatusTier.Kingdom) return kingdomMultiplierBps;
        return 0;
    }
    
    // =============================================================
    //                    ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Update emissions rate (DAO only)
     */
    function setEmissionsPerSecond(uint256 _emissionsPerSecond) external onlyOwner updateReward(address(0)) {
        require(_emissionsPerSecond <= 10 * 1e18, "Emissions rate too high");
        emissionsPerSecond = _emissionsPerSecond;
        emit EmissionsPerSecondUpdated(_emissionsPerSecond);
    }
    
    /**
     * @notice Update penalty distribution percentages (DAO only)
     */
    function setPenaltyDistribution(
        uint256 _burnBps,
        uint256 _treasuryBps,
        uint256 _refillBps
    ) external onlyOwner {
        require(_burnBps + _treasuryBps + _refillBps == BPS_DENOMINATOR, "Must sum to 10000");
        penaltyBurnBps = _burnBps;
        penaltyTreasuryBps = _treasuryBps;
        penaltyRefillBps = _refillBps;
        emit PenaltySplitsUpdated(_burnBps, _treasuryBps, _refillBps);
    }
    
    /**
     * @notice Update tier multipliers (DAO only)
     */
    function setTierMultipliers(
        uint256 _vaultBps,
        uint256 _fortressBps,
        uint256 _kingdomBps
    ) external onlyOwner {
        vaultMultiplierBps = _vaultBps;
        fortressMultiplierBps = _fortressBps;
        kingdomMultiplierBps = _kingdomBps;
        emit TierMultipliersUpdated(_vaultBps, _fortressBps, _kingdomBps);
    }
    
    /**
     * @notice Update DAO treasury address (DAO only)
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        daoTreasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }
    
    /**
     * @notice Toggle pause state (DAO only)
     */
    function togglePause() external onlyOwner {
        paused = !paused;
        emit Paused();
    }
    
    /**
     * @notice Emergency withdraw emissions pool (DAO only)
     */
    function emergencyWithdrawEmissions(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount <= remainingEmissions, "Insufficient emissions");
        
        remainingEmissions -= amount;
        monstroToken.safeTransfer(to, amount);
        
        emit EmergencyWithdrawal(to, amount);
    }

    /**
     * @notice Emergency withdraw only excess tokens (DAO only)
     * @param to Address to receive tokens
     * @dev Automatically calculates withdrawable amount = balance - totalStaked to protect user funds
     */
    function emergencyWithdrawExcess(address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        
        uint256 contractBalance = monstroToken.balanceOf(address(this));
        require(contractBalance > totalStaked, "No excess tokens");
        
        uint256 excessAmount = contractBalance - totalStaked;
        
        // Cap at remainingEmissions to avoid underflow if excess includes treasury payments
        uint256 emissionsReduction = excessAmount > remainingEmissions ? remainingEmissions : excessAmount;
        remainingEmissions -= emissionsReduction;
        
        monstroToken.safeTransfer(to, excessAmount);
        
        emit EmergencyWithdrawal(to, excessAmount);
    }
    
    /**
     * @notice Fund emissions pool (anyone can add)
     */
    function fundEmissions(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        remainingEmissions += amount;
        monstroToken.safeTransferFrom(msg.sender, address(this), amount);
        emit EmissionsFunded(msg.sender, amount);
    }

    /// @notice Allows treasury to withdraw accumulated payments
    function withdrawTreasuryPayments() external nonReentrant {
        uint256 amount = pendingTreasuryPayments[msg.sender];
        require(amount > 0, "No pending payments");
        
        pendingTreasuryPayments[msg.sender] = 0;
        monstroToken.safeTransfer(msg.sender, amount);
        
        emit TreasuryPaymentWithdrawn(msg.sender, amount);
    }

    function setTierThresholds(
        uint256 _vaultThreshold,
        uint256 _fortressThreshold,
        uint256 _kingdomThreshold
    ) external onlyOwner {
        require(_vaultThreshold < _fortressThreshold && _fortressThreshold < _kingdomThreshold, 
            "Thresholds must be ascending");
        tierThresholds[0] = _vaultThreshold;
        tierThresholds[1] = _fortressThreshold;
        tierThresholds[2] = _kingdomThreshold;
        emit TierThresholdsUpdated(_vaultThreshold, _fortressThreshold, _kingdomThreshold);
    }
    
    // =============================================================
    //                    HELPERS
    // =============================================================

    /**
     * @dev Determine tier based on stake amount
     */
    function getTierForAmount(uint256 amount) public view returns (StatusTier) {
        if (amount >= tierThresholds[2]) return StatusTier.Kingdom;
        if (amount >= tierThresholds[1]) return StatusTier.Fortress;
        if (amount >= tierThresholds[0]) return StatusTier.Vault;
        return StatusTier.None;
    }
}

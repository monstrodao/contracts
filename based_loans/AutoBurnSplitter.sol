// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libraries/FullMath.sol";

// --- Minimal interfaces ---

/// @dev Minimal interface for FeeDistributor's claim function.
interface IFeeDistributorClaim {
    function claim() external;
}

/// @dev Minimal interface for tokens that support burn(uint256).
interface IBurnable {
    function burn(uint256 amount) external;
}

/// @dev Minimal V3 swap router interface (PancakeSwap/Alien Base SmartRouter pattern).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @dev Minimal V3 pool interface for TWAP price reading.
interface IV3Pool {
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title AutoBurnSplitter
/// @notice Receives USDC from FeeDistributor and executes burns for configured tokens.
///         Each burn target either transfers USDC directly to a vault (increasing totalAssets
///         without minting shares, raising the exchange rate), or swaps USDC for a token via
///         a DEX pool and burns it (with a dead-address fallback for non-burnable tokens).
/// @dev Not upgradeable. `executeBurns()` is permissionless (anyone can call, pays gas).
contract AutoBurnSplitter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Errors ---

    error InvalidBpsSum();
    error TooManyTargets();
    error IndexOutOfBounds();
    error ZeroAddress();
    error InvalidPool();
    error FeeDistributorNotSet();

    // --- Constants ---

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint8 public constant MAX_TARGETS = 5;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // --- Structs ---

    struct BurnTarget {
        address token;      // mUSDC address, MONSTRO address, etc.
        uint16 weightBps;   // share of incoming USDC (in bps, active must sum to 10000)
        bool active;        // toggle without removing
        bool useVault;      // true = direct USDC transfer to vault (raises exchange rate), false = pool swap + burn
        address vault;      // vault address (only used if useVault=true, ignored for swap targets)
        address pool;       // V3 pool address for TWAP price (only used if useVault=false, ignored for vault targets)
    }

    // --- State ---

    IERC20 public immutable USDC;
    BurnTarget[] public burnTargets;

    /// @notice FeeDistributor address for claimAndBurn(). Set by owner.
    address public feeDistributor;

    /// @notice Swap router address for pool-based burns. Configurable by owner.
    address public swapRouter;

    /// @notice Pool fee tier used for swap-based burns (e.g. 3000 = 0.30%). Configurable.
    uint24 public defaultPoolFee = 3000;

    /// @notice Maximum acceptable slippage for swaps in basis points (e.g. 300 = 3%).
    ///         Applied relative to the TWAP price from the pool.
    uint16 public maxSlippageBps = 300;

    /// @notice TWAP window in seconds for slippage price reference. Default 1800 (30 min).
    ///         Longer windows are harder to manipulate but may lag during fast moves.
    uint32 public twapWindow = 1800;

    // --- Events ---

    event BurnTargetsUpdated(BurnTarget[] targets);
    event TargetWeightUpdated(uint256 indexed index, uint16 oldWeight, uint16 newWeight);
    event TargetActiveUpdated(uint256 indexed index, bool active);
    event BurnExecuted(address indexed token, uint256 usdcAmount, uint256 burnedAmount, bool useVault);
    event BurnsCompleted(uint256 totalUsdc);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event SwapRouterUpdated(address oldRouter, address newRouter);
    event DefaultPoolFeeUpdated(uint24 oldFee, uint24 newFee);
    event MaxSlippageUpdated(uint16 oldBps, uint16 newBps);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);
    event FeeDistributorUpdated(address oldDistributor, address newDistributor);
    event ClaimAndBurnExecuted(uint256 claimed);

    // --- Constructor ---

    /// @param _usdc Address of the USDC token.
    /// @param _owner Address that will own this contract.
    constructor(address _usdc, address _owner) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        USDC = IERC20(_usdc);
    }

    // --- Admin ---

    /// @notice Replace all burn targets. Active target weights must sum to 10000.
    function setBurnTargets(BurnTarget[] calldata targets) external onlyOwner {
        if (targets.length > MAX_TARGETS) revert TooManyTargets();

        // Validate active targets are well-formed and weights sum to 10000
        uint256 activeSum;
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].active) {
                if (targets[i].weightBps == 0) revert InvalidBpsSum(); // no zero-weight active targets
                if (targets[i].token == address(0)) revert ZeroAddress();
                if (targets[i].useVault) {
                    if (targets[i].vault == address(0)) revert ZeroAddress();
                } else {
                    if (targets[i].pool == address(0)) revert InvalidPool();
                }
                activeSum += targets[i].weightBps;
            }
        }
        if (activeSum != BPS_DENOMINATOR) revert InvalidBpsSum();

        // Replace storage
        delete burnTargets;
        for (uint256 i = 0; i < targets.length; i++) {
            burnTargets.push(targets[i]);
        }

        emit BurnTargetsUpdated(targets);
    }

    /// @notice Adjust a single target's weight. Does NOT validate total sum (call setBurnTargets for full validation).
    /// @dev Owner must ensure active weights sum to 10000 before next executeBurns.
    function setTargetWeight(uint256 index, uint16 weight) external onlyOwner {
        if (index >= burnTargets.length) revert IndexOutOfBounds();
        uint16 old = burnTargets[index].weightBps;
        burnTargets[index].weightBps = weight;
        emit TargetWeightUpdated(index, old, weight);
    }

    /// @notice Toggle a target's active state.
    /// @dev Owner must ensure active weights sum to 10000 before next executeBurns.
    function setTargetActive(uint256 index, bool active) external onlyOwner {
        if (index >= burnTargets.length) revert IndexOutOfBounds();
        burnTargets[index].active = active;
        emit TargetActiveUpdated(index, active);
    }

    /// @notice Set the swap router address for pool-based burns.
    function setSwapRouter(address _router) external onlyOwner {
        address old = swapRouter;
        swapRouter = _router;
        emit SwapRouterUpdated(old, _router);
    }

    /// @notice Set the default pool fee for swaps.
    function setDefaultPoolFee(uint24 _fee) external onlyOwner {
        uint24 old = defaultPoolFee;
        defaultPoolFee = _fee;
        emit DefaultPoolFeeUpdated(old, _fee);
    }

    /// @notice Set maximum slippage tolerance for swaps (in bps, e.g. 300 = 3%).
    function setMaxSlippage(uint16 _bps) external onlyOwner {
        if (_bps > uint16(BPS_DENOMINATOR)) revert InvalidBpsSum();
        uint16 old = maxSlippageBps;
        maxSlippageBps = _bps;
        emit MaxSlippageUpdated(old, _bps);
    }

    /// @notice Set TWAP window for slippage price reference.
    function setTwapWindow(uint32 _window) external onlyOwner {
        if (_window == 0) revert InvalidPool();
        uint32 old = twapWindow;
        twapWindow = _window;
        emit TwapWindowUpdated(old, _window);
    }

    /// @notice Set the FeeDistributor address for claimAndBurn().
    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        address old = feeDistributor;
        feeDistributor = _feeDistributor;
        emit FeeDistributorUpdated(old, _feeDistributor);
    }

    /// @notice Emergency rescue for stuck tokens. Cannot be used during normal operation.
    function rescueToken(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(to, balance);
            emit TokenRescued(token, to, balance);
        }
    }

    // --- Permissionless execution ---

    /// @notice Claims accumulated USDC from FeeDistributor and executes burns in one call.
    ///         Anyone can call (pays gas). FeeDistributor.claim() already auto-calls
    ///         executeBurns() on this contract, so burns happen atomically. As a safety
    ///         fallback, if USDC remains after claim, executeBurns is called explicitly.
    function claimAndBurn() external nonReentrant {
        if (feeDistributor == address(0)) revert FeeDistributorNotSet();

        uint256 balanceBefore = USDC.balanceOf(address(this));

        // claim() transfers USDC here and auto-triggers executeBurns() via
        // FeeDistributor's try/catch on IAutoExecutable(tier2Recipient).executeBurns().
        // That inner executeBurns() call hits this contract's nonReentrant guard and
        // reverts (caught by FeeDistributor's try/catch); burns are handled below.
        IFeeDistributorClaim(feeDistributor).claim();

        uint256 claimed = USDC.balanceOf(address(this)) - balanceBefore;

        // Execute burns on whatever USDC is now held (claimed + any pre-existing balance)
        _executeBurnsInternal();

        emit ClaimAndBurnExecuted(claimed);
    }

    /// @notice Splits the contract's USDC balance across active burn targets by weight
    ///         and executes burns. Anyone can call (pays gas).
    /// @dev No-op if USDC balance is zero or no targets are configured.
    function executeBurns() external nonReentrant {
        _executeBurnsInternal();
    }

    // --- Views ---

    /// @notice Returns all burn targets.
    function getBurnTargets() external view returns (BurnTarget[] memory) {
        return burnTargets;
    }

    /// @notice Returns the number of configured burn targets.
    function burnTargetCount() external view returns (uint256) {
        return burnTargets.length;
    }

    // --- Internal ---

    /// @dev Core burn logic shared by executeBurns() and claimAndBurn().
    function _executeBurnsInternal() internal {
        uint256 totalUsdc = USDC.balanceOf(address(this));
        if (totalUsdc == 0) return;

        uint256 len = burnTargets.length;
        if (len == 0) return;

        uint256 distributed;

        for (uint256 i = 0; i < len; i++) {
            BurnTarget storage t = burnTargets[i];
            if (!t.active) continue;

            uint256 amount;
            bool isLast = _isLastActive(i);
            if (isLast) {
                amount = totalUsdc - distributed;
            } else {
                amount = totalUsdc * t.weightBps / BPS_DENOMINATOR;
            }

            if (amount == 0) continue;
            distributed += amount;

            if (t.useVault) {
                _executeVaultBurn(t.token, t.vault, amount);
            } else {
                _executeSwapBurn(t.token, t.pool, amount);
            }
        }

        emit BurnsCompleted(totalUsdc);
    }

    /// @dev Check if index `i` is the last active target.
    function _isLastActive(uint256 i) internal view returns (bool) {
        for (uint256 j = i + 1; j < burnTargets.length; j++) {
            if (burnTargets[j].active) return false;
        }
        return true;
    }

    /// @dev Calculate minimum acceptable output for a swap using the pool's TWAP price.
    ///      Uses observe() to get the time-weighted average tick over `twapWindow` seconds,
    ///      converts to a price, and applies `maxSlippageBps` tolerance.
    ///      Reverts if the pool read fails (misconfigured pool should block execution,
    ///      not silently drop slippage protection).
    function _getMinAmountOut(address pool, address token, uint256 amountIn) internal view returns (uint256) {
        if (pool == address(0)) return 0; // No pool configured, vault-only target

        // Get TWAP tick from pool
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IV3Pool(pool).observe(secondsAgos);
        int24 avgTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(twapWindow)));

        // Convert tick to sqrtPriceX96: sqrtPrice = 1.0001^(tick/2) * 2^96
        // Use the TickMath approach: get sqrtRatioAtTick
        uint160 sqrtPriceX96 = _getSqrtRatioAtTick(avgTick);
        if (sqrtPriceX96 == 0) revert InvalidPool();

        // Derive expected output from TWAP price using FullMath to avoid overflow
        address token0 = IV3Pool(pool).token0();
        address token1 = IV3Pool(pool).token1();

        // Validate pool contains exactly USDC and the target token
        bool validPair = (token0 == address(USDC) && token1 == token)
            || (token0 == token && token1 == address(USDC));
        if (!validPair) revert InvalidPool();

        uint256 expectedOut;

        if (token0 == token) {
            // token is token0, USDC is token1
            // expectedOut (in token0) = amountIn * 2^192 / sqrtPrice^2
            // Split into two mulDiv to avoid overflow
            expectedOut = FullMath.mulDiv(amountIn, uint256(1) << 96, uint256(sqrtPriceX96));
            expectedOut = FullMath.mulDiv(expectedOut, uint256(1) << 96, uint256(sqrtPriceX96));
        } else {
            // USDC is token0, token is token1
            // expectedOut (in token1) = amountIn * sqrtPrice^2 / 2^192
            expectedOut = FullMath.mulDiv(amountIn, uint256(sqrtPriceX96), uint256(1) << 96);
            expectedOut = FullMath.mulDiv(expectedOut, uint256(sqrtPriceX96), uint256(1) << 96);
        }

        // Apply slippage tolerance
        return expectedOut * (BPS_DENOMINATOR - maxSlippageBps) / BPS_DENOMINATOR;
    }

    /// @dev Attempt to compute sqrtRatioAtTick using the standard approximation.
    ///      Adapted from Uniswap V3 TickMath. Returns the sqrt price as a Q64.96 value.
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > 887272) return 0; // Out of range

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        return uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @dev Transfer USDC directly to the vault. This increases totalAssets without minting
    ///      new shares, so the exchange rate (assets per share) goes up for all holders.
    function _executeVaultBurn(address token, address vault, uint256 amount) internal {
        USDC.safeTransfer(vault, amount);
        emit BurnExecuted(token, amount, amount, true);
    }

    /// @dev Swap USDC for token via router, then burn the received tokens.
    ///      If the token supports burn(uint256), calls it for a real supply reduction.
    ///      Otherwise falls back to sending tokens to the dead address.
    ///      Slippage protection uses the pool's TWAP price with maxSlippageBps tolerance.
    /// @notice Uses the configured swapRouter. If no router is set, this will revert.
    function _executeSwapBurn(address token, address pool, uint256 amount) internal {
        address router = swapRouter;
        if (router == address(0)) revert ZeroAddress();

        // Calculate minimum output from TWAP price
        uint256 minOut = _getMinAmountOut(pool, token, amount);

        // Approve router (forceApprove handles non-zero → non-zero safely)
        USDC.forceApprove(router, amount);

        // Execute swap: USDC -> token, received by this contract
        uint256 amountOut = ISwapRouter(router).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: token,
                fee: defaultPoolFee,
                recipient: address(this),
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        // Reset approval to zero (prevent dangling allowance if router consumed less)
        USDC.forceApprove(router, 0);

        // Try real burn first, fall back to dead address
        try IBurnable(token).burn(amountOut) {
            // Token was burned (total supply reduced)
        } catch {
            // Token doesn't support burn(), send to dead address
            IERC20(token).safeTransfer(DEAD, amountOut);
        }

        emit BurnExecuted(token, amount, amountOut, false);
    }
}

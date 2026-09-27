// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Burns token fees and uses native-ETH fee claims for permissionless buybacks.
/// @dev Only native currency0 pools participate. Each PoolId has its own budget and cooldown.
contract BuybackBurnHook is BaseHook, IUnlockCallback {
    uint256 public constant FEE_BPS = 100;
    uint256 public constant MIN_BUYBACK = 0.001 ether;
    uint256 public constant MAX_BUYBACK = 0.05 ether;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    mapping(PoolId => uint256) public accruedEth;
    mapping(PoolId => uint256) public burnedTotal;
    mapping(PoolId => uint256) public lastBuybackBlock;

    bool private buyingBack;
    bytes32 private pendingCallback;

    error InvalidPool();
    error BelowThreshold();
    error AlreadyBoughtBack();
    error BuybackInProgress();
    error UnexpectedCallback();
    error InvalidBuybackDelta();

    event FeeBurned(PoolId indexed poolId, uint256 amount);
    event FeeAccrued(PoolId indexed poolId, uint256 amount);
    event Buyback(PoolId indexed poolId, uint256 ethSpent, uint256 tokensBurned);

    constructor(IPoolManager manager) BaseHook(manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (!key.currency0.isAddressZero() || sender == address(this)) {
            return (this.afterSwap.selector, 0);
        }

        bool feeInToken = (params.amountSpecified < 0) == params.zeroForOne;
        // Widen before negation so even int128.min has a representable absolute value.
        int256 unspecified = feeInToken ? int256(delta.amount1()) : int256(delta.amount0());
        uint256 amount = uint256(unspecified < 0 ? -unspecified : unspecified);
        uint256 fee = amount * FEE_BPS / 10_000;
        if (fee == 0) return (this.afterSwap.selector, 0);

        PoolId id = key.toId();
        if (feeInToken) {
            burnedTotal[id] += fee;
            emit FeeBurned(id, fee);
            poolManager.take(key.currency1, DEAD, fee);
        } else {
            accruedEth[id] += fee;
            emit FeeAccrued(id, fee);
            poolManager.mint(address(this), key.currency0.toId(), fee);
        }
        // The fee is at most 1% of |int128.min|, hence fits a positive int128.
        // A positive hook credit subtracts output or increases input owed by the swapper.
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Spend up to 0.05 ETH in accrued fees on this pool, at most once per block.
    /// @dev No minimum-output protection: callers must account for the documented sandwich risk.
    function buyback(PoolKey calldata key) external {
        if (buyingBack) revert BuybackInProgress();
        if (address(key.hooks) != address(this) || !key.currency0.isAddressZero()) revert InvalidPool();
        PoolId id = key.toId();
        uint256 budget = accruedEth[id];
        if (budget < MIN_BUYBACK) revert BelowThreshold();
        if (lastBuybackBlock[id] == block.number) revert AlreadyBoughtBack();
        if (budget > MAX_BUYBACK) budget = MAX_BUYBACK;

        buyingBack = true;
        lastBuybackBlock[id] = block.number;
        bytes memory data = abi.encode(key, budget);
        pendingCallback = keccak256(data);
        // PoolManager rejects this if another swap/unlock is already in progress.
        poolManager.unlock(data);
        buyingBack = false;
    }

    /// @dev Only the single callback authorized by buyback may consume this pool's budget.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!buyingBack || pendingCallback != keccak256(data)) revert UnexpectedCallback();
        delete pendingCallback;
        (PoolKey memory key, uint256 budget) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(budget), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        if (delta.amount0() >= 0 || delta.amount1() <= 0) revert InvalidBuybackDelta();
        uint256 spent = uint256(-int256(delta.amount0()));
        uint256 output = uint256(int256(delta.amount1()));
        if (spent > budget) revert InvalidBuybackDelta();

        PoolId id = key.toId();
        accruedEth[id] -= spent;
        burnedTotal[id] += output;
        emit Buyback(id, spent, output);
        // Burn only the actual input debt: a price limit or exhausted liquidity may partially fill.
        poolManager.burn(address(this), key.currency0.toId(), spent);
        poolManager.take(key.currency1, DEAD, output);
        return "";
    }
}

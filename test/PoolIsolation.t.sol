// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHookTest} from "./BaseHookTest.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BuybackBurnHook} from "../src/BuybackBurnHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract PoolIsolationTest is BaseHookTest {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function test_nativePoolsHaveSeparateBudgetsBurnCountersAndCooldowns() public {
        BuybackBurnHook burner = BuybackBurnHook(address(hook));
        LaunchToken second = new LaunchToken();
        PoolKey memory other = key;
        other.currency1 = Currency.wrap(address(second));
        manager.initialize(other, TickMath.getSqrtPriceAtTick(START_TICK));
        second.approve(address(modifyLiquidityRouter), type(uint256).max);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), second.totalSupply()
        );
        modifyLiquidityRouter.modifyLiquidity(
            other, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), 0), ""
        );

        swapNativeInput(key, true, 20_000_000 ether, "", 30 ether);
        swapNativeInput(other, true, 10_000_000 ether, "", 20 ether);
        uint256 firstAccrued = burner.accruedEth(key.toId());
        uint256 otherAccrued = burner.accruedEth(other.toId());
        assertEq(manager.balanceOf(address(hook), 0), firstAccrued + otherAccrued);

        burner.buyback(key);
        assertEq(burner.accruedEth(key.toId()), firstAccrued - 0.05 ether);
        assertEq(burner.accruedEth(other.toId()), otherAccrued);
        assertEq(burner.burnedTotal(other.toId()), 0);
        assertEq(burner.lastBuybackBlock(other.toId()), 0);
        assertEq(token.balanceOf(DEAD), burner.burnedTotal(key.toId()));

        burner.buyback(other); // Same block, different PoolId.
        assertEq(burner.accruedEth(other.toId()), otherAccrued - 0.05 ether);
        assertEq(second.balanceOf(DEAD), burner.burnedTotal(other.toId()));
        assertEq(burner.lastBuybackBlock(other.toId()), vm.getBlockNumber());
        assertEq(manager.balanceOf(address(hook), 0), burner.accruedEth(key.toId()) + burner.accruedEth(other.toId()));
    }

    function test_nonNativePoolAllFourSwapTypesReturnZeroFeeAndWriteNoState() public {
        MockERC20 a = new MockERC20("A", "A", 10_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 10_000_000 ether);
        (a, b) = address(a) < address(b) ? (a, b) : (b, a);
        a.approve(address(modifyLiquidityRouter), type(uint256).max);
        b.approve(address(modifyLiquidityRouter), type(uint256).max);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        PoolKey memory other =
            PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 3000, 60, IHooks(address(hook)));
        manager.initialize(other, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, 1_000_000 ether, 0), "");
        for (uint256 kind; kind < 4; ++kind) {
            vm.recordLogs();
            BalanceDelta delta = swap(other, kind < 2, kind % 2 == 0 ? -int256(1 ether) : int256(1 ether), "");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 count;
            for (uint256 j; j < logs.length; ++j) {
                assertTrue(logs[j].emitter != address(hook), "ignored pool emitted a hook event");
                if (
                    logs[j].emitter == address(manager)
                        && logs[j].topics[0]
                            == keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
                ) {
                    (int128 amount0, int128 amount1,,,,) =
                        abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
                    assertEq(delta.amount0(), amount0);
                    assertEq(delta.amount1(), amount1);
                    ++count;
                }
            }
            assertEq(count, 1);
        }
        BuybackBurnHook burner = BuybackBurnHook(address(hook));
        assertEq(burner.accruedEth(other.toId()), 0);
        assertEq(burner.burnedTotal(other.toId()), 0);
        assertEq(burner.lastBuybackBlock(other.toId()), 0);
        assertEq(a.balanceOf(DEAD), 0);
        assertEq(b.balanceOf(DEAD), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }
}

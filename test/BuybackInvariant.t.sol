// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseHookTest} from "./BaseHookTest.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BuybackBurnHook} from "../src/BuybackBurnHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract BuybackHandler is Test {
    using StateLibrary for IPoolManager;
    IPoolManager private immutable manager;
    PoolSwapTest private immutable router;
    BuybackBurnHook private immutable hook;
    PoolKey[2] private keys;
    uint256[5] public calls;

    constructor(
        IPoolManager manager_,
        PoolSwapTest router_,
        BuybackBurnHook hook_,
        PoolKey memory a,
        PoolKey memory b
    ) {
        manager = manager_;
        router = router_;
        hook = hook_;
        keys[0] = a;
        keys[1] = b;
        LaunchToken(Currency.unwrap(a.currency1)).approve(address(router), type(uint256).max);
        LaunchToken(Currency.unwrap(b.currency1)).approve(address(router), type(uint256).max);
    }

    function buyInput(uint256 which, uint96 amount) external {
        uint256 input = bound(amount, 1, 1 ether);
        _swap(which % 2, true, -int256(input), input);
        ++calls[0];
    }

    function buyOutput(uint256 which, uint96 amount) external {
        _swap(which % 2, true, int256(bound(amount, 1, 1_000_000 ether)), 10 ether);
        ++calls[1];
    }

    function sellInput(uint256 which, uint96 amount) external {
        which %= 2;
        uint256 balance = keys[which].currency1.balanceOf(address(this));
        if (balance == 0) return;
        uint256 cap = balance > 1_000_000 ether ? 1_000_000 ether : balance;
        _swap(which, false, -int256(bound(amount, 1, cap)), 0);
        ++calls[2];
    }

    function sellOutput(uint256 which, uint96 amount) external {
        which %= 2;
        (uint160 price,,,) = manager.getSlot0(keys[which].toId());
        uint256 balance = keys[which].currency1.balanceOf(address(this));
        // Limit output to half the token inventory's current ETH value, allowing input fee and price impact.
        uint256 ethValue = FullMath.mulDiv(FullMath.mulDiv(balance, 2 ** 96, price), 2 ** 96, price);
        uint256 cap = ethValue / 2;
        if (cap < 100) return;
        if (cap > 0.01 ether) cap = 0.01 ether;
        _swap(which, false, int256(bound(amount, 1, cap)), 0);
        ++calls[3];
    }

    function buyback(uint256 which) external {
        PoolKey memory pool = keys[which % 2];
        if (hook.accruedEth(pool.toId()) < 0.001 ether || hook.lastBuybackBlock(pool.toId()) == vm.getBlockNumber()) {
            return;
        }
        hook.buyback(pool);
        ++calls[4];
    }

    function nextBlock(uint8 blocks) external {
        vm.roll(vm.getBlockNumber() + uint256(blocks) + 1);
    }

    function _swap(uint256 which, bool direction, int256 amount, uint256 value) private {
        router.swap{value: value}(
            keys[which],
            SwapParams(direction, amount, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(hook))
        );
    }

    receive() external payable {}
}

contract BuybackInvariantTest is BaseHookTest {
    using TransientStateLibrary for IPoolManager;
    BuybackBurnHook private burner;
    BuybackHandler private handler;
    LaunchToken private second;
    PoolKey private secondKey;

    function setUp() public override {
        super.setUp();
        burner = BuybackBurnHook(address(hook));
        second = new LaunchToken();
        secondKey = key;
        secondKey.currency1 = Currency.wrap(address(second));
        second.approve(address(modifyLiquidityRouter), type(uint256).max);
        manager.initialize(secondKey, TickMath.getSqrtPriceAtTick(START_TICK));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), second.totalSupply()
        );
        modifyLiquidityRouter.modifyLiquidity(
            secondKey, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), 0), ""
        );
        handler = new BuybackHandler(manager, swapRouter, burner, key, secondKey);
        vm.deal(address(handler), 10_000 ether);
        // Establish both pools with inventories and accrued fees; buybacks are exercised before fuzzing too.
        handler.buyOutput(0, uint96(1_000_000 ether));
        handler.buyOutput(1, uint96(1_000_000 ether));
        handler.buyback(0);
        handler.buyback(1);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buyInput.selector;
        selectors[1] = handler.buyOutput.selector;
        selectors[2] = handler.sellInput.selector;
        selectors[3] = handler.sellOutput.selector;
        selectors[4] = handler.buyback.selector;
        selectors[5] = handler.nextBlock.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_claimsEqualSumOfPoolBudgetsAndAllDeltasSettle() public view {
        assertEq(
            manager.balanceOf(address(hook), 0), burner.accruedEth(key.toId()) + burner.accruedEth(secondKey.toId())
        );
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(address(hook).balance, 0);
        assertEq(address(swapRouter).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(second.balanceOf(address(hook)), 0);
    }

    function invariant_burnsMatchDeadBalancesAndTokensAreConserved() public view {
        address dead = 0x000000000000000000000000000000000000dEaD;
        assertEq(token.balanceOf(dead), burner.burnedTotal(key.toId()));
        assertEq(second.balanceOf(dead), burner.burnedTotal(secondKey.toId()));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(second.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(manager)) + token.balanceOf(address(handler)) + token.balanceOf(address(this))
                + token.balanceOf(dead),
            token.totalSupply()
        );
        assertEq(
            second.balanceOf(address(manager)) + second.balanceOf(address(handler)) + second.balanceOf(address(this))
                + second.balanceOf(dead),
            second.totalSupply()
        );
        assertEq(address(manager).balance + address(handler).balance, 10_000 ether);
    }
}

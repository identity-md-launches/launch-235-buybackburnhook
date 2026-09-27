// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHookTest} from "./BaseHookTest.sol";
import {BuybackBurnHook} from "../src/BuybackBurnHook.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

contract ReentrancyTest is BaseHookTest {
    using TransientStateLibrary for IPoolManager;
    BuybackBurnHook private burner;
    ReentrantToken private adversary;
    PoolKey private maliciousKey;
    PoolId private maliciousId;

    function setUp() public override {
        super.setUp();
        burner = BuybackBurnHook(address(hook));
        adversary = new ReentrantToken();
        maliciousKey = key;
        maliciousKey.currency1 = Currency.wrap(address(adversary));
        maliciousId = maliciousKey.toId();
        manager.initialize(maliciousKey, TickMath.getSqrtPriceAtTick(START_TICK));
        adversary.approve(address(modifyLiquidityRouter), type(uint256).max);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), adversary.totalSupply()
        );
        modifyLiquidityRouter.modifyLiquidity(
            maliciousKey, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), 0), ""
        );
        swapNativeInput(maliciousKey, true, 20_000_000 ether, "", 30 ether);
        adversary.configure(burner, maliciousKey, false);
    }

    function test_tokenTransferCannotReenterBuybackDuringFeeCallback() public {
        uint256 accrued = burner.accruedEth(maliciousId);
        swap(maliciousKey, true, -1 ether, "");
        assertEq(adversary.attempts(), 1);
        assertEq(adversary.rejection(), IPoolManager.AlreadyUnlocked.selector);
        assertEq(burner.lastBuybackBlock(maliciousId), 0);
        assertEq(burner.accruedEth(maliciousId), accrued);
        assertEq(manager.balanceOf(address(hook), 0), accrued);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_tokenTransferCannotReenterBuybackDuringBuyback() public {
        uint256 accrued = burner.accruedEth(maliciousId);
        burner.buyback(maliciousKey);
        assertEq(adversary.attempts(), 1);
        assertEq(adversary.rejection(), BuybackBurnHook.BuybackInProgress.selector);
        assertEq(burner.accruedEth(maliciousId), accrued - 0.05 ether);
        assertEq(manager.balanceOf(address(hook), 0), burner.accruedEth(maliciousId));
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_failedTokenTransferRollsBackClaimsCountersAndCooldown() public {
        adversary.configure(burner, maliciousKey, true);
        uint256 accrued = burner.accruedEth(maliciousId);
        uint256 reserves = adversary.balanceOf(address(manager));
        vm.expectRevert(); // PoolManager wraps the token's transfer failure.
        burner.buyback(maliciousKey);
        assertEq(burner.lastBuybackBlock(maliciousId), 0);
        assertEq(burner.burnedTotal(maliciousId), 0);
        assertEq(burner.accruedEth(maliciousId), accrued);
        assertEq(manager.balanceOf(address(hook), 0), accrued);
        assertEq(adversary.balanceOf(address(manager)), reserves);
        adversary.configure(burner, maliciousKey, false);
        burner.buyback(maliciousKey);
        assertEq(burner.accruedEth(maliciousId), accrued - 0.05 ether);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }
}

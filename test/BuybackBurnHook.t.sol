// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHookTest} from "./BaseHookTest.sol";
import {BuybackBurnHook} from "../src/BuybackBurnHook.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract BuybackBurnHookTest is BaseHookTest {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant BURN_EVENT = keccak256("FeeBurned(bytes32,uint256)");
    bytes32 internal constant ACCRUE_EVENT = keccak256("FeeAccrued(bytes32,uint256)");
    bytes32 internal constant BUYBACK_EVENT = keccak256("Buyback(bytes32,uint256,uint256)");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    BuybackBurnHook internal burner;
    PoolId internal id;

    struct Balances {
        uint256 eth;
        uint256 tokens;
        uint256 dead;
        uint256 claims;
        uint256 accrued;
        uint256 burned;
        uint256 managerEth;
        uint256 managerTokens;
    }

    function setUp() public virtual override {
        super.setUp();
        burner = BuybackBurnHook(address(hook));
        id = key.toId();
    }

    function test_exactInputBuyWorksAsFirstSwapWithNoEthInPool() public {
        assertEq(address(manager).balance, 0);
        assertApproxEqAbs(token.balanceOf(address(manager)), token.totalSupply(), 1000);
        assertEq(key.fee, 3000);
        _assertSwap(true, -1 ether, 1 ether, "");
        assertGt(token.balanceOf(DEAD), 0);
        assertEq(burner.accruedEth(id), 0);
    }

    function test_exactOutputBuyPaysOnePercentExtraEthAsClaims() public {
        assertEq(address(manager).balance, 0);
        _assertSwap(true, 100_000 ether, 1 ether, "");
        assertGt(burner.accruedEth(id), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_exactInputSellReceivesOnePercentLessEth() public {
        swap(key, true, -10 ether, "");
        _assertSwap(false, -100_000 ether, 0, "");
    }

    function test_exactOutputSellPaysOnePercentExtraTokensToDead() public {
        swap(key, true, -10 ether, "");
        _assertSwap(false, 0.1 ether, 0, "");
    }

    function testFuzz_allFourSwapTypes(uint8 kind, uint96 quantity) public {
        kind %= 4;
        if (kind == 0) {
            uint256 amount = bound(quantity, 1, 2 ether);
            _assertSwap(true, -int256(amount), amount, "");
        } else if (kind == 1) {
            _assertSwap(true, int256(bound(quantity, 1, 1_000_000 ether)), 2 ether, "");
        } else {
            swap(key, true, -20 ether, "");
            if (kind == 2) _assertSwap(false, -int256(bound(quantity, 1, 1_000_000 ether)), 0, "");
            else _assertSwap(false, int256(bound(quantity, 1, 1 ether)), 0, "");
        }
    }

    function test_dustRoundsEthFeeToZero() public {
        _assertSwap(true, 1, 1 ether, "");
        assertEq(burner.accruedEth(id), 0);
        swap(key, true, -1 ether, "");
        _assertSwap(false, -10_000_000, 0, "");
        assertEq(burner.accruedEth(id), 0);
    }

    function test_hookDataCannotImpersonateHookOrAvoidFee() public {
        _assertSwap(true, -1 ether, 1 ether, abi.encode(address(hook)));
        _assertSwap(true, 100_000 ether, 1 ether, hex"ff");
        _assertSwap(false, -100_000 ether, 0, abi.encode(address(hook), address(this)));
        _assertSwap(false, 0.01 ether, 0, abi.encode(address(swapRouter)));
    }

    function test_buybackBurnsOutputAndClaimsWithoutChargingItsOwnSwap() public {
        _accrueAboveCap();
        _assertBuyback(0.05 ether);
        assertGt(burner.accruedEth(id), 0.001 ether);
    }

    function test_buybackBelowCapSpendsOnlyAvailableClaims() public {
        swapNativeInput(key, true, 1_000_000 ether, "", 2 ether);
        uint256 budget = burner.accruedEth(id);
        assertGe(budget, 0.001 ether);
        assertLt(budget, 0.05 ether);
        _assertBuyback(budget);
        assertEq(burner.accruedEth(id), 0);
    }

    function test_buybackOnlyOncePerBlockAndWorksNextBlock() public {
        _accrueAboveCap();
        _assertBuyback(0.05 ether);
        vm.expectRevert(BuybackBurnHook.AlreadyBoughtBack.selector);
        burner.buyback(key);
        vm.roll(vm.getBlockNumber() + 1);
        _assertBuyback(0.05 ether);
    }

    function test_buybackRequiresThreshold() public {
        vm.expectRevert(BuybackBurnHook.BelowThreshold.selector);
        burner.buyback(key);
        swapNativeInput(key, true, 100 ether, "", 1 ether);
        assertGt(burner.accruedEth(id), 0);
        assertLt(burner.accruedEth(id), 0.001 ether);
        vm.expectRevert(BuybackBurnHook.BelowThreshold.selector);
        burner.buyback(key);
        assertEq(burner.lastBuybackBlock(id), 0);
        _assertSettled();
    }

    function test_invalidPoolKeysCannotSpendAnotherPoolsClaims() public {
        _accrueAboveCap();
        PoolKey memory wrong = key;
        wrong.hooks = IHooks(address(0));
        vm.expectRevert(BuybackBurnHook.InvalidPool.selector);
        burner.buyback(wrong);
        wrong = key;
        wrong.currency0 = Currency.wrap(address(1));
        vm.expectRevert(BuybackBurnHook.InvalidPool.selector);
        burner.buyback(wrong);
        wrong = key;
        wrong.fee = 500;
        vm.expectRevert(BuybackBurnHook.BelowThreshold.selector);
        burner.buyback(wrong);
        _assertSettled();
    }

    function test_afterSwapRejectsNonManagerEvenWithForgedSender() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(
            address(hook), key, SwapParams(true, -1 ether, MIN_PRICE_LIMIT), toBalanceDelta(-1 ether, 1 ether), ""
        );
    }

    function test_unlockCallbackRejectsNonManagerAndUnsolicitedManagerCall() public {
        bytes memory data = abi.encode(key, 0.05 ether);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        burner.unlockCallback(data);
        vm.prank(address(manager));
        vm.expectRevert(BuybackBurnHook.UnexpectedCallback.selector);
        burner.unlockCallback(data);
    }

    function test_buybackCannotNestInsideUnlockedManager() public {
        _accrueAboveCap();
        uint256 accrued = burner.accruedEth(id);
        manager.unlock("");
        assertEq(burner.accruedEth(id), accrued);
        assertEq(burner.lastBuybackBlock(id), 0);
        _assertBuyback(0.05 ether);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        burner.buyback(key);
        return "";
    }

    function test_noLiquidityBuybackRevertsAtomicallyAndCanRetry() public {
        _accrueAboveCap();
        (uint128 liquidity,,) = manager.getPositionInfo(id, address(modifyLiquidityRouter), tickLower, tickUpper, 0);
        ModifyLiquidityParams memory removal =
            ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(liquidity)), 0);
        modifyLiquidityRouter.modifyLiquidity(key, removal, "");
        Balances memory before = _balances();
        vm.expectRevert(BuybackBurnHook.InvalidBuybackDelta.selector);
        burner.buyback(key);
        assertEq(burner.accruedEth(id), before.accrued);
        assertEq(burner.burnedTotal(id), before.burned);
        assertEq(manager.balanceOf(address(hook), 0), before.claims);
        assertEq(burner.lastBuybackBlock(id), 0);
        removal.liquidityDelta = int256(uint256(liquidity));
        modifyLiquidityRouter.modifyLiquidity{value: 30 ether}(key, removal, "");
        _assertBuyback(0.05 ether);
    }

    function test_partialBuybackBurnsOnlyActuallySpentClaims() public {
        _accrueAboveCap();
        (uint128 liquidity,,) = manager.getPositionInfo(id, address(modifyLiquidityRouter), tickLower, tickUpper, 0);
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(liquidity)), 0), ""
        );
        (, int24 tick,,) = manager.getSlot0(id);
        int24 lower = (tick / 60 - 1) * 60;
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            key, ModifyLiquidityParams(lower, lower + 120, 1e8, 0), ""
        );
        uint256 before = burner.accruedEth(id);
        _assertBuyback(type(uint256).max);
        uint256 spent = before - burner.accruedEth(id);
        assertGt(spent, 0);
        assertLt(spent, 0.05 ether, "liquidity must exhaust before the cap");
        assertGt(burner.accruedEth(id), 0.001 ether, "unspent claims remain available");
    }

    function test_unsolicitedClaimsAreSurplusAndCannotCreatePoolBudget() public {
        claimsRouter.deposit{value: 1 ether}(key.currency0, address(hook), 1 ether);
        assertEq(manager.balanceOf(address(hook), 0), 1 ether);
        assertEq(burner.accruedEth(id), 0);
        vm.expectRevert(BuybackBurnHook.BelowThreshold.selector);
        burner.buyback(key);
    }

    function test_adversePriceMovementReducesBurnButSpendRemainsCapped() public {
        _accrueAboveCap();
        uint256 snapshot = vm.snapshotState();
        burner.buyback(key);
        uint256 undisturbedBurn = burner.burnedTotal(id);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        address attacker = address(0xA77AC);
        vm.deal(attacker, 100 ether);
        vm.startPrank(attacker);
        BalanceDelta front = swapRouter.swap{value: 100 ether}(
            key, SwapParams(true, -100 ether, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 burnedBefore = burner.burnedTotal(id);
        uint256 accruedBefore = burner.accruedEth(id);
        burner.buyback(key);
        uint256 disturbedBurn = burner.burnedTotal(id) - burnedBefore;
        assertGt(disturbedBurn, 0);
        assertLt(disturbedBurn, undisturbedBurn, "no output price guarantee");
        assertEq(accruedBefore - burner.accruedEth(id), 0.05 ether);
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams(false, -int256(front.amount1()), MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        _assertSettled();
    }

    function test_runtimeHasNoUpgradeOrDestructionOpcodes() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function test_permissionsAndAddressHaveExactlyRequiredFlags() public view {
        assertEq(flagsOf(hook.getHookPermissions()), 0x0044);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x0044);
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_constructorRejectsInvalidAddressAndCreate2AcceptsMinedAddress() public {
        bytes memory code = abi.encodePacked(type(BuybackBurnHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(code);
        bytes32 goodSalt;
        bytes32 badSalt;
        bool found;
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == 0x0044) {
                goodSalt = salt;
                found = true;
                break;
            }
            badSalt = salt;
        }
        assertTrue(found, "salt search exhausted");
        address invalidDeployment;
        assembly ("memory-safe") { invalidDeployment := create2(0, add(code, 32), mload(code), badSalt) }
        assertEq(invalidDeployment, address(0), "constructor accepted wrong address flags");
        BuybackBurnHook deployed = new BuybackBurnHook{salt: goodSalt}(manager);
        assertEq(uint160(address(deployed)) & Hooks.ALL_HOOK_MASK, 0x0044);
        assertEq(flagsOf(deployed.getHookPermissions()), 0x0044);
    }

    function _accrueAboveCap() internal {
        swapNativeInput(key, true, 20_000_000 ether, "", 30 ether);
        assertGt(burner.accruedEth(id), 0.1 ether);
    }

    function _balances() internal view returns (Balances memory b) {
        b = Balances(
            address(this).balance,
            token.balanceOf(address(this)),
            token.balanceOf(DEAD),
            manager.balanceOf(address(hook), 0),
            burner.accruedEth(id),
            burner.burnedTotal(id),
            address(manager).balance,
            token.balanceOf(address(manager))
        );
    }

    function _assertSwap(bool zeroForOne, int256 specified, uint256 value, bytes memory data) internal {
        Balances memory before = _balances();
        vm.recordLogs();
        BalanceDelta actual = swapNativeInput(key, zeroForOne, specified, data, value);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BalanceDelta raw = _rawSwap(logs, address(swapRouter));
        bool tokenFee = (specified < 0) == zeroForOne;
        int256 unspecified = tokenFee ? int256(raw.amount1()) : int256(raw.amount0());
        uint256 fee = uint256(unspecified < 0 ? -unspecified : unspecified) / 100;
        assertEq(int256(actual.amount0()), int256(raw.amount0()) - (tokenFee ? int256(0) : int256(fee)));
        assertEq(int256(actual.amount1()), int256(raw.amount1()) - (tokenFee ? int256(fee) : int256(0)));
        assertEq(int256(address(this).balance) - int256(before.eth), int256(actual.amount0()), "wallet ETH");
        assertEq(
            int256(token.balanceOf(address(this))) - int256(before.tokens), int256(actual.amount1()), "wallet token"
        );
        assertEq(burner.burnedTotal(id) - before.burned, tokenFee ? fee : 0);
        assertEq(token.balanceOf(DEAD) - before.dead, tokenFee ? fee : 0);
        assertEq(burner.accruedEth(id) - before.accrued, tokenFee ? 0 : fee);
        assertEq(manager.balanceOf(address(hook), 0) - before.claims, tokenFee ? 0 : fee);
        assertEq(int256(address(manager).balance) - int256(before.managerEth), -int256(actual.amount0()));
        assertEq(
            int256(token.balanceOf(address(manager))) - int256(before.managerTokens),
            -int256(actual.amount1()) - (tokenFee ? int256(fee) : int256(0))
        );
        _assertFeeEvents(logs, tokenFee ? BURN_EVENT : ACCRUE_EVENT, fee);
        _assertSettled();
    }

    function _rawSwap(Vm.Log[] memory logs, address expectedSender) internal view returns (BalanceDelta raw) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedSender);
                (int128 a0, int128 a1,,,, uint24 lpFee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(lpFee, 3000, "LP fee remains separate");
                raw = toBalanceDelta(a0, a1);
                ++count;
            }
        }
        assertEq(count, 1, "must execute one real swap");
    }

    function _assertFeeEvents(Vm.Log[] memory logs, bytes32 expected, uint256 fee) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook)
                    && (logs[i].topics[0] == BURN_EVENT || logs[i].topics[0] == ACCRUE_EVENT)
            ) {
                assertEq(logs[i].topics[0], expected);
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                assertEq(abi.decode(logs[i].data, (uint256)), fee);
                ++count;
            }
        }
        assertEq(count, fee == 0 ? 0 : 1);
    }

    function _assertBuyback(uint256 expectedSpent) internal {
        Balances memory before = _balances();
        vm.recordLogs();
        vm.prank(address(0xB0B)); // No approvals or privileged caller required.
        burner.buyback(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BalanceDelta raw = _rawSwap(logs, address(hook));
        uint256 output = uint256(int256(raw.amount1()));
        if (expectedSpent == type(uint256).max) expectedSpent = uint256(-int256(raw.amount0()));
        assertEq(uint256(-int256(raw.amount0())), expectedSpent);
        assertGt(output, 0);
        assertEq(before.accrued - burner.accruedEth(id), expectedSpent);
        assertEq(before.claims - manager.balanceOf(address(hook), 0), expectedSpent);
        assertEq(token.balanceOf(DEAD) - before.dead, output);
        assertEq(burner.burnedTotal(id) - before.burned, output);
        assertEq(address(manager).balance, before.managerEth, "claims settled without sending ETH");
        assertEq(token.balanceOf(address(manager)), before.managerTokens - output);
        assertEq(address(this).balance, before.eth);
        assertEq(token.balanceOf(address(this)), before.tokens);
        assertEq(burner.lastBuybackBlock(id), vm.getBlockNumber());
        _assertFeeEvents(logs, BURN_EVENT, 0);
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == BUYBACK_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                (uint256 spent, uint256 burned) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(spent, expectedSpent);
                assertEq(burned, output);
                ++events;
            }
        }
        assertEq(events, 1);
        _assertSettled();
    }

    function _assertSettled() internal view {
        assertEq(manager.balanceOf(address(hook), 0), burner.accruedEth(id));
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(swapRouter), key.currency0), 0);
        assertEq(manager.currencyDelta(address(swapRouter), key.currency1), 0);
        assertFalse(manager.isUnlocked());
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}

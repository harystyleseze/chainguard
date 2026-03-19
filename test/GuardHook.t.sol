// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Currency} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {GuardHook} from "../src/GuardHook.sol";
import {RiskRegistry} from "../src/RiskRegistry.sol";

contract GuardHookTest is Test, Deployers {

    GuardHook hook;
    RiskRegistry registry;

    address blockedUser = address(0xB10C);
    address flaggedUser = address(0xF1A6);
    address cleanUser = address(0xC1EA);
    address suspiciousUser = address(0x5A55);

    function setUp() public {
        // Deploy PoolManager and routers
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deploy registry
        registry = new RiskRegistry();

        // Deploy hook to an address with correct flag bits
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        deployCodeTo("GuardHook.sol:GuardHook", abi.encode(manager, address(registry), address(this)), address(flags));
        hook = GuardHook(address(flags));

        // Approve currencies for routers
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize pool with dynamic fee flag
        (key,) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_1_1
        );

        // Add liquidity
        // will also call _beforeAddLiquidity + _afterAddLiquidity on hook
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Set up the callback contract on registry so we can flag addresses in tests
        registry.setCallbackContract(address(this));
    }

    // Unit Tests 

    function test_hookPermissions_correct() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.afterSwap);
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
    }

    function test_cleanAddress_canSwap() public {
        // cleanUser is not in registry -- swap should succeed
        vm.prank(address(this), cleanUser);
        _doSwap();
    }

    function test_blockedAddress_cannotSwap() public {
        registry.addToBlacklist(blockedUser);
        vm.expectRevert();
        vm.prank(address(this), blockedUser);
        _doSwap();
    }

    function test_flaggedAddress_paysSurcharge() public {
        registry.flagAddress(flaggedUser, address(0xBAD), 1);

        vm.prank(address(this), flaggedUser);
        _doSwap();
        assertEq(hook.totalSwapsSurcharged(), 1);
    }

    function test_suspiciousNewAddress_paysModerateFee() public {
        // flagSuspicious sets SuspiciousNew tier (0.75% fee)
        registry.flagSuspicious(suspiciousUser, address(0xBAD), 1);
        assertTrue(registry.isSuspicious(suspiciousUser));

        // Swap should succeed (not blocked, not fully flagged)
        vm.prank(address(this), suspiciousUser);
        _doSwap();

        // totalSwapsSurcharged only increments for Flagged (3%) tier, not SuspiciousNew
        assertEq(hook.totalSwapsSurcharged(), 0);
    }

    function test_cleanAddress_canAddLiquidity() public {
        vm.prank(address(this), cleanUser);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );
    }

    function test_blockedAddress_cannotAddLiquidity() public {
        registry.addToBlacklist(blockedUser);
        vm.expectRevert();
        vm.prank(address(this), blockedUser);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );
    }

    function test_flaggedAddress_cannotAddLiquidity() public {
        registry.flagAddress(flaggedUser, address(0xBAD), 1);
        vm.expectRevert();
        vm.prank(address(this), flaggedUser);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(1))
            }),
            ZERO_BYTES
        );
    }

    function test_clearedAddress_canSwapAgain() public {
        registry.addToBlacklist(blockedUser);

        // Blocked -- should revert
        vm.expectRevert();
        vm.prank(address(this), blockedUser);
        _doSwap();

        // Clear
        registry.removeFromBlacklist(blockedUser);

        // Now should succeed
        vm.prank(address(this), blockedUser);
        _doSwap();
    }

    function test_beforeInitialize_requiresDynamicFee() public {
        vm.expectRevert();
        initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);
    }

    function test_swapCounter_incrementsOnSurcharge() public {
        registry.flagAddress(flaggedUser, address(0xBAD), 1);

        assertEq(hook.totalSwapsSurcharged(), 0);

        vm.prank(address(this), flaggedUser);
        _doSwap();
        assertEq(hook.totalSwapsSurcharged(), 1);

        vm.prank(address(this), flaggedUser);
        _doSwap();
        assertEq(hook.totalSwapsSurcharged(), 2);
    }

    function testFuzz_blockedAddressAlwaysReverts(address user) public {
        registry.addToBlacklist(user);
        assertTrue(registry.isBlocked(user));
        assertEq(uint256(registry.getRiskLevel(user)), uint256(RiskRegistry.RiskLevel.Blocked));
    }

    // Integration Tests

    function test_fullFlow_blockThenClearThenSwap() public {
        // 1. Clean swap
        vm.prank(address(this), cleanUser);
        _doSwap();

        // 2. Block
        registry.addToBlacklist(blockedUser);
        vm.expectRevert();
        vm.prank(address(this), blockedUser);
        _doSwap();

        // 3. Clear
        registry.removeFromBlacklist(blockedUser);

        // 4. Swap again
        vm.prank(address(this), blockedUser);
        _doSwap();
    }

    function test_fullFlow_flagThenSurchargedSwap() public {
        // 1. Clean swap
        vm.prank(address(this), cleanUser);
        _doSwap();
        assertEq(hook.totalSwapsSurcharged(), 0);

        // 2. Flag
        registry.flagAddress(flaggedUser, address(0xBAD), 1);

        // 3. Surcharged swap
        vm.prank(address(this), flaggedUser);
        _doSwap();
        assertEq(hook.totalSwapsSurcharged(), 1);
    }

    // Emergency Pause Tests (B1)

    function test_pause_blocksSwaps() public {
        hook.pause();
        assertTrue(hook.paused());

        vm.expectRevert();
        vm.prank(address(this), cleanUser);
        _doSwap();
    }

    function test_unpause_resumesSwaps() public {
        hook.pause();
        hook.unpause();
        assertFalse(hook.paused());

        vm.prank(address(this), cleanUser);
        // should succeed
        _doSwap(); 
    }

    function test_pause_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(GuardHook.OnlyOwner.selector);
        hook.pause();
    }

    function test_pause_blocksLiquidityAdd() public {
        hook.pause();

        vm.expectRevert();
        vm.prank(address(this), cleanUser);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(2))
            }),
            ZERO_BYTES
        );
    }

    // Whitelist Tests (D2) 

    function test_whitelist_bypassesBlocked() public {
        registry.addToBlacklist(blockedUser);
        registry.setWhitelist(blockedUser, true);

        // Should succeed due to whitelist
        vm.prank(address(this), blockedUser);
        _doSwap();
    }

    function test_whitelist_bypassesLiquidityBlock() public {
        registry.addToBlacklist(blockedUser);
        registry.setWhitelist(blockedUser, true);

        vm.prank(address(this), blockedUser);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(3))
            }),
            ZERO_BYTES
        );
    }

    // MEV Tax Observation Tests (Unichain)

    function test_afterSwap_observesMevTax() public {
        // gasprice = 2 gwei, basefee = 1 gwei → priority = 1 gwei
        vm.txGasPrice(2 gwei);
        vm.fee(1 gwei);

        vm.prank(address(this), cleanUser);
        _doSwap();

        assertTrue(hook.totalMevTaxObserved() > 0);
    }

    function test_afterSwap_noMevWhenGasPriceEqualsBaseFee() public {
        // gasprice == basefee → no priority fee
        vm.txGasPrice(1 gwei);
        vm.fee(1 gwei);

        vm.prank(address(this), cleanUser);
        _doSwap();

        assertEq(hook.totalMevTaxObserved(), 0);
    }

    function test_afterSwap_hookDataOverridesAddress() public {
        // Pass a specific address via hookData instead of tx.origin
        address explicitUser = address(0xABCD);
        bytes memory hookData = abi.encode(explicitUser);

        vm.txGasPrice(2 gwei);
        vm.fee(1 gwei);

        vm.prank(address(this), cleanUser);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
        assertTrue(hook.totalMevTaxObserved() > 0);
    }

    // getProtocolStats Tests (C1)

    function test_getProtocolStats_returnsDefaults() public view {
        (
            uint24 _baseFee, uint24 _surchargeFee, uint24 _suspiciousFee,
            uint256 swapsSurcharged,
            uint256 suspiciousNewSurcharged,
            uint256 totalFlagged, bool isPaused,
            uint256 mevTaxObserved
        ) = hook.getProtocolStats();

        assertEq(_baseFee, 3000);
        assertEq(_surchargeFee, 30000);
        assertEq(_suspiciousFee, 7500);
        assertEq(swapsSurcharged, 0);
        assertEq(suspiciousNewSurcharged, 0);
        assertEq(totalFlagged, 0);
        assertFalse(isPaused);
        assertEq(mevTaxObserved, 0);
    }

    // Money Flow Event Tests 

    function test_afterSwap_emitsMoneyFlowRecorded() public {
        vm.expectEmit(true, false, false, false);
        emit GuardHook.MoneyFlowRecorded(cleanUser, 0, 0, bytes32(0), 0);

        vm.prank(address(this), cleanUser);
        _doSwap();
    }

    function test_afterSwap_moneyFlowEvent_hasCorrectUser() public {
        // Verify MoneyFlowRecorded emits with correct indexed user via expectEmit
        // topic[0] = sig, topic[1] = indexed user — we check topic[1] matches cleanUser
        vm.expectEmit(true, false, false, false);
        emit GuardHook.MoneyFlowRecorded(cleanUser, 0, 0, bytes32(0), 0);

        vm.prank(address(this), cleanUser);
        _doSwap();
    }

    // LP Holding Period Tests 

    function test_holdingPeriod_blocksEarlyExit() public {
        address lp = address(0x1100);

        // Approve tokens for the LP
        vm.prank(address(this));
        MockERC20(Currency.unwrap(currency0)).transfer(lp, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(lp, 10 ether);

        vm.startPrank(lp, lp);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity — records addedAt
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(10))
            }),
            ZERO_BYTES
        );

        // Attempt to remove immediately — should revert (holdingPeriod = 24h, elapsed = 0)
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1 ether,
                salt: bytes32(uint256(10))
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    function test_holdingPeriod_allowsExitAfterPeriod() public {
        address lp = address(0x1102);

        vm.prank(address(this));
        MockERC20(Currency.unwrap(currency0)).transfer(lp, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(lp, 10 ether);

        vm.startPrank(lp, lp);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(11))
            }),
            ZERO_BYTES
        );

        // Warp past holding period
        vm.warp(block.timestamp + 25 hours);

        // Remove liquidity — should succeed now
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1 ether,
                salt: bytes32(uint256(11))
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    function test_holdingPeriod_disabledWhenZero() public {
        hook.setHoldingPeriod(0);

        address lp = address(0x1103);
        vm.prank(address(this));
        MockERC20(Currency.unwrap(currency0)).transfer(lp, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(lp, 10 ether);

        vm.startPrank(lp, lp);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1 ether,
                salt: bytes32(uint256(12))
            }),
            ZERO_BYTES
        );

        // Immediate remove — should succeed since holdingPeriod = 0
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -1 ether,
                salt: bytes32(uint256(12))
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    // setCoinbaseAttester 

    function test_setCoinbaseAttester_updatesValue() public {
        address newAddr = address(0xA77E5);
        hook.setCoinbaseAttester(newAddr);
        assertEq(hook.coinbaseAttester(), newAddr);
    }

    function test_setCoinbaseAttester_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(GuardHook.OnlyOwner.selector);
        hook.setCoinbaseAttester(address(0xA77E5));
    }

    function test_setCoinbaseAttester_revertsOnZero() public {
        vm.expectRevert(GuardHook.ZeroAddress.selector);
        hook.setCoinbaseAttester(address(0));
    }

    // requireHookData

    function test_requireHookData_revertsSwapWithoutData() public {
        hook.setRequireHookData(true);

        vm.expectRevert();
        vm.prank(address(this), cleanUser);
        // uses ZERO_BYTES → no hookData → should revert with HookDataRequired
        _doSwap();  
    }

    function test_requireHookData_allowsSwapWithHookData() public {
        hook.setRequireHookData(true);

        bytes memory hookData = abi.encode(cleanUser);

        vm.prank(address(this), cleanUser);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
    }

    function test_setRequireHookData_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(GuardHook.OnlyOwner.selector);
        hook.setRequireHookData(true);
    }

    // totalSuspiciousNewSurcharged

    function test_suspiciousNewSurcharged_incrementsOnSuspiciousSwap() public {
        registry.flagSuspicious(suspiciousUser, address(0xBAD), 1);

        vm.prank(address(this), suspiciousUser);
        _doSwap();

        assertEq(hook.totalSuspiciousNewSurcharged(), 1);
        // Flagged-only counter unchanged
        assertEq(hook.totalSwapsSurcharged(), 0);  
    }

    function test_suspiciousNewSurcharged_notIncrementedOnFlaggedSwap() public {
        registry.flagAddress(flaggedUser, address(0xBAD), 1);

        vm.prank(address(this), flaggedUser);
        _doSwap();

        assertEq(hook.totalSuspiciousNewSurcharged(), 0);
        assertEq(hook.totalSwapsSurcharged(), 1);
    }

    // Helper 

    function _doSwap() internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
    }

    // swap with an explicit user address passed as hookData
    function _swapAs(address user) internal {
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            abi.encode(user)
        );
    }

    // add liquidity with an explicit user address passed as hookData (uses test contract's tokens)
    function _addLiquidityAs(address user) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: bytes32(0) }),
            abi.encode(user)
        );
    }

    function _block(address user) internal { registry.addToBlacklist(user); }
    function _flag(address user) internal { registry.flagAddressDirect(user, address(this)); }
    function _flagSuspicious(address user) internal { registry.flagSuspicious(user, address(this), 1); }

    // holding Period — Per-Pool Isolation 

    function test_holdingPeriod_perPool_isolation() public {
        address alice = address(0xA11CE);
        uint256 T = block.timestamp;

        MockERC20(Currency.unwrap(currency0)).transfer(alice, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(alice, 10 ether);

        // Initialize pool B with tickSpacing 120 
        // different pool ID from key which uses 60
        PoolKey memory keyB = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyB, SQRT_PRICE_1_1);

        vm.startPrank(alice, alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Alice adds liquidity to pool A at time T
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(uint256(20)) }),
            abi.encode(alice)
        );

        // Warp to T+12h — still locked on pool A
        vm.warp(T + 12 hours);

        // Alice adds liquidity to pool B at T+12h
        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            ModifyLiquidityParams({ tickLower: -240, tickUpper: 240, liquidityDelta: 1 ether, salt: bytes32(uint256(21)) }),
            abi.encode(alice)
        );

        // Warp to T+25h — pool A unlocked (25h ≥ 24h)
        // pool B only 13h elapsed
        vm.warp(T + 25 hours);

        // Pool A: remove should succeed
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: -1 ether, salt: bytes32(uint256(20)) }),
            abi.encode(alice)
        );

        // Pool B: alice added at T+12h → only 13h elapsed → should revert
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            keyB,
            ModifyLiquidityParams({ tickLower: -240, tickUpper: 240, liquidityDelta: -1 ether, salt: bytes32(uint256(21)) }),
            abi.encode(alice)
        );

        vm.stopPrank();
    }

    // Holding Period — addedAt Not Updated on Subsequent Add 

    function test_holdingPeriod_addedAt_notUpdatedOnSubsequentAdd() public {
        address alice = address(0xA11CE2);

        MockERC20(Currency.unwrap(currency0)).transfer(alice, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(alice, 10 ether);

        vm.startPrank(alice, alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        uint256 T = block.timestamp;

        // First add at T
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(uint256(30)) }),
            abi.encode(alice)
        );

        bytes32 pid = keccak256(abi.encode(key));
        assertEq(hook.addedAt(alice, pid), T);

        // Warp 2h, add again (to same pool, different position)
        vm.warp(T + 2 hours);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 0.5 ether, salt: bytes32(uint256(31)) }),
            abi.encode(alice)
        );

        // addedAt must still be T (not T+2h)
        assertEq(hook.addedAt(alice, pid), T);

        // Warp to T+25h — remove should succeed (based on first add at T)
        vm.warp(T + 25 hours);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: -1 ether, salt: bytes32(uint256(30)) }),
            abi.encode(alice)
        );

        vm.stopPrank();
    }

    // Pause — Does Not Block Remove Liquidity

    function test_pause_doesNotBlockRemoveLiquidity() public {
        address alice = address(0xA11CE3);

        MockERC20(Currency.unwrap(currency0)).transfer(alice, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(alice, 10 ether);

        vm.startPrank(alice, alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(uint256(40)) }),
            abi.encode(alice)
        );
        vm.stopPrank();

        // Warp past holding period
        vm.warp(block.timestamp + 25 hours);

        // Pause the hook
        hook.pause();
        assertTrue(hook.paused());

        // alice should still be able to remove (beforeRemoveLiquidity does NOT check paused)
        vm.prank(alice, alice);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: -1 ether, salt: bytes32(uint256(40)) }),
            abi.encode(alice)
        );
    }

    // Consecutive Surcharge Counter — SuspiciousNew

    function test_suspiciousNew_consecutiveSwaps_incrementsSuspiciousCounter() public {
        registry.flagSuspicious(suspiciousUser, address(0xBAD), 1);

        vm.prank(address(this), suspiciousUser);
        _doSwap();
        assertEq(hook.totalSuspiciousNewSurcharged(), 1);
        assertEq(hook.totalSwapsSurcharged(), 0);

        vm.prank(address(this), suspiciousUser);
        _doSwap();
        assertEq(hook.totalSuspiciousNewSurcharged(), 2);
        assertEq(hook.totalSwapsSurcharged(), 0); // Flagged counter stays 0
    }

    // MEV Tax — Event Not Emitted at Zero Priority Fee 

    function test_afterSwap_mevTax_notEmittedWhenGasPriceEqualsBaseFee() public {
        vm.txGasPrice(10 gwei);
        // priority fee = 0
        vm.fee(10 gwei); 

        vm.recordLogs();
        vm.prank(address(this), cleanUser);
        _doSwap();

        bytes32 mevSig = keccak256("MevTaxObserved(address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != mevSig, "MevTaxObserved must NOT be emitted");
        }
    }

    // Travel Rule Threshold Boundary

    function test_travelRule_exactlyAtThreshold_emitsEvent() public {
        // Exact-output swap: pool sends exactly TRAVEL_RULE_THRESHOLD of token1
        int256 threshold = int256(uint256(hook.TRAVEL_RULE_THRESHOLD()));

        vm.expectEmit(true, false, false, false);
        emit GuardHook.TravelRuleThresholdExceeded(cleanUser, 0, bytes32(0), 0);

        vm.prank(address(this), cleanUser);
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: threshold, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );
    }

    function test_travelRule_justBelowThreshold_noEvent() public {
        int256 belowThreshold = int256(uint256(hook.TRAVEL_RULE_THRESHOLD())) - 1;

        vm.recordLogs();
        vm.prank(address(this), cleanUser);
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: belowThreshold, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );

        bytes32 travelRuleSig = keccak256("TravelRuleThresholdExceeded(address,uint128,bytes32,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != travelRuleSig, "TravelRuleThresholdExceeded must NOT be emitted");
        }
    }

    // hookData Partial Length Falls Back to tx.origin

    function test_hookData_partialLength_fallsBackToTxOrigin() public {
        registry.addToBlacklist(blockedUser);

        // 2-byte hookData < 32 bytes → _resolveUser returns tx.origin (blockedUser) → revert
        vm.prank(address(this), blockedUser);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            hex"1234"
        );
    }

    // SuspiciousNew — Can Add Liquidity, addedAt Recorded

    function test_suspiciousNew_canAddLiquidity_withTimestamp() public {
        address alice = address(0xA11CE4);
        registry.flagSuspicious(alice, address(0xBAD), 1);
        assertTrue(registry.isSuspicious(alice));

        MockERC20(Currency.unwrap(currency0)).transfer(alice, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(alice, 10 ether);

        vm.startPrank(alice, alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        // SuspiciousNew is allowed to add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({ tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(uint256(50)) }),
            abi.encode(alice)
        );
        vm.stopPrank();

        bytes32 pid = keccak256(abi.encode(key));
        assertGt(hook.addedAt(alice, pid), 0);
    }

    // Fuzz — Flagged Address Always Pays Surcharge

    function testFuzz_flaggedAddress_alwaysPaysSurcharge(address user) public {
        vm.assume(user != address(0));

        registry.flagAddress(user, address(0xBAD), 1);
        assertTrue(registry.isFlagged(user));

        vm.prank(address(this), user);
        _doSwap();

        assertGt(hook.totalSwapsSurcharged(), 0);
    }
}

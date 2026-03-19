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
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {GuardHook} from "../src/GuardHook.sol";
import {RiskRegistry} from "../src/RiskRegistry.sol";
import {GuardCallback} from "../src/GuardCallback.sol";
import {GuardReactive} from "../src/GuardReactive.sol";

// ---------------------------------------------------------------------------
// Harness — identical to the one in GuardReactive.t.sol
// Forces vm=true so react() works in the test environment
// no Reactive Network needed
// ---------------------------------------------------------------------------
contract GuardReactiveHarness is GuardReactive {
    constructor(
        address[] memory _initialBlacklist,
        address _callbackContract,
        uint256 _originChainId,
        uint256 _destChainId,
        address _usdcAddress
    )
        GuardReactive(_initialBlacklist, _callbackContract, _originChainId, _destChainId, _usdcAddress)
    {
        vm = true;
    }

    function reactTest(
        uint256 chainId,
        address contractAddr,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        bytes memory data
    ) external {
        LogRecord memory log = LogRecord({
            chain_id: chainId,
            _contract: contractAddr,
            topic_0: topic0,
            topic_1: topic1,
            topic_2: topic2,
            topic_3: 0,
            data: data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
        this.react(log);
    }
}

// ---------------------------------------------------------------------------
// ChainGuardUserJourneysTest
//
// 15 end-to-end user journey tests that prove the full architecture works as an
// integrated system: Reactive Network detection → cross-chain callback →
// RiskRegistry state update → GuardHook enforcement.
//
// Design notes:
//  - GuardCallback is deployed with msg.sender = test contract, so
//    rvm_id = address(this). Calling callback.f(address(this), ...) satisfies
//    rvmIdOnly and correctly simulates the Reactive Network injecting the RVM ID.
//  - Swap "as alice" means vm.prank(address(this), alice) so tx.origin = alice.
//    The test contract (which holds the tokens) executes the swap, but GuardHook
//    reads tx.origin as the effective user.
//  - LP operations by named users: vm.startPrank(user, user) + user's own tokens.
// ---------------------------------------------------------------------------
contract ChainGuardUserJourneysTest is Test, Deployers {
    GuardHook hook;
    RiskRegistry registry;
    // rvm_id = address(this) — simulates Reactive Network relay
    GuardCallback callback;       
    GuardReactiveHarness reactive;

    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address carol   = address(0xCA201);
    address mallory = address(0xBAD);
    address lp1     = address(0x11111111);

    uint256 constant ETH_CHAIN_ID = 1;
    address constant USDC_ETHEREUM      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINALYSIS_ORACLE = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;
    address constant CALLBACK_PROXY     = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    uint256 constant TRANSFER_TOPIC_0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint256 constant USDC_BLACKLISTED_TOPIC_0 =
        0xffa4e6181777692565cf28528fc88fd1516ea86b56da075235fa575af6a4b855;
    uint256 constant SANCTIONED_ADDED_TOPIC_0 =
        uint256(keccak256("SanctionedAddressesAdded(address[])"));

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        registry = new RiskRegistry();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG    |
            Hooks.BEFORE_SWAP_FLAG          |
            Hooks.AFTER_SWAP_FLAG           |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG  |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        deployCodeTo("GuardHook.sol:GuardHook", abi.encode(manager, address(registry), address(this)), address(flags));
        hook = GuardHook(address(flags));

        // GuardCallback: rvm_id = msg.sender = address(this)
        callback = new GuardCallback(CALLBACK_PROXY, address(registry));
        registry.setCallbackContract(address(callback));

        // GuardReactive: mallory pre-seeded in reactive blacklist (mirrors OFAC list)
        address[] memory initial = new address[](1);
        initial[0] = mallory;
        reactive = new GuardReactiveHarness(initial, address(callback), ETH_CHAIN_ID, 130, USDC_ETHEREUM);

        // Approve test-contract tokens to routers (used for _swapAs pattern)
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);

        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        // Seed pool with liquidity so swaps have enough depth
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    // fund `user` and approve both routers from that address.
    function _fundAndApprove(address user) internal {
        MockERC20(Currency.unwrap(currency0)).transfer(user, 10 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(user, 10 ether);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();
    }

    // swap using test-contract tokens with tx.origin = user.
    // GuardHook reads tx.origin as the effective swapper.
    function _swapAs(address user) internal {
        vm.prank(address(this), user);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // add 1 ether liquidity as user (user pays from their own tokens).
    function _addLiqAs(address user, bytes32 salt) internal {
        vm.startPrank(user, user);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: salt}),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    // remove 1 ether liquidity as user.
    function _removeLiqAs(address user, bytes32 salt) internal {
        vm.startPrank(user, user);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1 ether, salt: salt}),
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    // flag target as SuspiciousNew through the callback (mirrors Reactive relay path).
    function _flagSuspicious(address target, address source) internal {
        callback.flagSuspicious(address(this), target, source, ETH_CHAIN_ID);
    }

    // escalate target to Flagged through the callback.
    function _flagAddress(address target, address source) internal {
        callback.flagAddress(address(this), target, source, ETH_CHAIN_ID);
    }

    // =======================================================================
    // Journey 1 — Clean User Swaps at Base Fee
    //
    // A fresh, unregistered address can swap at the 0.30% base fee.
    // MoneyFlowRecorded is emitted; no surcharge counters increment.
    // =======================================================================
    function test_journey_cleanUserSwap() public {
        vm.expectEmit(true, false, false, false);
        emit GuardHook.MoneyFlowRecorded(alice, 0, 0, bytes32(0), 0);

        _swapAs(alice);

        assertEq(hook.totalSwapsSurcharged(), 0);
        assertEq(hook.totalSuspiciousNewSurcharged(), 0);
        assertEq(hook.totalMevTaxObserved(), 0);
    }

    // =======================================================================
    // Journey 2 — Owner Seeds Blacklist, Blocked User Reverts
    //
    // Owner blocks mallory. Swap and LP add both revert.
    // After removal, mallory swaps successfully.
    // =======================================================================
    function test_journey_blockedUserCannotSwap() public {
        registry.addToBlacklist(mallory);
        assertTrue(registry.isBlocked(mallory));
        assertEq(registry.totalBlocked(), 1);

        // Blocked swap reverts (WrappedError from router — use bare expectRevert)
        vm.expectRevert();
        _swapAs(mallory);

        // Blocked LP add reverts
        _fundAndApprove(mallory);
        vm.expectRevert();
        _addLiqAs(mallory, bytes32(uint256(100)));

        // Remove from blacklist
        registry.removeFromBlacklist(mallory);
        assertEq(registry.totalBlocked(), 0);

        // Now clean — swap at base fee
        _swapAs(mallory);
        assertEq(hook.totalSwapsSurcharged(), 0);
    }

    // =======================================================================
    // Journey 3 — USDC Taint Propagation: Full Cross-Chain Reactive Flow
    //
    // mallory (pre-seeded in reactive blacklist) sends USDC to alice on Ethereum.
    // Step 1: GuardReactive detects the Transfer and flags alice locally.
    // Step 2: GuardCallback relays the flag to RiskRegistry → alice = SuspiciousNew.
    // Step 3: GuardHook enforces 0.75% surcharge on alice's next swap.
    // =======================================================================
    function test_journey_usdcTaintPropagation() public {
        // Step 1 — Reactive Network detects mallory→alice transfer on Ethereum
        vm.expectEmit(true, true, false, false);
        emit GuardReactive.BlacklistUpdated(alice, true);

        vm.expectEmit(true, true, false, false);
        emit GuardReactive.TaintPropagated(mallory, alice, ETH_CHAIN_ID);

        reactive.reactTest(
            ETH_CHAIN_ID, USDC_ETHEREUM, TRANSFER_TOPIC_0,
            uint256(uint160(mallory)), uint256(uint160(alice)),
            abi.encode(uint256(1000e6))
        );
        assertTrue(reactive.blacklist(alice));

        // Step 2 — Reactive Network delivers callback to Unichain
        // Event emission order: registry.AddressFlaggedSuspicious first, then callback.AddressSuspiciousFlagRelayed
        vm.expectEmit(true, true, false, false);
        emit RiskRegistry.AddressFlaggedSuspicious(alice, mallory, ETH_CHAIN_ID, block.timestamp);

        vm.expectEmit(true, true, false, false);
        emit GuardCallback.AddressSuspiciousFlagRelayed(alice, mallory, ETH_CHAIN_ID);

        callback.flagSuspicious(address(this), alice, mallory, ETH_CHAIN_ID);

        assertTrue(registry.isSuspicious(alice));
        assertEq(registry.flagSource(alice), "USDC_TAINT");
        assertEq(registry.flaggedBy(alice), mallory);

        // Step 3 — GuardHook applies SuspiciousNew (0.75%) surcharge
        vm.expectEmit(true, false, false, false);
        emit GuardHook.SwapSurcharged(alice, hook.SUSPICIOUS_FEE(), block.timestamp);

        _swapAs(alice);
        assertEq(hook.totalSuspiciousNewSurcharged(), 1);
        assertEq(hook.totalSwapsSurcharged(), 0);  // Flagged counter unchanged
    }

    // =======================================================================
    // Journey 4 — Taint Escalation: SuspiciousNew → Flagged
    //
    // Bob starts SuspiciousNew (0.75%). Further evidence escalates to Flagged (3%).
    // totalFlagged stays at 1 — no double-counting on escalation.
    // After escalation, bob cannot add liquidity.
    // =======================================================================
    function test_journey_suspiciousEscalationToFlagged() public {
        _flagSuspicious(bob, mallory);
        assertTrue(registry.isSuspicious(bob));
        assertEq(registry.totalFlagged(), 1);

        // SuspiciousNew swap: 0.75%
        _swapAs(bob);
        assertEq(hook.totalSuspiciousNewSurcharged(), 1);
        assertEq(hook.totalSwapsSurcharged(), 0);

        // Escalate SuspiciousNew → Flagged (wasSuspicious = true → totalFlagged not double-counted)
        _flagAddress(bob, mallory);
        assertTrue(registry.isFlagged(bob));
        assertEq(registry.totalFlagged(), 1);  // no double-count

        // Flagged swap: 3%
        _swapAs(bob);
        assertEq(hook.totalSwapsSurcharged(), 1);

        // Flagged: cannot add liquidity (WrappedError from router — use bare expectRevert)
        _fundAndApprove(bob);
        vm.expectRevert();
        _addLiqAs(bob, bytes32(uint256(200)));
    }

    // =======================================================================
    // Journey 5 — Chainalysis OFAC Oracle Sync: Batch Block
    //
    // Reactive detects SanctionedAddressesAdded on Ethereum.
    // GuardCallback blocks 3 addresses in batch with flagSource = "CHAINALYSIS".
    // =======================================================================
    function test_journey_chainalysisOracleBatchBlock() public {
        address addr1 = address(0xAAA1);
        address addr2 = address(0xAAA2);
        address addr3 = address(0xAAA3);

        address[] memory targets = new address[](3);
        targets[0] = addr1;
        targets[1] = addr2;
        targets[2] = addr3;

        // Step 1 — Reactive detects Chainalysis oracle event
        reactive.reactTest(
            ETH_CHAIN_ID, CHAINALYSIS_ORACLE, SANCTIONED_ADDED_TOPIC_0,
            0, 0, abi.encode(targets)
        );
        assertTrue(reactive.blacklist(addr1));
        assertTrue(reactive.blacklist(addr2));
        assertTrue(reactive.blacklist(addr3));

        // Step 2 — Callback delivers batch block to Unichain
        bytes32 oracleSyncSig = keccak256("OracleSyncBatch(address,uint256,uint256)");
        vm.recordLogs();
        callback.blockAddressBatch(address(this), targets);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool oracleSyncEmitted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == oracleSyncSig) { oracleSyncEmitted = true; break; }
        }
        assertTrue(oracleSyncEmitted, "OracleSyncBatch must be emitted");

        assertTrue(registry.isBlocked(addr1));
        assertTrue(registry.isBlocked(addr2));
        assertTrue(registry.isBlocked(addr3));
        assertEq(registry.flagSource(addr1), "CHAINALYSIS");
        assertEq(registry.totalBlocked(), 3);

        // addr1 cannot swap
        vm.expectRevert();
        _swapAs(addr1);
    }

    // =======================================================================
    // Journey 6 — Circle USDC Blacklisted: Single Address Block
    //
    // Reactive detects USDC Blacklisted(carol) on Ethereum.
    // GuardCallback blocks carol on Unichain with flagSource = "USDC_BLACKLIST".
    // =======================================================================
    function test_journey_usdcBlacklistedEvent() public {
        // Step 1 — Reactive detects USDC Blacklisted event
        vm.expectEmit(true, false, false, false);
        emit GuardReactive.UsdcBlacklistDetected(carol, ETH_CHAIN_ID);

        reactive.reactTest(
            ETH_CHAIN_ID, USDC_ETHEREUM, USDC_BLACKLISTED_TOPIC_0,
            uint256(uint160(carol)), 0, new bytes(0)
        );
        assertTrue(reactive.blacklist(carol));

        // Step 2 — Callback delivers block to Unichain
        vm.expectEmit(true, false, false, true);
        emit GuardCallback.AddressBlockedFromOracle(carol, "USDC_BLACKLIST");

        callback.blockFromUsdcBlacklist(address(this), carol);

        assertTrue(registry.isBlocked(carol));
        assertEq(registry.flagSource(carol), "USDC_BLACKLIST");

        // carol's swap reverts
        vm.expectRevert();
        _swapAs(carol);
    }

    // =======================================================================
    // Journey 7 — LP Holding Period Enforcement
    //
    // lp1 adds liquidity. Immediate removal reverts (EarlyExitBlocked).
    // After 12h: still reverts. After 25h (≥ 24h holdingPeriod): removal succeeds.
    // =======================================================================
    function test_journey_lpHoldingPeriod() public {
        _fundAndApprove(lp1);

        uint256 T = block.timestamp;
        bytes32 salt = bytes32(uint256(300));

        // Add liquidity: records addedAt[lp1][pid] = T
        _addLiqAs(lp1, salt);
        bytes32 pid = keccak256(abi.encode(key));
        assertEq(hook.addedAt(lp1, pid), T);

        // Immediate remove → revert (elapsed = 0, wrapped by router — use bare expectRevert)
        vm.expectRevert();
        _removeLiqAs(lp1, salt);

        // 12h elapsed: still locked (12h < 24h)
        vm.warp(T + 12 hours);
        vm.expectRevert();
        _removeLiqAs(lp1, salt);

        // 25h elapsed: unlocked (25h ≥ 24h)
        vm.warp(T + 25 hours);
        _removeLiqAs(lp1, salt);  // must not revert
    }

    // =======================================================================
    // Journey 8 — Travel Rule Threshold: Large Swap Triggers Event
    //
    // A swap at exactly $1,000 USDC (1_000 * 1e6 units) emits TravelRuleThresholdExceeded.
    // A swap at threshold - 1 does NOT emit the event.
    // =======================================================================
    function test_journey_travelRuleThreshold() public {
        int256 threshold = int256(uint256(hook.TRAVEL_RULE_THRESHOLD()));

        // At threshold: event emitted
        vm.expectEmit(true, false, false, false);
        emit GuardHook.TravelRuleThresholdExceeded(alice, 0, bytes32(0), 0);

        vm.prank(address(this), alice);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: threshold, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // Just below threshold: no TravelRuleThresholdExceeded event
        int256 belowThreshold = threshold - 1;
        bytes32 travelRuleSig = keccak256("TravelRuleThresholdExceeded(address,uint128,bytes32,uint256)");

        vm.recordLogs();
        vm.prank(address(this), alice);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: belowThreshold, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != travelRuleSig, "TravelRuleThresholdExceeded must NOT emit below threshold");
        }
    }

    // =======================================================================
    // Journey 9 — MEV Tax Observation (Unichain-Specific)
    //
    // When gasprice > basefee, totalMevTaxObserved increments and MevTaxObserved is emitted.
    // When gasprice == basefee (no priority fee), counter stays unchanged and no event.
    // =======================================================================
    function test_journey_mevTaxObservation() public {
        // Priority fee = 2 gwei (3 - 1)
        vm.fee(1 gwei);
        vm.txGasPrice(3 gwei);

        vm.expectEmit(true, false, false, false);
        emit GuardHook.MevTaxObserved(alice, 0, 0);

        _swapAs(alice);
        assertTrue(hook.totalMevTaxObserved() > 0);

        uint256 prevMev = hook.totalMevTaxObserved();

        // No priority fee: gasprice == basefee → counter unchanged, no MevTaxObserved event
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);

        bytes32 mevSig = keccak256("MevTaxObserved(address,uint256,uint256)");
        vm.recordLogs();
        _swapAs(alice);
        assertEq(hook.totalMevTaxObserved(), prevMev);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != mevSig, "MevTaxObserved must NOT emit at zero priority fee");
        }
    }

    // =======================================================================
    // Journey 10 — Emergency Pause: Scoped to Swaps and LP Adds
    //
    // Owner pauses hook. Swaps and LP adds revert (EnforcedPause).
    // LP removes are NOT blocked — funds are never frozen.
    // After unpause, swaps resume normally.
    // =======================================================================
    function test_journey_emergencyPause() public {
        _fundAndApprove(lp1);
        bytes32 salt = bytes32(uint256(400));

        // lp1 adds liquidity before pause
        _addLiqAs(lp1, salt);
        vm.warp(block.timestamp + 25 hours);  // past holding period

        // Pause
        hook.pause();
        assertTrue(hook.paused());

        // Swap reverts
        vm.expectRevert();
        _swapAs(alice);

        // LP add reverts
        _fundAndApprove(alice);
        vm.expectRevert();
        _addLiqAs(alice, bytes32(uint256(401)));

        // LP remove still works (beforeRemoveLiquidity does NOT check paused)
        _removeLiqAs(lp1, salt);

        // Unpause → swaps resume
        hook.unpause();
        assertFalse(hook.paused());
        _swapAs(alice);  // must not revert
    }

    // =======================================================================
    // Journey 11 — Whitelist: Blocked Address Bypasses All Checks
    //
    // mallory is blocked but whitelist overrides all risk tiers.
    // After whitelist removal, mallory is blocked again.
    // =======================================================================
    function test_journey_whitelistBypass() public {
        registry.addToBlacklist(mallory);

        // Blocked — swap reverts
        vm.expectRevert();
        _swapAs(mallory);

        // Whitelist added — bypasses block
        registry.setWhitelist(mallory, true);
        _swapAs(mallory);  // must not revert
        assertEq(hook.totalSwapsSurcharged(), 0);

        // Whitelist allows LP add too
        _fundAndApprove(mallory);
        _addLiqAs(mallory, bytes32(uint256(500)));

        // Remove whitelist — blocked again
        registry.setWhitelist(mallory, false);
        vm.expectRevert();
        _swapAs(mallory);
    }

    // =======================================================================
    // Journey 12 — SuspiciousNew Appeal + Auto-Expiry Lifecycle
    //
    // alice receives a SuspiciousNew flag, pays 0.75% surcharge, appeals via
    // requestAppeal(). After 31 days the flag auto-expires → alice is Clean again.
    // =======================================================================
    function test_journey_suspiciousAppealAndExpiry() public {
        _flagSuspicious(alice, mallory);
        assertTrue(registry.isSuspicious(alice));

        // SuspiciousNew swap: 0.75% surcharge
        _swapAs(alice);
        assertEq(hook.totalSuspiciousNewSurcharged(), 1);

        // alice appeals
        vm.expectEmit(true, false, false, false);
        emit RiskRegistry.AppealRequested(alice, block.timestamp);

        vm.prank(alice);
        registry.requestAppeal();

        // Cannot expire yet (< 30 days)
        vm.expectRevert();
        registry.expireSuspicious(alice);

        // Warp 31 days → expiry criteria met
        vm.warp(block.timestamp + 31 days);

        vm.expectEmit(true, false, false, false);
        emit RiskRegistry.SuspiciousExpired(alice, 0);  // checkData=false; timestamp not checked

        registry.expireSuspicious(alice);
        assertTrue(registry.isClean(alice));

        // alice now swaps at base fee — SuspiciousNew counter stays at 1
        _swapAs(alice);
        assertEq(hook.totalSuspiciousNewSurcharged(), 1);
    }

    // =======================================================================
    // Journey 13 — Transitive Taint Chain: A→B→C Three Hops
    //
    // Taint propagates transitively: mallory (A, pre-seeded) → bob (B) → carol (C).
    // B and C are SuspiciousNew (0.75% surcharge). A (Blocked) cannot swap.
    // =======================================================================
    function test_journey_taintChainThreeHops() public {
        // Hop 1: mallory → bob (mallory is pre-seeded in reactive.blacklist)
        reactive.reactTest(
            ETH_CHAIN_ID, USDC_ETHEREUM, TRANSFER_TOPIC_0,
            uint256(uint160(mallory)), uint256(uint160(bob)),
            abi.encode(uint256(1000e6))
        );
        assertTrue(reactive.blacklist(bob));
        _flagSuspicious(bob, mallory);
        assertTrue(registry.isSuspicious(bob));

        // Hop 2: bob → carol (bob is now in reactive.blacklist)
        reactive.reactTest(
            ETH_CHAIN_ID, USDC_ETHEREUM, TRANSFER_TOPIC_0,
            uint256(uint160(bob)), uint256(uint160(carol)),
            abi.encode(uint256(1000e6))
        );
        assertTrue(reactive.blacklist(carol));
        _flagSuspicious(carol, bob);
        assertTrue(registry.isSuspicious(carol));

        // bob swaps: 0.75%
        _swapAs(bob);
        assertEq(hook.totalSuspiciousNewSurcharged(), 1);

        // carol swaps: 0.75%
        _swapAs(carol);
        assertEq(hook.totalSuspiciousNewSurcharged(), 2);

        // mallory (block in registry) cannot swap
        registry.addToBlacklist(mallory);
        vm.expectRevert();
        _swapAs(mallory);
    }

    // =======================================================================
    // Journey 14 — Protocol Statistics Dashboard
    //
    // After flagging bob (SuspiciousNew), carol (Flagged), and blocking mallory,
    // getProtocolStats returns accurate counters across all tracked metrics.
    // =======================================================================
    function test_journey_protocolStatsDashboard() public {
        // Setup: bob=SuspiciousNew, carol=Flagged, mallory=Blocked
        _flagSuspicious(bob, mallory);
        _flagAddress(carol, mallory);
        registry.addToBlacklist(mallory);

        // bob: SuspiciousNew swap → +1 suspiciousNewSurcharged
        _swapAs(bob);

        // carol: Flagged swap → +1 swapsSurcharged
        _swapAs(carol);

        // mallory: blocked swap → reverts (not counted in surcharge stats)
        vm.expectRevert();
        _swapAs(mallory);

        (
            uint24 _baseFee, uint24 _surchargeFee, uint24 _suspiciousFee,
            uint256 swapsSurcharged, uint256 suspiciousNewSurcharged,
            uint256 totalFlagged, bool isPaused, uint256 mevTaxObserved
        ) = hook.getProtocolStats();

        assertEq(_baseFee, 3000);
        assertEq(_surchargeFee, 30000);
        assertEq(_suspiciousFee, 7500);
        // carol (Flagged 3%)
        assertEq(swapsSurcharged, 1);           
        // bob (SuspiciousNew 0.75%)
        assertEq(suspiciousNewSurcharged, 1);    
        // bob (SuspiciousNew) + carol (Flagged)
        assertEq(totalFlagged, 2);               
        assertFalse(isPaused);
        // no priority fee set in this test
        assertEq(mevTaxObserved, 0);             
    }

    // =======================================================================
    // Journey 15 — Identity-Verified Bypass + Multi-Oracle Integration
    //
    // alice is SuspiciousNew but identity-verified → swaps at base fee (no surcharge).
    // batchBlockFromOracle (Chainalysis) and blockFromOracle (USDC blacklist) work
    // independently and produce distinct flagSource values.
    // =======================================================================
    function test_journey_identityVerifiedAndMultiOracle() public {
        // alice is SuspiciousNew (would normally get 0.75%)
        _flagSuspicious(alice, mallory);
        assertTrue(registry.isSuspicious(alice));

        // Identity verification bypasses risk surcharge
        registry.setIdentityVerified(alice, true);

        _swapAs(alice);
        // bypassed by identityVerified — no surcharge applied
        assertEq(hook.totalSuspiciousNewSurcharged(), 0);  
        assertEq(hook.totalSwapsSurcharged(), 0);

        // Multi-oracle: batch block from Chainalysis
        address oracleTarget1 = address(0xBBB1);
        address[] memory batch = new address[](1);
        batch[0] = oracleTarget1;

        bytes32 oracleSyncSig = keccak256("OracleSyncBatch(address,uint256,uint256)");
        vm.recordLogs();
        callback.blockAddressBatch(address(this), batch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == oracleSyncSig) { found = true; break; }
        }
        assertTrue(found, "OracleSyncBatch must be emitted");
        assertEq(registry.flagSource(oracleTarget1), "CHAINALYSIS");
        assertTrue(registry.isBlocked(oracleTarget1));

        // Single block from USDC blacklist
        address oracleTarget2 = address(0xBBB2);
        vm.expectEmit(true, false, false, true);
        emit GuardCallback.AddressBlockedFromOracle(oracleTarget2, "USDC_BLACKLIST");
        callback.blockFromUsdcBlacklist(address(this), oracleTarget2);
        assertEq(registry.flagSource(oracleTarget2), "USDC_BLACKLIST");
        assertTrue(registry.isBlocked(oracleTarget2));

        // flagSource distinguishes the two oracle sources
        assertTrue(
            registry.flagSource(oracleTarget1) != registry.flagSource(oracleTarget2),
            "CHAINALYSIS and USDC_BLACKLIST flagSource must differ"
        );
    }
}

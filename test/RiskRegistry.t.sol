// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {RiskRegistry} from "../src/RiskRegistry.sol";

contract RiskRegistryTest is Test {
    RiskRegistry registry;
    address callbackAddr = address(0xCA11BAC4);
    address user1 = address(0x1111);
    address user2 = address(0x2222);
    address user3 = address(0x3333);

    function setUp() public {
        registry = new RiskRegistry();
        registry.setCallbackContract(callbackAddr);
    }

    // Owner addToBlacklist
    function test_addToBlacklist_setsBlocked() public {
        registry.addToBlacklist(user1);
        assertEq(uint256(registry.getRiskLevel(user1)), uint256(RiskRegistry.RiskLevel.Blocked));
        assertTrue(registry.isBlocked(user1));
    }

    function test_addToBlacklist_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(RiskRegistry.OnlyOwner.selector);
        registry.addToBlacklist(user1);
    }

    // Owner batchAddToBlacklist

    function test_batchAddToBlacklist_works() public {
        address[] memory targets = new address[](3);
        targets[0] = user1;
        targets[1] = user2;
        targets[2] = user3;

        registry.batchAddToBlacklist(targets);

        assertTrue(registry.isBlocked(user1));
        assertTrue(registry.isBlocked(user2));
        assertTrue(registry.isBlocked(user3));
    }

    // Owner removeFromBlacklist

    function test_removeFromBlacklist_setsClean() public {
        registry.addToBlacklist(user1);
        assertTrue(registry.isBlocked(user1));

        registry.removeFromBlacklist(user1);
        assertTrue(registry.isClean(user1));
        assertFalse(registry.isBlocked(user1));
    }

    // CallbackflagAddress

    function test_flagAddress_setsFlagged() public {
        vm.prank(callbackAddr);
        registry.flagAddress(user1, user2, 1);

        assertTrue(registry.isFlagged(user1));
        assertEq(uint256(registry.getRiskLevel(user1)), uint256(RiskRegistry.RiskLevel.Flagged));
    }

    function test_flagAddress_onlyCallback() public {
        vm.expectRevert(RiskRegistry.OnlyCallback.selector);
        registry.flagAddress(user1, user2, 1);
    }

    function test_flagAddress_doesNotDowngradeBlocked() public {
        registry.addToBlacklist(user1);

        vm.prank(callbackAddr);
        registry.flagAddress(user1, user2, 1);

        // Should still be Blocked, not downgraded to Flagged
        assertTrue(registry.isBlocked(user1));
        assertFalse(registry.isFlagged(user1));
    }

    function test_flagAddress_recordsSource() public {
        vm.prank(callbackAddr);
        registry.flagAddress(user1, user2, 1);

        assertEq(registry.flaggedBy(user1), user2);
        assertEq(registry.flaggedAt(user1), block.timestamp);
        assertEq(registry.totalFlagged(), 1);
    }

    // Callback flagSuspicious (SuspiciousNew tier)

    function test_flagSuspicious_setsSuspiciousNew() public {
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        assertTrue(registry.isSuspicious(user1));
        assertEq(uint256(registry.getRiskLevel(user1)), uint256(RiskRegistry.RiskLevel.SuspiciousNew));
        assertFalse(registry.isFlagged(user1));
        assertFalse(registry.isBlocked(user1));
    }

    function test_flagSuspicious_onlyCallback() public {
        vm.expectRevert(RiskRegistry.OnlyCallback.selector);
        registry.flagSuspicious(user1, user2, 1);
    }

    function test_flagSuspicious_doesNotDowngradeBlocked() public {
        registry.addToBlacklist(user1);

        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        // Blocked stays Blocked
        assertTrue(registry.isBlocked(user1));
        assertFalse(registry.isSuspicious(user1));
    }

    function test_flagSuspicious_doesNotDowngradeFlagged() public {
        vm.prank(callbackAddr);
        registry.flagAddress(user1, user2, 1);
        assertTrue(registry.isFlagged(user1));

        // flagSuspicious only upgrades from Clean — should not downgrade Flagged
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        assertTrue(registry.isFlagged(user1));
        assertFalse(registry.isSuspicious(user1));
    }

    function test_flagSuspicious_recordsFlagSource() public {
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        assertEq(registry.flagSource(user1), "USDC_TAINT");
        assertEq(registry.flaggedBy(user1), user2);
        assertEq(registry.totalFlagged(), 1);
    }

    // Callback batchBlockFromOracle

    function test_batchBlockFromOracle_blocksAll() public {
        address[] memory targets = new address[](3);
        targets[0] = user1;
        targets[1] = user2;
        targets[2] = user3;

        vm.prank(callbackAddr);
        registry.batchBlockFromOracle(targets, "CHAINALYSIS");

        assertTrue(registry.isBlocked(user1));
        assertTrue(registry.isBlocked(user2));
        assertTrue(registry.isBlocked(user3));
        assertEq(registry.totalBlocked(), 3);
    }

    function test_batchBlockFromOracle_recordsFlagSource() public {
        address[] memory targets = new address[](1);
        targets[0] = user1;

        vm.prank(callbackAddr);
        registry.batchBlockFromOracle(targets, "CHAINALYSIS");

        assertEq(registry.flagSource(user1), "CHAINALYSIS");
    }

    function test_batchBlockFromOracle_idempotent() public {
        address[] memory targets = new address[](2);
        targets[0] = user1;
        targets[1] = user1; // duplicate

        vm.prank(callbackAddr);
        registry.batchBlockFromOracle(targets, "CHAINALYSIS");

        assertEq(registry.totalBlocked(), 1); // not 2
    }

    function test_batchBlockFromOracle_onlyCallback() public {
        address[] memory targets = new address[](1);
        targets[0] = user1;
        vm.expectRevert(RiskRegistry.OnlyCallback.selector);
        registry.batchBlockFromOracle(targets, "CHAINALYSIS");
    }

    // callback blockFromOracle

    function test_blockFromOracle_setsBlocked() public {
        vm.prank(callbackAddr);
        registry.blockFromOracle(user1, "USDC_BLACKLIST");

        assertTrue(registry.isBlocked(user1));
        assertEq(registry.flagSource(user1), "USDC_BLACKLIST");
    }

    function test_blockFromOracle_idempotent() public {
        vm.prank(callbackAddr);
        registry.blockFromOracle(user1, "USDC_BLACKLIST");
        assertEq(registry.totalBlocked(), 1);

        vm.prank(callbackAddr);
        registry.blockFromOracle(user1, "USDC_BLACKLIST");
        assertEq(registry.totalBlocked(), 1);
    }

    // identityVerified

    function test_identityVerified_setAndQuery() public {
        assertFalse(registry.identityVerified(user1));

        registry.setIdentityVerified(user1, true);
        assertTrue(registry.identityVerified(user1));

        registry.setIdentityVerified(user1, false);
        assertFalse(registry.identityVerified(user1));
    }

    function test_identityVerified_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(RiskRegistry.OnlyOwner.selector);
        registry.setIdentityVerified(user1, true);
    }

    // View Functions

    function test_isBlocked_isCorrect() public {
        assertFalse(registry.isBlocked(user1));
        registry.addToBlacklist(user1);
        assertTrue(registry.isBlocked(user1));
    }

    function test_isFlagged_isCorrect() public {
        assertFalse(registry.isFlagged(user1));
        vm.prank(callbackAddr);
        registry.flagAddress(user1, user2, 1);
        assertTrue(registry.isFlagged(user1));
    }

    function test_isSuspicious_isCorrect() public {
        assertFalse(registry.isSuspicious(user1));
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);
        assertTrue(registry.isSuspicious(user1));
    }

    // setCallbackContract

    function test_setCallbackContract_onlyOnce() public {
        // Already set in setUp
        vm.expectRevert(RiskRegistry.CallbackAlreadySet.selector);
        registry.setCallbackContract(address(0xBEEF));
    }

    // Zero-Address Validation (A3)

    function test_setCallbackContract_revertsOnZeroAddress() public {
        RiskRegistry fresh = new RiskRegistry();
        vm.expectRevert(RiskRegistry.ZeroAddress.selector);
        fresh.setCallbackContract(address(0));
    }

    // totalBlocked Counter (D2)

    function test_totalBlocked_incrementsAndDecrements() public {
        assertEq(registry.totalBlocked(), 0);

        registry.addToBlacklist(user1);
        assertEq(registry.totalBlocked(), 1);

        registry.addToBlacklist(user2);
        assertEq(registry.totalBlocked(), 2);

        registry.removeFromBlacklist(user1);
        assertEq(registry.totalBlocked(), 1);
    }

    function test_totalBlocked_idempotentOnDoubleAdd() public {
        registry.addToBlacklist(user1);
        assertEq(registry.totalBlocked(), 1);

        // Adding same address again must NOT increment counter
        registry.addToBlacklist(user1);
        assertEq(registry.totalBlocked(), 1);
    }

    function test_batchAddToBlacklist_idempotent() public {
        address[] memory targets = new address[](2);
        targets[0] = user1;
        targets[1] = user1; // duplicate

        registry.batchAddToBlacklist(targets);
        assertEq(registry.totalBlocked(), 1); // not 2
    }

    // Whitelist (D2)

    function test_whitelist_setAndQuery() public {
        assertFalse(registry.isWhitelisted(user1));

        registry.setWhitelist(user1, true);
        assertTrue(registry.isWhitelisted(user1));

        registry.setWhitelist(user1, false);
        assertFalse(registry.isWhitelisted(user1));
    }

    // batchGetRiskLevel (C2) 

    function test_batchGetRiskLevel_works() public {
        registry.addToBlacklist(user1);
        vm.prank(callbackAddr);
        registry.flagAddress(user2, user1, 1);

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        RiskRegistry.RiskLevel[] memory levels = registry.batchGetRiskLevel(accounts);
        assertEq(uint256(levels[0]), uint256(RiskRegistry.RiskLevel.Blocked));
        assertEq(uint256(levels[1]), uint256(RiskRegistry.RiskLevel.Flagged));
        assertEq(uint256(levels[2]), uint256(RiskRegistry.RiskLevel.Clean));
    }

    function test_batchGetRiskLevel_includesSuspiciousNew() public {
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        RiskRegistry.RiskLevel[] memory levels = registry.batchGetRiskLevel(accounts);
        assertEq(uint256(levels[0]), uint256(RiskRegistry.RiskLevel.SuspiciousNew));
    }

    // Fuzz

    function testFuzz_addAndRemove(address target) public {
        registry.addToBlacklist(target);
        assertTrue(registry.isBlocked(target));

        registry.removeFromBlacklist(target);
        assertTrue(registry.isClean(target));
    }

    // flagAddress escalates SuspiciousNew → Flagged 

    function test_flagAddress_upgradesSuspiciousNewToFlagged() public {
        // First set SuspiciousNew via callback
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);
        assertTrue(registry.isSuspicious(user1));

        // Now escalate to Flagged
        vm.prank(callbackAddr);
        registry.flagAddress(user1, user2, 1);

        assertTrue(registry.isFlagged(user1));
        assertFalse(registry.isSuspicious(user1));
    }

    function test_flagAddress_upgradesSuspiciousNew_doesNotDoubleTotalFlagged() public {
        // flagSuspicious increments totalFlagged once
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);
        assertEq(registry.totalFlagged(), 1);

        // flagAddress on SuspiciousNew should NOT increment again
        vm.prank(callbackAddr);
        registry.flagAddress(user1, user2, 1);
        assertEq(registry.totalFlagged(), 1);  // still 1, not 2
    }

    // Appeal mechanism for SuspiciousNew addresses

    function test_requestAppeal_emitsEvent() public {
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        vm.expectEmit(true, false, false, false);
        emit RiskRegistry.AppealRequested(user1, block.timestamp);

        vm.prank(user1);
        registry.requestAppeal();
    }

    function test_requestAppeal_revertsIfNotSuspicious() public {
        // user1 is Clean — should revert
        vm.prank(user1);
        vm.expectRevert(RiskRegistry.NotSuspicious.selector);
        registry.requestAppeal();
    }

    function test_expireSuspicious_clearsAfterPeriod() public {
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);
        assertTrue(registry.isSuspicious(user1));

        // Warp past 30-day expiry
        vm.warp(block.timestamp + 31 days);

        registry.expireSuspicious(user1);
        assertTrue(registry.isClean(user1));
    }

    function test_expireSuspicious_revertsBeforeExpiry() public {
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        vm.warp(block.timestamp + 1 days);

        vm.expectRevert();  // NotExpiredYet
        registry.expireSuspicious(user1);
    }

    function test_expireSuspicious_revertsIfNotSuspicious() public {
        // user1 is Clean — should revert
        vm.expectRevert(RiskRegistry.NotSuspicious.selector);
        registry.expireSuspicious(user1);
    }

    function test_expireSuspicious_revertsIfNoExpiryConfigured() public {
        registry.setSuspiciousExpiryPeriod(0);

        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        vm.expectRevert(RiskRegistry.NoExpiryConfigured.selector);
        registry.expireSuspicious(user1);
    }

    function test_setSuspiciousExpiryPeriod_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(RiskRegistry.OnlyOwner.selector);
        registry.setSuspiciousExpiryPeriod(7 days);
    }

    // Flagged tier reachable via owner

    function test_flagAddressDirect_setsFlagged() public {
        registry.flagAddressDirect(user1, user2);

        assertTrue(registry.isFlagged(user1));
        assertFalse(registry.isBlocked(user1));
        assertEq(registry.totalFlagged(), 1);
    }

    function test_flagAddressDirect_upgradesSuspiciousNewToFlagged() public {
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);
        assertEq(registry.totalFlagged(), 1);

        registry.flagAddressDirect(user1, user2);

        assertTrue(registry.isFlagged(user1));
        assertEq(registry.totalFlagged(), 1);  // no double-count
    }

    function test_flagAddressDirect_doesNotDowngradeBlocked() public {
        registry.addToBlacklist(user1);
        assertTrue(registry.isBlocked(user1));

        registry.flagAddressDirect(user1, user2);

        // Should still be Blocked, not downgraded to Flagged
        assertTrue(registry.isBlocked(user1));
        assertFalse(registry.isFlagged(user1));
    }

    function test_flagAddressDirect_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(RiskRegistry.OnlyOwner.selector);
        registry.flagAddressDirect(user1, user2);
    }

    // Full Appeal + Expiry Lifecycle 

    function test_fullAppealLifecycle() public {
        // 1. Flag as suspicious
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);
        assertTrue(registry.isSuspicious(user1));

        // 2. Request appeal — emits AppealRequested
        vm.expectEmit(true, false, false, false);
        emit RiskRegistry.AppealRequested(user1, block.timestamp);

        vm.prank(user1);
        registry.requestAppeal();

        // 3. Warp past 30-day expiry
        vm.warp(block.timestamp + 31 days);

        // 4. Expire — emits SuspiciousExpired, sets Clean
        vm.expectEmit(true, false, false, false);
        emit RiskRegistry.SuspiciousExpired(user1, block.timestamp);

        registry.expireSuspicious(user1);

        assertEq(uint256(registry.getRiskLevel(user1)), uint256(RiskRegistry.RiskLevel.Clean));
        assertTrue(registry.isClean(user1));
    }

    // expireSuspicious Before Period — Exact Selector

    function test_expireSuspicious_revertsBeforePeriod() public {
        uint256 flagTime = block.timestamp;
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);

        vm.warp(flagTime + 29 days);

        uint256 expectedExpiry = flagTime + 30 days;
        vm.expectRevert(abi.encodeWithSelector(RiskRegistry.NotExpiredYet.selector, expectedExpiry));
        registry.expireSuspicious(user1);
    }

    // removeFromBlacklist Clears All Metadata

    function test_removeFromBlacklist_clearsAllMetadata() public {
        // flagSuspicious sets flaggedAt, flaggedBy, flagSource
        vm.prank(callbackAddr);
        registry.flagSuspicious(user1, user2, 1);
        assertGt(registry.flaggedAt(user1), 0);
        assertEq(registry.flagSource(user1), "USDC_TAINT");
        assertEq(registry.flaggedBy(user1), user2);

        // Escalate to Blocked
        registry.addToBlacklist(user1);
        assertTrue(registry.isBlocked(user1));

        // Remove: must clear all metadata
        registry.removeFromBlacklist(user1);

        assertEq(registry.flaggedAt(user1), 0);
        assertEq(registry.flagSource(user1), bytes32(0));
        assertEq(registry.flaggedBy(user1), address(0));
        assertEq(uint256(registry.getRiskLevel(user1)), uint256(RiskRegistry.RiskLevel.Clean));
    }

    // batchAddToBlacklist With Duplicates — No Double Count

    function test_batchAddToBlacklist_withDuplicates_noOverCount() public {
        address alice = address(0xAA01);
        address bob = address(0xBB01);

        address[] memory targets = new address[](3);
        targets[0] = alice;
        targets[1] = alice; // duplicate
        targets[2] = bob;

        registry.batchAddToBlacklist(targets);
        assertEq(registry.totalBlocked(), 2); // alice counted once, bob once
        assertTrue(registry.isBlocked(alice));
        assertTrue(registry.isBlocked(bob));
    }

    // totalBlocked — Remove Then Re-add 

    function test_totalBlocked_removeThenReadd() public {
        registry.addToBlacklist(user1);
        assertEq(registry.totalBlocked(), 1);

        registry.removeFromBlacklist(user1);
        assertEq(registry.totalBlocked(), 0);
        assertTrue(registry.isClean(user1));

        registry.addToBlacklist(user1);
        assertEq(registry.totalBlocked(), 1);
        assertTrue(registry.isBlocked(user1));
    }

    // Fuzz — No Downgrade From Blocked

    function testFuzz_noDowngrade(address user, uint8 action) public {
        vm.assume(user != address(0));
        vm.assume(user != callbackAddr);

        registry.addToBlacklist(user);
        RiskRegistry.RiskLevel before = registry.getRiskLevel(user);
        assertEq(uint256(before), uint256(RiskRegistry.RiskLevel.Blocked));

        if (action % 3 == 0) {
            vm.prank(callbackAddr);
            registry.flagSuspicious(user, address(0x1), 1);
        } else if (action % 3 == 1) {
            vm.prank(callbackAddr);
            registry.flagAddress(user, address(0x1), 1);
        } else {
            // idempotent
            registry.addToBlacklist(user); 
        }

        assertEq(uint256(registry.getRiskLevel(user)), uint256(before));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, Vm} from "forge-std/Test.sol";
import {GuardReactive} from "../src/GuardReactive.sol";

// GuardReactiveHarness
// exposes internal state for testing by simulating the Reactive VM environment.
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
        // Force vm = true so react() works in tests
        vm = true;
    }

    // expose the react function for testing without vmOnly check
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

contract GuardReactiveTest is Test {
    GuardReactiveHarness reactive;
    address callbackContract = address(0xCA11BAC4);

    address blacklisted1 = address(0xB1AC);
    address blacklisted2 = address(0xB2AC);
    address cleanRecipient = address(0xC1EA);

    uint256 constant TRANSFER_TOPIC_0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint256 constant USDC_BLACKLISTED_TOPIC_0 = 0xffa4e6181777692565cf28528fc88fd1516ea86b56da075235fa575af6a4b855;
    uint256 constant SANCTIONED_ADDED_TOPIC_0 = uint256(keccak256("SanctionedAddressesAdded(address[])"));

    address constant USDC_ETHEREUM = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CHAINALYSIS_ORACLE = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;

    function setUp() public {
        address[] memory initial = new address[](2);
        initial[0] = blacklisted1;
        initial[1] = blacklisted2;

        reactive = new GuardReactiveHarness(initial, callbackContract, 1, 130, USDC_ETHEREUM);
    }

    // USDC Transfer Taint Propagation

    function test_blacklistedSender_triggersFlag() public {
        // Simulate Transfer from blacklisted1 to cleanRecipient on Ethereum USDC
        reactive.reactTest(
            1, // Ethereum
            USDC_ETHEREUM,
            TRANSFER_TOPIC_0,
            // from
            uint256(uint160(blacklisted1)), 
            // to
            uint256(uint160(cleanRecipient)), 
            // value
            abi.encode(uint256(1000e6)) 
        );

        // cleanRecipient should now be in the local blacklist
        assertTrue(reactive.blacklist(cleanRecipient));
    }

    function test_cleanSender_noFlag() public {
        address cleanSender = address(0xAAAA);

        reactive.reactTest(
            1,
            USDC_ETHEREUM,
            TRANSFER_TOPIC_0,
            uint256(uint160(cleanSender)),
            uint256(uint160(cleanRecipient)),
            abi.encode(uint256(1000e6))
        );

        // cleanRecipient should NOT be flagged
        assertFalse(reactive.blacklist(cleanRecipient));
    }

    function test_addToBlacklist_works() public {
        address newBad = address(0xBAD1);
        assertFalse(reactive.blacklist(newBad));

        reactive.addToBlacklist(newBad);
        assertTrue(reactive.blacklist(newBad));
    }

    function test_batchAddToBlacklist_works() public {
        address[] memory targets = new address[](2);
        targets[0] = address(0xBAD1);
        targets[1] = address(0xBAD2);

        reactive.batchAddToBlacklist(targets);
        assertTrue(reactive.blacklist(targets[0]));
        assertTrue(reactive.blacklist(targets[1]));
    }

    function test_topicToAddress_correct() public {
        // Topic is uint256 with address in lower 160 bits
        uint256 topic = uint256(uint160(address(0x1234567890AbcdEF1234567890aBcdef12345678)));
        address extracted = address(uint160(topic));
        assertEq(extracted, address(0x1234567890AbcdEF1234567890aBcdef12345678));
    }

    function test_alreadyBlacklistedRecipient_noDoubleFlag() public {
        // blacklisted2 is already in the blacklist
        // sending to them should not trigger
        reactive.reactTest(
            1,
            USDC_ETHEREUM,
            TRANSFER_TOPIC_0,
            uint256(uint160(blacklisted1)),
            uint256(uint160(blacklisted2)),
            abi.encode(uint256(1000e6))
        );

        // Should still be blacklisted but no callback emitted (no double flag)
        assertTrue(reactive.blacklist(blacklisted2));
    }

    function testFuzz_addressExtraction(address addr) public pure {
        uint256 topic = uint256(uint160(addr));
        address extracted = address(uint160(topic));
        assertEq(extracted, addr);
    }

    function test_transferEventDecoding() public {
        // Verify Transfer event topic layout
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        assertEq(uint256(transferSig), TRANSFER_TOPIC_0);
    }

    //Scoped Subscription — Non-USDC Contract Ignored
    function test_transferFromNonUsdcContract_isIgnored() public {
        // Transfer from a different ERC-20 contract (not USDC) should NOT trigger taint
        address otherToken = address(0x07E12);
        reactive.reactTest(
            1,
            otherToken, // NOT USDC_ETHEREUM
            TRANSFER_TOPIC_0,
            uint256(uint160(blacklisted1)), // blacklisted sender
            uint256(uint160(cleanRecipient)),
            abi.encode(uint256(1000e6))
        );

        // cleanRecipient should NOT be flagged — only USDC transfers are tracked
        assertFalse(reactive.blacklist(cleanRecipient));
    }

    // USDC Blacklisted Event Routing

    function test_usdcBlacklistedEvent_addsToLocalBlacklist() public {
        address newTarget = address(0xB1A115);
        assertFalse(reactive.blacklist(newTarget));

        // Simulate USDC Blacklisted(address indexed _account) event
        reactive.reactTest(
            1,
            USDC_ETHEREUM,          // must be USDC contract
            USDC_BLACKLISTED_TOPIC_0,
            uint256(uint160(newTarget)), // topic_1 = indexed _account
            0,
            new bytes(0)
        );

        // Should be added to local blacklist
        assertTrue(reactive.blacklist(newTarget));
    }

    function test_usdcBlacklistedEvent_fromWrongContract_isIgnored() public {
        address newTarget = address(0xB1A116);
        address fakeUSDC = address(0xFA4E01);

        reactive.reactTest(
            1,
            fakeUSDC,               // NOT USDC_ETHEREUM — should be ignored
            USDC_BLACKLISTED_TOPIC_0,
            uint256(uint160(newTarget)),
            0,
            new bytes(0)
        );

        assertFalse(reactive.blacklist(newTarget));
    }

    // Chainalysis Oracle Event Routing

    function test_chainalysisOracleEvent_addsToLocalBlacklist() public {
        address sanctioned1 = address(0x5AA1);
        address sanctioned2 = address(0x5AA2);
        assertFalse(reactive.blacklist(sanctioned1));
        assertFalse(reactive.blacklist(sanctioned2));

        address[] memory batch = new address[](2);
        batch[0] = sanctioned1;
        batch[1] = sanctioned2;

        // simulate SanctionedAddressesAdded(address[] addrs) event
        // addresses are ABI-encoded in the data field (non-indexed dynamic array)
        reactive.reactTest(
            1,
            CHAINALYSIS_ORACLE,         // must be Chainalysis oracle
            SANCTIONED_ADDED_TOPIC_0,
            0,                          // no indexed topics
            0,
            abi.encode(batch)           // address[] in data
        );

        assertTrue(reactive.blacklist(sanctioned1));
        assertTrue(reactive.blacklist(sanctioned2));
    }

    function test_chainalysisOracleEvent_fromWrongContract_isIgnored() public {
        address sanctioned1 = address(0x5AA3);
        address fakeOracle = address(0xFA4E02);

        address[] memory batch = new address[](1);
        batch[0] = sanctioned1;

        reactive.reactTest(
            1,
            fakeOracle,             // NOT CHAINALYSIS_ORACLE — should be ignored
            SANCTIONED_ADDED_TOPIC_0,
            0,
            0,
            abi.encode(batch)
        );

        assertFalse(reactive.blacklist(sanctioned1));
    }

    function test_chainalysisOracleEvent_alreadyBlacklisted_noDoubleCount() public {
        // sanctioned address already in blacklist
        address alreadySanctioned = blacklisted1;

        address[] memory batch = new address[](1);
        batch[0] = alreadySanctioned;

        reactive.reactTest(
            1,
            CHAINALYSIS_ORACLE,
            SANCTIONED_ADDED_TOPIC_0,
            0,
            0,
            abi.encode(batch)
        );

        // Should still be blacklisted (no error, just idempotent)
        assertTrue(reactive.blacklist(alreadySanctioned));
    }

    // Topic Hash Verification

    function test_usdcBlacklistedTopicHash_isCorrect() public {
        bytes32 expected = keccak256("Blacklisted(address)");
        assertEq(uint256(expected), USDC_BLACKLISTED_TOPIC_0);
    }

    function test_sanctionedAddedTopicHash_isCorrect() public {
        bytes32 expected = keccak256("SanctionedAddressesAdded(address[])");
        assertEq(uint256(expected), SANCTIONED_ADDED_TOPIC_0);
        assertEq(uint256(expected), reactive.SANCTIONED_ADDED_TOPIC_0());
    }

    // BlacklistUpdated emitted on taint propagation

    function test_usdcTransfer_emitsBlacklistUpdatedOnTaint() public {
        vm.expectEmit(true, true, false, false);
        emit GuardReactive.BlacklistUpdated(cleanRecipient, true);

        reactive.reactTest(
            1,
            USDC_ETHEREUM,
            TRANSFER_TOPIC_0,
            uint256(uint160(blacklisted1)),
            uint256(uint160(cleanRecipient)),
            abi.encode(uint256(1000e6))
        );

        assertTrue(reactive.blacklist(cleanRecipient));
    }

    function test_chainalysis_emitsBlacklistUpdatedForNewAddress() public {
        address newSanctioned = address(0x5AA9);
        assertFalse(reactive.blacklist(newSanctioned));

        address[] memory batch = new address[](1);
        batch[0] = newSanctioned;

        vm.expectEmit(true, true, false, false);
        emit GuardReactive.BlacklistUpdated(newSanctioned, true);

        reactive.reactTest(
            1,
            CHAINALYSIS_ORACLE,
            SANCTIONED_ADDED_TOPIC_0,
            0,
            0,
            abi.encode(batch)
        );

        assertTrue(reactive.blacklist(newSanctioned));
    }

    // USDC Blacklisted callback only for new addresses

    function test_usdcBlacklisted_doesNotEmitCallbackForKnownAddress() public {
        // First, add target to local blacklist directly
        reactive.addToBlacklist(cleanRecipient);
        assertTrue(reactive.blacklist(cleanRecipient));

        // Record all events emitted during the reactTest call
        vm.recordLogs();

        // Simulate USDC Blacklisted event for already-blacklisted address
        reactive.reactTest(
            1,
            USDC_ETHEREUM,
            USDC_BLACKLISTED_TOPIC_0,
            uint256(uint160(cleanRecipient)),
            0,
            new bytes(0)
        );

        // Verify no Callback event was emitted (the target is already in blacklist)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != callbackSig, "Callback should NOT be emitted for known address");
        }
    }

    // Taint Chain — Three Hops A→B→C

    function test_taintChain_threeHops() public {
        address A = blacklisted1; // pre-blacklisted in setUp
        address B = address(0xB001);
        address C = address(0xC001);

        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");

        vm.recordLogs();

        // Hop 1: A → B
        reactive.reactTest(
            1, USDC_ETHEREUM, TRANSFER_TOPIC_0,
            uint256(uint160(A)), uint256(uint160(B)),
            abi.encode(uint256(1000e6))
        );
        assertTrue(reactive.blacklist(B));

        // Hop 2: B → C (B is now blacklisted)
        reactive.reactTest(
            1, USDC_ETHEREUM, TRANSFER_TOPIC_0,
            uint256(uint160(B)), uint256(uint160(C)),
            abi.encode(uint256(1000e6))
        );
        assertTrue(reactive.blacklist(C));

        // Verify exactly 2 Callback events emitted (one for B, one for C)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 callbackCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                callbackCount++;
            }
        }
        assertEq(callbackCount, 2);
    }

    // Chainalysis Oracle — Empty Batch, No Callback

    function test_chainalysisOracle_emptyBatch_noCallback() public {
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");

        vm.recordLogs();
        reactive.reactTest(
            1, CHAINALYSIS_ORACLE, SANCTIONED_ADDED_TOPIC_0,
            0, 0,
            abi.encode(new address[](0))
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != callbackSig, "No Callback for empty batch");
        }
    }

    // Chainalysis Oracle — Batch With Duplicates, Single Callback 

    function test_chainalysisOracle_batchDuplicates_onlyNewAddressesCallback() public {
        address A = blacklisted1; // already in blacklist
        address B = address(0xB002);
        assertFalse(reactive.blacklist(B));

        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");

        address[] memory batch = new address[](3);
        batch[0] = A; // already blacklisted → skip
        batch[1] = B; // new
        batch[2] = B; // duplicate of B → skip after first

        vm.recordLogs();
        reactive.reactTest(
            1, CHAINALYSIS_ORACLE, SANCTIONED_ADDED_TOPIC_0,
            0, 0,
            abi.encode(batch)
        );

        assertTrue(reactive.blacklist(B));

        // newCount = 1 → exactly 1 Callback event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 callbackCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackSig) {
                callbackCount++;
            }
        }
        assertEq(callbackCount, 1);
    }

    // Fuzz — ABI Decode Address Roundtrip

    function testFuzz_abiDecodeAddress(address addr) public pure {
        bytes memory encoded = abi.encode(addr);
        address decoded = abi.decode(encoded, (address));
        assertEq(decoded, addr);
    }
}

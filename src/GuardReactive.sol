// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/AbstractReactive.sol";

// guardReactive
// Monitors targeted ERC-20 events on Ethereum for compliance enforcement.
// Subscribes to:
//   1. USDC Transfer events — taint propagation (blacklisted sender → flag recipient as SuspiciousNew)
//   2. Chainalysis SanctionedAddressesAdded — auto-sync OFAC SDN list into RiskRegistry
//   3. USDC Blacklisted event — auto-block any address Circle blacklists
contract GuardReactive is AbstractReactive {

    // Origin and destination chain IDs for cross-chain callbacks (e.g. Ethereum → Unichain)
    // Ethereum (1 or 11155111)
    uint256 public immutable ORIGIN_CHAIN_ID;   
    // Unichain (130 or 1301)
    uint256 public immutable DEST_CHAIN_ID;     

    uint64 public constant CALLBACK_GAS_LIMIT = 300000;

    // ERC-20 Transfer(address indexed from, address indexed to, uint256 value)
    uint256 public constant TRANSFER_TOPIC_0 =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // USDC FiatTokenV2 Blacklisted(address indexed _account)
    // = keccak256("Blacklisted(address)")
    uint256 public constant USDC_BLACKLISTED_TOPIC_0 =
        0xffa4e6181777692565cf28528fc88fd1516ea86b56da075235fa575af6a4b855;

    // Chainalysis SanctionsList SanctionedAddressesAdded(address[])
    // Computed at compile time via keccak256
    uint256 public constant SANCTIONED_ADDED_TOPIC_0 =
        uint256(keccak256("SanctionedAddressesAdded(address[])"));

    // USDC address on the origin chain — set at deploy time
    // Sepolia: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238).
    address public immutable USDC_ETHEREUM;

    // Chainalysis SanctionsList oracle
    address public constant CHAINALYSIS_ORACLE = 0x40C57923924B5c5c5455c48D93317139ADDaC8fb;

    // State 
    mapping(address => bool) public blacklist;
    address public callbackContract;
    address public owner;

    // Events
    event TaintPropagated(address indexed from, address indexed to, uint256 chainId);
    event OracleSanctionDetected(address indexed target, uint256 chainId);
    event UsdcBlacklistDetected(address indexed target, uint256 chainId);
    event BlacklistUpdated(address indexed target, bool status);
    event Subscribed(uint256 timestamp);

    // Errors
    error OnlyOwner();
    error AlreadySubscribed();

    // Whether subscribeAll() has been called
    bool public subscribed;

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(
        address[] memory _initialBlacklist,
        address _callbackContract,
        uint256 _originChainId,
        uint256 _destChainId,
        address _usdcAddress
    ) payable {
        owner = msg.sender;
        callbackContract = _callbackContract;
        ORIGIN_CHAIN_ID = _originChainId;
        DEST_CHAIN_ID = _destChainId;
        USDC_ETHEREUM = _usdcAddress;

        for (uint256 i = 0; i < _initialBlacklist.length; i++) {
            blacklist[_initialBlacklist[i]] = true;
            emit BlacklistUpdated(_initialBlacklist[i], true);
        }
    }

    // Register subscriptions on the Reactive Network after the contract is deployed and funded.
    // Call this once from the deployer after sending ETH to the contract.
    // Idempotent guard prevents double-subscription.
    // This runs on the Reactive Network only (not in tests or on destination chains).
    function subscribeAll() external onlyOwner {
        if (subscribed) revert AlreadySubscribed();
        subscribed = true;

        // 1. USDC Transfer events — taint propagation
        service.subscribe(
            ORIGIN_CHAIN_ID,
            USDC_ETHEREUM,
            TRANSFER_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // 2. Chainalysis oracle — OFAC SDN list sync
        service.subscribe(
            ORIGIN_CHAIN_ID,
            CHAINALYSIS_ORACLE,
            SANCTIONED_ADDED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // 3. USDC Blacklisted events — Circle compliance sync
        service.subscribe(
            ORIGIN_CHAIN_ID,
            USDC_ETHEREUM,
            USDC_BLACKLISTED_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        emit Subscribed(block.timestamp);
    }

    // route incoming log records to the appropriate handler.
    // routes by topic_0 and the emitting contract address for defense-in-depth.
    function react(LogRecord calldata log) external vmOnly {
        if (log.topic_0 == TRANSFER_TOPIC_0 && log._contract == USDC_ETHEREUM) {
            _handleUsdcTransfer(log);
        } else if (log.topic_0 == SANCTIONED_ADDED_TOPIC_0 && log._contract == CHAINALYSIS_ORACLE) {
            _handleChainalysisSanctions(log);
        } else if (log.topic_0 == USDC_BLACKLISTED_TOPIC_0 && log._contract == USDC_ETHEREUM) {
            _handleUsdcBlacklisted(log);
        }
    }

    // handle USDC Transfer events for taint propagation.
    // If sender is blacklisted and recipient is not, flag the recipient as SuspiciousNew.
    function _handleUsdcTransfer(LogRecord calldata log) internal {
        address from = address(uint160(log.topic_1));
        address to = address(uint160(log.topic_2));

        if (blacklist[from] && !blacklist[to]) {
            // Mark recipient as tainted in local VM blacklist
            blacklist[to] = true;
            // allows off-chain indexers to re-seed after RSC restart
            emit BlacklistUpdated(to, true);

            emit TaintPropagated(from, to, log.chain_id);

            // Emit callback to flag the recipient as SuspiciousNew (0.75% surcharge tier)
            // on Unichain — lighter than Flagged (3%) since this may be a dust-attack victim
            bytes memory payload = abi.encodeWithSignature(
                "flagSuspicious(address,address,address,uint256)",
                // replaced by Reactive Network with RVM ID
                address(0),
                to,
                from,
                log.chain_id
            );
            emit Callback(DEST_CHAIN_ID, callbackContract, CALLBACK_GAS_LIMIT, payload);
        }
    }

    // handle Chainalysis SanctionedAddressesAdded events.
    // decodes the address array from log.data and emits a batch-block callback.
    // each newly sanctioned address gets Blocked tier in RiskRegistry (not just Flagged).
    function _handleChainalysisSanctions(LogRecord calldata log) internal {

        // SanctionedAddressesAdded(address[] addrs) — addrs is non-indexed, in log.data
        address[] memory sanctioned = abi.decode(log.data, (address[]));

        // Update local blacklist and track new additions
        uint256 newCount = 0;
        for (uint256 i = 0; i < sanctioned.length; i++) {
            if (!blacklist[sanctioned[i]]) {
                blacklist[sanctioned[i]] = true;
                // allows off-chain indexers to re-seed after RSC restart
                emit BlacklistUpdated(sanctioned[i], true);
                emit OracleSanctionDetected(sanctioned[i], log.chain_id);
                newCount++;
            }
        }

        if (newCount > 0) {
            // Emit a single batch callback to block all newly sanctioned addresses on Unichain
            bytes memory payload = abi.encodeWithSignature(
                "blockAddressBatch(address,address[])",
                // replaced by Reactive Network with RVM ID
                address(0),
                sanctioned
            );
            emit Callback(DEST_CHAIN_ID, callbackContract, CALLBACK_GAS_LIMIT, payload);
        }
    }

    // handle USDC Blacklisted(address indexed _account) events
    // Circle only blacklists addresses with confirmed legal orders
    // These get Blocked tier — zero false positive risk
    function _handleUsdcBlacklisted(LogRecord calldata log) internal {
        // indexed → topic_1
        address target = address(uint160(log.topic_1)); 

        if (!blacklist[target]) {
            blacklist[target] = true;
            emit UsdcBlacklistDetected(target, log.chain_id);
            // allows off-chain indexers to re-seed after RSC restart
            emit BlacklistUpdated(target, true);

            // Only emit callback for new additions
            // idempotent guard prevents duplicate callbacks
            bytes memory payload = abi.encodeWithSignature(
                "blockFromUsdcBlacklist(address,address)",
                address(0), 
                target
            );
            emit Callback(DEST_CHAIN_ID, callbackContract, CALLBACK_GAS_LIMIT, payload);
        }
    }

    // Owner Functions

    // add a single address to the blacklist
    function addToBlacklist(address target) external onlyOwner {
        blacklist[target] = true;
        emit BlacklistUpdated(target, true);
    }

    // add multiple addresses to the blacklist in one transaction
    function batchAddToBlacklist(address[] calldata targets) external onlyOwner {
        for (uint256 i = 0; i < targets.length; i++) {
            blacklist[targets[i]] = true;
            emit BlacklistUpdated(targets[i], true);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractCallback} from "reactive-lib/AbstractCallback.sol";

interface IRiskRegistry {
    function flagAddress(address target, address source, uint256 sourceChainId) external;
    function flagSuspicious(address target, address source, uint256 sourceChainId) external;
    function blockFromOracle(address target, bytes32 oracleName) external;
    function batchBlockFromOracle(address[] calldata targets, bytes32 oracleName) external;
}

// GuardCallback
contract GuardCallback is AbstractCallback {
    IRiskRegistry public immutable registry;

    // Oracle name identifiers
    bytes32 public constant ORACLE_CHAINALYSIS = "CHAINALYSIS";
    bytes32 public constant ORACLE_USDC_BLACKLIST = "USDC_BLACKLIST";

    // Events
    event AddressFlagRelayed(address indexed target, address indexed source, uint256 sourceChainId);
    event AddressSuspiciousFlagRelayed(address indexed target, address indexed source, uint256 sourceChainId);
    event AddressBlockedFromOracle(address indexed target, bytes32 oracleName);
    event AddressBatchBlockedFromOracle(uint256 count, bytes32 oracleName);

    constructor(address _callbackProxy, address _registry) AbstractCallback(_callbackProxy) {
        registry = IRiskRegistry(_registry);
    }

    // Flag an address as Flagged
    function flagAddress(address _rvm_id, address target, address source, uint256 sourceChainId)
        external
        rvmIdOnly(_rvm_id)
    {
        registry.flagAddress(target, source, sourceChainId);
        emit AddressFlagRelayed(target, source, sourceChainId);
    }

    // Flag an address as SuspiciousNew (USDC taint propagation).
    function flagSuspicious(address _rvm_id, address target, address source, uint256 sourceChainId)
        external
        rvmIdOnly(_rvm_id)
    {
        registry.flagSuspicious(target, source, sourceChainId);
        emit AddressSuspiciousFlagRelayed(target, source, sourceChainId);
    }

    // Block a single address from a USDC Blacklisted event.
    // Called when the USDC contract emits Blacklisted(address indexed _account).
    function blockFromUsdcBlacklist(address _rvm_id, address target)
        external
        rvmIdOnly(_rvm_id)
    {
        registry.blockFromOracle(target, ORACLE_USDC_BLACKLIST);
        emit AddressBlockedFromOracle(target, ORACLE_USDC_BLACKLIST);
    }

    // Block multiple addresses from a Chainalysis SanctionedAddressesAdded event.
    // Called when the Chainalysis oracle syncs the OFAC SDN list on Ethereum.
    function blockAddressBatch(address _rvm_id, address[] calldata targets)
        external
        rvmIdOnly(_rvm_id)
    {
        registry.batchBlockFromOracle(targets, ORACLE_CHAINALYSIS);
        emit AddressBatchBlockedFromOracle(targets.length, ORACLE_CHAINALYSIS);
    }
}

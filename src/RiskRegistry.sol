// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// riskRegistry
// on-chain blacklist and risk-level registry for cross-chain compliance
// four risk tiers: Clean, SuspiciousNew (taint-propagated), Flagged (confirmed), Blocked (sanctioned)
// Other protocols can query this contract to check whether an address is blocked or flagged.
contract RiskRegistry {

    // 0 = Clean, 1 = SuspiciousNew, 2 = Flagged, 3 = Blocked
    enum RiskLevel { Clean, SuspiciousNew, Flagged, Blocked }

    // Events
    event AddressBlocked(address indexed target, uint256 timestamp);
    event AddressFlagged(address indexed target, address indexed source, uint256 sourceChainId, uint256 timestamp);
    event AddressFlaggedSuspicious(address indexed target, address indexed source, uint256 sourceChainId, uint256 timestamp);
    event OracleSyncBatch(address indexed oracle, uint256 count, uint256 timestamp);
    event AddressCleared(address indexed target, uint256 timestamp);
    event CallbackContractSet(address indexed callbackContract);
    event WhitelistUpdated(address indexed account, bool status);
    event IdentityVerifiedUpdated(address indexed account, bool status);
    event AppealRequested(address indexed target, uint256 timestamp);
    event SuspiciousExpired(address indexed target, uint256 timestamp);

    // Errors
    error OnlyOwner();
    error OnlyCallback();
    error CallbackAlreadySet();
    error ZeroAddress();
    error NotSuspicious();
    error NoExpiryConfigured();
    error NotExpiredYet(uint256 expiresAt);

    // State
    mapping(address => RiskLevel) public riskLevels;
    mapping(address => uint256) public flaggedAt;
    mapping(address => address) public flaggedBy;
    // which oracle flagged this address
    mapping(address => bytes32) public flagSource;       
    mapping(address => bool) public whitelist;
    // positive attestation layer
    mapping(address => bool) public identityVerified;    
    address public owner;
    address public callbackContract;
    uint256 public totalFlagged;
    uint256 public totalBlocked;
    // 0 = disabled; SuspiciousNew auto-clears after this
    uint256 public suspiciousExpiryPeriod = 30 days;

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyCallback() {
        if (msg.sender != callbackContract) revert OnlyCallback();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // add an address to the blacklist (Blocked risk level)
    function addToBlacklist(address target) external onlyOwner {
        if (riskLevels[target] != RiskLevel.Blocked) {
            riskLevels[target] = RiskLevel.Blocked;
            totalBlocked++;
            emit AddressBlocked(target, block.timestamp);
        }
    }

    // add multiple addresses to the blacklist in one transaction
    function batchAddToBlacklist(address[] calldata targets) external onlyOwner {
        for (uint256 i = 0; i < targets.length; i++) {
            if (riskLevels[targets[i]] != RiskLevel.Blocked) {
                riskLevels[targets[i]] = RiskLevel.Blocked;
                totalBlocked++;
                emit AddressBlocked(targets[i], block.timestamp);
            }
        }
    }

    // remove an address from the blacklist and clear flagging metadata
    function removeFromBlacklist(address target) external onlyOwner {
        if (riskLevels[target] == RiskLevel.Blocked) {
            totalBlocked--;
        }
        riskLevels[target] = RiskLevel.Clean;
        flaggedAt[target] = 0;
        flaggedBy[target] = address(0);
        flagSource[target] = bytes32(0);
        emit AddressCleared(target, block.timestamp);
    }

    // link the callback relay contract. Can only be set once
    function setCallbackContract(address _cb) external onlyOwner {
        if (_cb == address(0)) revert ZeroAddress();
        if (callbackContract != address(0)) revert CallbackAlreadySet();
        callbackContract = _cb;
        emit CallbackContractSet(_cb);
    }

    // set or remove an address from the whitelist
    function setWhitelist(address account, bool status) external onlyOwner {
        whitelist[account] = status;
        emit WhitelistUpdated(account, status);
    }

    // mark an address as identity-verified (via EAS, World ID, etc.)
    // Verified addresses bypass risk surcharges in GuardHook (treated as whitelisted)
    function setIdentityVerified(address account, bool status) external onlyOwner {
        identityVerified[account] = status;
        emit IdentityVerifiedUpdated(account, status);
    }

    // set the SuspiciousNew auto-expiry period. Set to 0 to disable
    function setSuspiciousExpiryPeriod(uint256 _period) external onlyOwner {
        suspiciousExpiryPeriod = _period;
    }

    // flag an address as Flagged (3% surcharge tier) directly via owner
    // Escalates Clean → Flagged and SuspiciousNew → Flagged
    // Does not downgrade a Blocked address
    // Uses the same totalFlagged double-count prevention as the callback path
    function flagAddressDirect(address target, address source) external onlyOwner {
        if (riskLevels[target] < RiskLevel.Flagged) {
            bool wasSuspicious = riskLevels[target] == RiskLevel.SuspiciousNew;
            riskLevels[target] = RiskLevel.Flagged;
            flaggedAt[target] = block.timestamp;
            flaggedBy[target] = source;
            if (!wasSuspicious) {
                totalFlagged++;
            }
            emit AddressFlagged(target, source, block.chainid, block.timestamp);
        }
    }

    // request owner review of a SuspiciousNew classification
    function requestAppeal() external {
        if (riskLevels[msg.sender] != RiskLevel.SuspiciousNew) revert NotSuspicious();
        emit AppealRequested(msg.sender, block.timestamp);
    }

    // clear a SuspiciousNew address to Clean once the expiry period has elapsed
    // permissionless — anyone can call
    // expiry period is owner-configured
    function expireSuspicious(address target) external {
        if (riskLevels[target] != RiskLevel.SuspiciousNew) revert NotSuspicious();
        if (suspiciousExpiryPeriod == 0) revert NoExpiryConfigured();
        uint256 expiresAt = flaggedAt[target] + suspiciousExpiryPeriod;
        if (block.timestamp < expiresAt) revert NotExpiredYet(expiresAt);
        riskLevels[target] = RiskLevel.Clean;
        emit SuspiciousExpired(target, block.timestamp);
    }

    // called by the callback contract to flag an address as tainted (SuspiciousNew tier)
    // used for USDC taint propagation from Reactive Network
    // does not downgrade a Flagged or Blocked address
    function flagSuspicious(address target, address source, uint256 sourceChainId) external onlyCallback {
        if (riskLevels[target] == RiskLevel.Clean) {
            riskLevels[target] = RiskLevel.SuspiciousNew;
            flaggedAt[target] = block.timestamp;
            flaggedBy[target] = source;
            flagSource[target] = "USDC_TAINT";
            totalFlagged++;
            emit AddressFlaggedSuspicious(target, source, sourceChainId, block.timestamp);
        }
    }

    // called by the callback contract to flag an address as Flagged
    // escalates Clean → Flagged and SuspiciousNew → Flagged (without double-counting totalFlagged).
    // does not downgrade a Blocked address to Flagged.
    function flagAddress(address target, address source, uint256 sourceChainId) external onlyCallback {
        if (riskLevels[target] < RiskLevel.Flagged) {
            bool wasSuspicious = riskLevels[target] == RiskLevel.SuspiciousNew;
            riskLevels[target] = RiskLevel.Flagged;
            flaggedAt[target] = block.timestamp;
            flaggedBy[target] = source;
            if (!wasSuspicious) {
                // SuspiciousNew already counted;
                // only increment for Clean→Flagged
                totalFlagged++; 
            }
            emit AddressFlagged(target, source, sourceChainId, block.timestamp);
        }
    }

    // called by the callback contract to block a single address from an oracle source.
    // used for USDC Blacklisted events relayed from Reactive Network.
    function blockFromOracle(address target, bytes32 oracleName) external onlyCallback {
        if (riskLevels[target] != RiskLevel.Blocked) {
            riskLevels[target] = RiskLevel.Blocked;
            totalBlocked++;
            flagSource[target] = oracleName;
            emit AddressBlocked(target, block.timestamp);
        }
    }

    // called by the callback contract to block multiple addresses from an oracle source
    // used for Chainalysis SanctionedAddressesAdded events relayed from Reactive Network
    function batchBlockFromOracle(address[] calldata targets, bytes32 oracleName) external onlyCallback {
        uint256 newlyBlocked;
        for (uint256 i = 0; i < targets.length; i++) {
            if (riskLevels[targets[i]] != RiskLevel.Blocked) {
                riskLevels[targets[i]] = RiskLevel.Blocked;
                totalBlocked++;
                flagSource[targets[i]] = oracleName;
                newlyBlocked++;
                emit AddressBlocked(targets[i], block.timestamp);
            }
        }
        if (newlyBlocked > 0) {
            emit OracleSyncBatch(msg.sender, newlyBlocked, block.timestamp);
        }
    }

    // check if an address is blocked
    function isBlocked(address account) external view returns (bool) {
        return riskLevels[account] == RiskLevel.Blocked;
    }

    // check if an address is flagged (Flagged tier only, not SuspiciousNew)
    function isFlagged(address account) external view returns (bool) {
        return riskLevels[account] == RiskLevel.Flagged;
    }

    // check if an address is in the SuspiciousNew tier
    function isSuspicious(address account) external view returns (bool) {
        return riskLevels[account] == RiskLevel.SuspiciousNew;
    }

    // check if an address is clean (not flagged or blocked)
    function isClean(address account) external view returns (bool) {
        return riskLevels[account] == RiskLevel.Clean;
    }

    // get the risk level of an address
    function getRiskLevel(address account) external view returns (RiskLevel) {
        return riskLevels[account];
    }

    // check if an address is whitelisted (bypasses risk checks)
    function isWhitelisted(address account) external view returns (bool) {
        return whitelist[account];
    }

    // get the risk levels of multiple addresses in a single call
    function batchGetRiskLevel(address[] calldata accounts) external view returns (RiskLevel[] memory) {
        RiskLevel[] memory levels = new RiskLevel[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            levels[i] = riskLevels[accounts[i]];
        }
        return levels;
    }
}

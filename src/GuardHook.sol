// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {RiskRegistry} from "./RiskRegistry.sol";

// Chainalysis SanctionsList — same address on all major EVM chains
interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

// Ethereum Attestation Service (EAS) interface
// for positive identity checks via Coinbase attestation indexer
interface IEAS {
    struct Attestation {
        bytes32 uid;
        bytes32 schema;
        uint64 time;
        uint64 expirationTime;
        uint64 revocationTime;
        bytes32 refUID;
        address recipient;
        address attester;
        bool revocable;
        bytes data;
    }
    function getAttestation(bytes32 uid) external view returns (Attestation memory);
}

// Coinbase EAS Attestation Indexer
// maps recipient → attestation UID
interface IAttestationIndexer {
    function getAttestationUid(address recipient, bytes32 schemaUid)
        external view returns (bytes32);
}

// GuardHook
// Uniswap v4 hook enforcing 4-tier compliance risk: Clean, SuspiciousNew, Flagged, Blocked.
// - Blocked (OFAC sanctioned): swap reverts
// - Flagged (confirmed taint): 3.00% surcharge
// - SuspiciousNew (possible dust-attack victim): 0.75% surcharge
// - Clean: base fee (0.30%)
// Also enforces LP holding periods, emits money flow audit events,
// and supports optional live checks against Chainalysis oracle and Coinbase EAS attestations.
contract GuardHook is BaseHook {

    using PoolIdLibrary for PoolKey;

    // Events
    event SwapSurcharged(address indexed account, uint24 fee, uint256 timestamp);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event MevTaxObserved(address indexed swapper, uint256 priorityFee, uint256 timestamp);
    event MoneyFlowRecorded(
        address indexed user,
        int128 amount0,
        int128 amount1,
        bytes32 indexed poolId,
        uint256 timestamp
    );
    event TravelRuleThresholdExceeded(
        address indexed user,
        uint128 absAmount,
        bytes32 indexed poolId,
        uint256 timestamp
    );
    event LPPositionTracked(
        address indexed provider,
        int128 amount0,
        int128 amount1,
        uint256 addedAt,
        bytes32 indexed poolId
    );
    event LPEarlyExitBlocked(
        address indexed provider,
        uint256 holdingElapsed,
        uint256 holdingRequired
    );
    event HoldingPeriodUpdated(uint256 newPeriod);

    // Errors
    error AddressBlocked(address account);
    error AddressFlaggedOrBlocked(address account);
    error EarlyExitBlocked(address provider, uint256 elapsed, uint256 required);
    error PoolMustUseDynamicFee();
    error OnlyOwner();
    error EnforcedPause();
    error ZeroAddress();
    error HookDataRequired();

    // Fee Constants
    // 0.30% — clean addresses
    uint24 public baseFee = 3000;  
    // 0.75% — SuspiciousNew tier             
    uint24 public constant SUSPICIOUS_FEE = 7500;
    // 3.00% — Flagged tier (10x base)  
    uint24 public constant SURCHARGE_FEE = 30000;  

    // Travel Rule Threshold
    // $1,000 in USDC (6 decimals) — FATF recommendation threshold
    uint128 public constant TRAVEL_RULE_THRESHOLD = 1_000 * 1e6;

    // Coinbase EAS Config (Base mainnet / OP Stack)
    // Mutable so it can be updated when deploying on chains where the Coinbase attester differs.
    address public coinbaseAttester = 0x357458739F90461b99789350868CD7CF330Dd7EE;
    // Schema UID for "Verified Account"
    // Coinbase KYC'd trading account
    bytes32 public constant VERIFIED_ACCOUNT_SCHEMA_UID =
        0xf8b05c79f090979bf4a80270aba232dff11a10d9ca55c4f88de95317970f0de9;

    // State
    RiskRegistry public immutable registry;
    uint256 public totalSwapsSurcharged; 
    uint256 public totalSuspiciousNewSurcharged;
    uint256 public totalMevTaxObserved;
    address public owner;
    bool public paused;
    bool public requireHookData;                

    // LP holding period enforcement
    uint256 public holdingPeriod = 24 hours;
    // [provider][poolId] → timestamp
    mapping(address => mapping(bytes32 => uint256)) public addedAt; 

    // Oracle addresses — set to address(0) to disable
    // live Chainalysis check per-swap
    address public chainalysisOracle; 
    // EAS predeploy (OP Stack 0x420...0021)   
    address public easContract;   
    // Coinbase attestation indexer       
    address public attestationIndexer;   

    // Modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(IPoolManager _poolManager, address _registry, address _owner) BaseHook(_poolManager) {
        registry = RiskRegistry(_registry);
        owner = _owner;
    }

    // Admin Functions

    // Pause the hook
    // all swaps and liquidity adds will revert until unpaused
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    // Unpause the hook
    // swaps and liquidity adds resume normal operation
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // Set the LP holding period. 
    // Set to 0 to disable holding period enforcement.
    // Duration in seconds (e.g., 24 hours = 86400)
    function setHoldingPeriod(uint256 _period) external onlyOwner {
        holdingPeriod = _period;
        emit HoldingPeriodUpdated(_period);
    }

    // Set the Chainalysis oracle address for live per-swap sanctions checks.
    // Set to address(0) to disable.
    // Chainalysis SanctionsList contract address on Unichain
    function setChainalysisOracle(address _oracle) external onlyOwner {
        chainalysisOracle = _oracle;
    }

    // Set the EAS contract and Coinbase attestation indexer addresses.
    // Set both to address(0) to disable positive identity checks.
    // needs the EAS predeploy address
    // needs the coinbase attestation indexer address
    function setEasContracts(address _eas, address _indexer) external onlyOwner {
        easContract = _eas;
        attestationIndexer = _indexer;
    }

    // Update the Coinbase EAS attester address for this chain.
    // Rquired when deploying on a chain where the Coinbase attester differs from Base mainnet.
    function setCoinbaseAttester(address _attester) external onlyOwner {
        if (_attester == address(0)) revert ZeroAddress();
        coinbaseAttester = _attester;
    }

    // Require that all swap/LP callers explicitly pass the user address via hookData.
    // Enable for pools where aggregators are expected to inject hookData.
    // When enabled, direct swaps without hookData will revert.
    function setRequireHookData(bool _require) external onlyOwner {
        requireHookData = _require;
    }

    // Hook Permissions
    // Returns the hook permission flags for the PoolManager
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- Hook Implementations ---

    // enforce that the pool uses the dynamic fee flag
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert PoolMustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    // resolves the effective user address.
    // Smart contract wallets and routers can pass the actual user via hookData (abi.encode(userAddr)).
    // Falls back to tx.origin for direct EOA swaps unless requireHookData is set.
    function _resolveUser(bytes calldata hookData) private view returns (address) {
        if (hookData.length >= 32) {
            return abi.decode(hookData, (address));
        }
        if (requireHookData) revert HookDataRequired();
        return tx.origin;
    }

    // check risk level of swapper: block, surcharge, or pass.
    // Risk check order:
    //  1. Whitelist / EAS attestation (bypass all checks → base fee)
    //  2. Chainalysis oracle live check (if configured → block if sanctioned)
    //  3. RiskRegistry tier: Blocked → revert, Flagged → 3%, SuspiciousNew → 0.75%, Clean → base
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (paused) revert EnforcedPause();

        address swapper = _resolveUser(hookData);

        // Step 1: Whitelist bypass
        if (registry.isWhitelisted(swapper) || registry.identityVerified(swapper)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Step 2: Coinbase EAS attestation check (positive identity layer)
        // If the swapper has a valid Coinbase "Verified Account" attestation, treat as whitelisted.
        if (easContract != address(0) && attestationIndexer != address(0)) {
            bytes32 uid = IAttestationIndexer(attestationIndexer)
                .getAttestationUid(swapper, VERIFIED_ACCOUNT_SCHEMA_UID);
            if (uid != bytes32(0)) {
                IEAS.Attestation memory att = IEAS(easContract).getAttestation(uid);
                bool valid = att.attester == coinbaseAttester
                          && att.revocationTime == 0
                          && (att.expirationTime == 0 || att.expirationTime > block.timestamp);
                if (valid) {
                    return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
                }
            }
        }

        // Step 3: Chainalysis oracle live check
        if (chainalysisOracle != address(0)) {
            if (ISanctionsList(chainalysisOracle).isSanctioned(swapper)) {
                revert AddressBlocked(swapper);
            }
        }

        // Step 4: RiskRegistry tier routing
        RiskRegistry.RiskLevel level = registry.getRiskLevel(swapper);

        if (level == RiskRegistry.RiskLevel.Blocked) {
            revert AddressBlocked(swapper);
        }

        if (level == RiskRegistry.RiskLevel.Flagged) {
            totalSwapsSurcharged++;
            emit SwapSurcharged(swapper, SURCHARGE_FEE, block.timestamp);
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, SURCHARGE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        if (level == RiskRegistry.RiskLevel.SuspiciousNew) {
            
            totalSuspiciousNewSurcharged++;
            emit SwapSurcharged(swapper, SUSPICIOUS_FEE, block.timestamp);
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, SUSPICIOUS_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Clean — apply base fee
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // Observe Unichain priority fee and emit money flow / Travel Rule events.
    // Priority fee (tx.gasprice - block.basefee) reflects MEV ordering value on Unichain's
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        // MEV tax observation
        if (tx.gasprice > block.basefee) {
            uint256 priorityFee = tx.gasprice - block.basefee;
            totalMevTaxObserved += priorityFee;
            emit MevTaxObserved(_resolveUser(hookData), priorityFee, block.timestamp);
        }

        // Money flow audit trail
        address user = _resolveUser(hookData);
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        bytes32 pid = PoolId.unwrap(key.toId());

        emit MoneyFlowRecorded(user, a0, a1, pid, block.timestamp);

        // Travel Rule threshold check — uses token1 amount as USD proxy for ETH/USDC pools.
        // Threshold: $1,000 USDC (6 decimals = 1,000,000,000 units).
        // Emits TravelRuleThresholdExceeded for off-chain compliance monitoring.
        uint128 absA1 = a1 < 0 ? uint128(-a1) : uint128(a1);
        if (absA1 >= TRAVEL_RULE_THRESHOLD) {
            emit TravelRuleThresholdExceeded(user, absA1, pid, block.timestamp);
        }

        return (this.afterSwap.selector, 0);
    }

    // Block flagged and blocked addresses from providing liquidity.
    // Also records addedAt timestamp for holding period enforcement.
    // Whitelisted and identity-verified addresses bypass checks.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4)
    {
        if (paused) revert EnforcedPause();

        address provider = _resolveUser(hookData);

        // Whitelist / identity bypass
        if (registry.isWhitelisted(provider) || registry.identityVerified(provider)) {
            _recordAddedAt(provider, key);
            return this.beforeAddLiquidity.selector;
        }

        RiskRegistry.RiskLevel level = registry.getRiskLevel(provider);

        if (level == RiskRegistry.RiskLevel.Blocked) {
            revert AddressBlocked(provider);
        }
        if (level == RiskRegistry.RiskLevel.Flagged) {
            revert AddressFlaggedOrBlocked(provider);
        }
        // SuspiciousNew and Clean can provide liquidity

        // Record first-add timestamp for holding period enforcement
        _recordAddedAt(provider, key);

        return this.beforeAddLiquidity.selector;
    }

    // Emit LP position tracking event after liquidity is added.
    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        address provider = _resolveUser(hookData);
        bytes32 pid = PoolId.unwrap(key.toId());
        emit LPPositionTracked(provider, delta.amount0(), delta.amount1(), block.timestamp, pid);
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // Enforce holding period before LP can remove liquidity.
    // Reverts early exits. Does NOT seize funds (avoids legal/griefing issues).
    // Set holdingPeriod = 0 to disable enforcement.
    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4)
    {
        address provider = _resolveUser(hookData);
        bytes32 pid = PoolId.unwrap(key.toId());
        uint256 entryTime = addedAt[provider][pid];

        if (holdingPeriod > 0 && entryTime != 0) {
            uint256 elapsed = block.timestamp - entryTime;
            if (elapsed < holdingPeriod) {
                emit LPEarlyExitBlocked(provider, elapsed, holdingPeriod);
                revert EarlyExitBlocked(provider, elapsed, holdingPeriod);
            }
        }

        return this.beforeRemoveLiquidity.selector;
    }

    // record first-add timestamp for a provider/pool pair. 
    // Only writes on first add.
    function _recordAddedAt(address provider, PoolKey calldata key) private {
        bytes32 pid = PoolId.unwrap(key.toId());
        if (addedAt[provider][pid] == 0) {
            addedAt[provider][pid] = block.timestamp;
        }
    }

    // returns all key protocol metrics in a single call 
    // for dashboard display
    function getProtocolStats()
        external
        view
        returns (
            uint24 _baseFee,
            uint24 _surchargeFee,
            uint24 _suspiciousFee,
            uint256 swapsSurcharged,
            uint256 suspiciousNewSurcharged,
            uint256 totalFlagged,
            bool isPaused,
            uint256 mevTaxObserved
        )
    {
        _baseFee = baseFee;
        _surchargeFee = SURCHARGE_FEE;
        _suspiciousFee = SUSPICIOUS_FEE;
        swapsSurcharged = totalSwapsSurcharged;
        suspiciousNewSurcharged = totalSuspiciousNewSurcharged;
        totalFlagged = registry.totalFlagged();
        isPaused = paused;
        mevTaxObserved = totalMevTaxObserved;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {RiskRegistry} from "../src/RiskRegistry.sol";
import {GuardHook} from "../src/GuardHook.sol";
import {GuardCallback} from "../src/GuardCallback.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// Deploys RiskRegistry + GuardHook + GuardCallback on Unichain
contract DeployGuard is Script {
    // Set PoolManager addresses by chain
    address immutable POOL_MANAGER = vm.envOr("POOL_MANAGER", address(0x00B036B58a818B1BC34d502D3fE730Db729e62AC));
    // Unichain callback proxy
    address constant CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;
    // Chainalysis SanctionsList 
    address constant CHAINALYSIS_ORACLE = address(0);
    // EAS predeploy
    // OP Stack 0x4200000000000000000000000000000000000021
    // set after verifying: cast code 0x4200...0021
    address constant EAS_PREDEPLOY = address(0); 
    // Coinbase attestation indexer (Base mainnet: 0x2c7eE1E5f416dfF40054c27A62f7B357C4E8619C)
    // set if EAS is available on Unichain
    address constant COINBASE_INDEXER = address(0); 

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Hook flags: beforeInitialize, beforeSwap, afterSwap, beforeAddLiquidity,
        //             afterAddLiquidity (LP tracking events), beforeRemoveLiquidity (holding period)
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy RiskRegistry
        RiskRegistry registry = new RiskRegistry();
        console.log("RiskRegistry deployed to:", address(registry));

        // 2. Mine hook address and deploy via CREATE2
        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), address(registry), deployer);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(GuardHook).creationCode,
            constructorArgs
        );
        console.log("Deploying GuardHook to:", hookAddress);

        GuardHook hook = new GuardHook{salt: salt}(IPoolManager(POOL_MANAGER), address(registry), deployer);
        require(address(hook) == hookAddress, "Hook address mismatch");

        // 3. Configure optional oracle integrations
        if (CHAINALYSIS_ORACLE != address(0)) {
            hook.setChainalysisOracle(CHAINALYSIS_ORACLE);
            console.log("Chainalysis oracle configured:", CHAINALYSIS_ORACLE);
        }
        if (EAS_PREDEPLOY != address(0) && COINBASE_INDEXER != address(0)) {
            hook.setEasContracts(EAS_PREDEPLOY, COINBASE_INDEXER);
            console.log("EAS contracts configured");
        }

        // 4. Deploy callback
        GuardCallback callback = new GuardCallback(CALLBACK_PROXY, address(registry));
        console.log("GuardCallback deployed to:", address(callback));

        // 5. Link callback to registry
        registry.setCallbackContract(address(callback));
        console.log("Callback linked to registry");

        // 6. Seed initial blacklist (optional)
        address[] memory initialList = new address[](0);
        if (initialList.length > 0) {
            registry.batchAddToBlacklist(initialList);
            console.log("Initial blacklist seeded");
        }

        vm.stopBroadcast();

        console.log("--- Deployment Summary ---");
        console.log("RiskRegistry:  ", address(registry));
        console.log("GuardHook:     ", address(hook));
        console.log("GuardCallback: ", address(callback));
        console.log("Hook flags:    ", flags);
    }
}

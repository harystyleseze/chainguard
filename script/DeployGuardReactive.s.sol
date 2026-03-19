// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {GuardReactive} from "../src/GuardReactive.sol";

// deploys GuardReactive on the Reactive Network
// Requires the following environment variables to be set:
//      REACTIVE_PRIVATE_KEY, CALLBACK_CONTRACT,
//      ORIGIN_CHAIN_ID (default 11155111), DEST_CHAIN_ID (default 1301),
//      USDC_ADDRESS (default Ethereum mainnet 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)
contract DeployGuardReactive is Script {
    function run() external payable {
        uint256 deployerPrivateKey = vm.envUint("REACTIVE_PRIVATE_KEY");
        address callbackContract = vm.envAddress("CALLBACK_CONTRACT");
        uint256 originChainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(11155111));
        uint256 destChainId = vm.envOr("DEST_CHAIN_ID", uint256(1301));
        // USDC_ADDRESS defaults to Ethereum
        // override with Sepolia (0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) for testnet
        address usdcAddress = vm.envOr("USDC_ADDRESS", address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

        // Initial blacklist
        address[] memory initialBlacklist = new address[](0);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy only. subscribeAll() is called separately via cast send (see below).
        //
        // WHY: service.subscribe() calls the Reactive Network's custom precompile at
        // address(0x64) to resolve the system contract implementation. Forge's EVM
        // simulation does not have this precompile and returns 0 bytes, causing
        // getSystemContractImpl() to revert with "Failure". On the real Lasna chain
        // the precompile exists and returns 32 bytes. So subscribeAll() must be sent
        // directly via cast send (no simulation), not through forge script.
        GuardReactive reactive = new GuardReactive{value: 1 ether}(
            initialBlacklist,
            callbackContract,
            originChainId,
            destChainId,
            usdcAddress
        );

        console.log("GuardReactive deployed to:", address(reactive));
        console.log("Origin chain ID:", originChainId);
        console.log("Dest chain ID:", destChainId);
        console.log("Callback contract:", callbackContract);
        console.log("USDC address:", usdcAddress);
        console.log("");
        console.log("NEXT STEP - register subscriptions (run this separately):");
        console.log("  cast send <ABOVE_ADDRESS> 'subscribeAll()' \\");
        console.log("    --rpc-url $REACTIVE_LASNA_RPC \\");
        console.log("    --private-key $REACTIVE_PRIVATE_KEY \\");
        console.log("    --gas 500000");
        console.log("(--gas bypasses eth_estimateGas simulation which lacks the 0x64 precompile)");

        vm.stopBroadcast();
    }
}

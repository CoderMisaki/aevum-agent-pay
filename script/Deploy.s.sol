// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentPay} from "../src/AgentPay.sol";

/// @notice Deploy AgentPay to QDay Aevum Testnet (chain 44005).
/// @dev Run with:
///   export DEPLOYER_KEY=$(python3 -c "import json;print(json.load(open('../.keys/payer.json'))['data'][0]['private_key'])")
///   forge script script/Deploy.s.sol --rpc-url https://rpc-test.qday.info --broadcast
/// The deployer key lives in ../.keys/ (mode 600) and is NEVER committed.
contract Deploy is Script {
    // Real tUSD8 on Aevum Testnet, verified on-chain (6 decimals).
    address constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (AgentPay agentPay) {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(deployerKey);

        agentPay = new AgentPay(TUSD8);

        vm.stopBroadcast();

        console.log("AgentPay deployed at:", address(agentPay));
        console.log("Token (tUSD8):", TUSD8);
        console.log("Deployer:", vm.addr(deployerKey));
        console.log("Explorer:", string.concat("https://explorer-test.qday.info/address/", vm.toString(address(agentPay))));
    }
}

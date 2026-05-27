// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { GCT } from "../src/GCT.sol";

contract TransferGCTToPlatform is Script {
    function run() external {
        GCT token = GCT(vm.envAddress("GCT_TOKEN"));
        address recipient = vm.envAddress("SUB2API_GCT_DEPOSIT_ADDRESS");
        uint256 amount = vm.envUint("SUB2API_GCT_DEPOSIT_AMOUNT");

        vm.startBroadcast();
        require(token.transfer(recipient, amount), "GCT transfer failed");
        vm.stopBroadcast();

        console2.log("GCT token:", address(token));
        console2.log("recipient:", recipient);
        console2.log("amount:", amount);
    }
}

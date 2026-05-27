// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IContinuousClearingAuction } from "../src/interfaces/IContinuousClearingAuction.sol";

contract ExitClaimGCTCCA is Script {
    function run() external {
        IContinuousClearingAuction auction =
            IContinuousClearingAuction(vm.envAddress("CCA_AUCTION"));
        uint256 bidId = vm.envUint("CCA_BID_ID");

        vm.startBroadcast();
        auction.exitBid(bidId);
        auction.claimTokens(bidId);
        vm.stopBroadcast();

        console2.log("CCA auction:", address(auction));
        console2.log("claimed bidId:", bidId);
    }
}

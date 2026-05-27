// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { GCT } from "../src/GCT.sol";
import { AuctionSteps } from "./AuctionSteps.sol";
import { AuctionParameters } from "../src/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "../src/interfaces/IContinuousClearingAuctionFactory.sol";
import { IDistributionContract } from "../src/interfaces/IDistributionContract.sol";

contract DeployGCTCCA is Script {
    function run() external returns (address auction) {
        GCT token = GCT(vm.envAddress("GCT_TOKEN"));
        IContinuousClearingAuctionFactory factory =
            IContinuousClearingAuctionFactory(vm.envAddress("CCA_FACTORY"));

        uint64 startBlock = uint64(block.number + vm.envOr("CCA_START_DELAY_BLOCKS", uint256(5)));
        uint64 durationBlocks = uint64(vm.envOr("CCA_DURATION_BLOCKS", uint256(7200)));
        uint64 endBlock = startBlock + durationBlocks;
        uint64 claimBlock = endBlock + uint64(vm.envOr("CCA_CLAIM_DELAY_BLOCKS", uint256(0)));

        AuctionParameters memory parameters = AuctionParameters({
            currency: vm.envAddress("CCA_CURRENCY"),
            tokensRecipient: vm.envAddress("CCA_TOKENS_RECIPIENT"),
            fundsRecipient: vm.envAddress("CCA_FUNDS_RECIPIENT"),
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: claimBlock,
            tickSpacing: vm.envUint("CCA_TICK_SPACING"),
            validationHook: vm.envAddress("CCA_VALIDATION_HOOK"),
            floorPrice: vm.envUint("CCA_FLOOR_PRICE_Q96"),
            requiredCurrencyRaised: uint128(vm.envOr("CCA_REQUIRED_CURRENCY_RAISED", uint256(0))),
            auctionStepsData: AuctionSteps.forDuration(durationBlocks)
        });

        uint256 auctionSupply = vm.envUint("GCT_AUCTION_SUPPLY");
        bytes32 salt = vm.envOr("CCA_SALT", bytes32(0));

        vm.startBroadcast();
        auction = factory.initializeDistribution(
            address(token), auctionSupply, abi.encode(parameters), salt
        );
        token.mint(auction, auctionSupply);
        IDistributionContract(auction).onTokensReceived();
        if (vm.envOr("GCT_FINALIZE_MINTING", false)) {
            token.finalizeMinting();
        }
        vm.stopBroadcast();

        console2.log("GCT token:", address(token));
        console2.log("CCA auction:", auction);
        console2.log("startBlock:", startBlock);
        console2.log("endBlock:", endBlock);
        console2.log("claimBlock:", claimBlock);
    }
}

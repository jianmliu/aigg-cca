// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { GCC } from "../src/GCC.sol";
import { GCCCCAToV4Seeder } from "../src/GCCCCAToV4Seeder.sol";
import { AuctionSteps } from "./AuctionSteps.sol";
import { AuctionParameters } from "../src/interfaces/IContinuousClearingAuction.sol";
import {
    IContinuousClearingAuctionFactory
} from "../src/interfaces/IContinuousClearingAuctionFactory.sol";
import { IDistributionContract } from "../src/interfaces/IDistributionContract.sol";

/// @dev When `CCA_V4_SEEDER_ENABLED=true`, the script deploys a
///      GCCCCAToV4Seeder, splits the GCC supply (`auction` gets the auction
///      share, `seeder` gets the LP reserve) and wires the seeder as both
///      `tokensRecipient` and `fundsRecipient` on the auction. After the
///      auction settles, the treasury multisig that owns the seeder calls
///      `bootstrap()` to initialise a Uniswap V4 USDC/GCC pool and seed it
///      with the collected USDC + LP reserve.
///
///      When the flag is off (legacy), the script behaves exactly as before.
contract DeployGCCCCA is Script {
    struct Recipients {
        address seederAddr;
        address tokensRecipient;
        address fundsRecipient;
        bool seederEnabled;
    }

    function run() external returns (address auction) {
        GCC token = GCC(vm.envAddress("GCC_TOKEN"));
        Recipients memory rec = _resolveRecipients(address(token));

        AuctionParameters memory parameters = _buildAuctionParameters(rec);
        uint256 totalSupply = vm.envUint("GCC_AUCTION_SUPPLY");
        uint256 lpReserve = _lpReserve(rec.seederEnabled, totalSupply);
        uint256 auctionSupply = totalSupply - lpReserve;

        auction = _runBroadcast(token, parameters, auctionSupply, rec, lpReserve);

        console2.log("GCC token:", address(token));
        console2.log("CCA auction:", auction);
        console2.log("auction supply:", auctionSupply);
        if (rec.seederEnabled) {
            address reuse = vm.envOr("CCA_V4_REUSE_SEEDER", address(0));
            console2.log("V4 seeder:", rec.seederAddr);
            console2.log(reuse == address(0) ? "  (newly deployed)" : "  (reused existing)");
            console2.log("LP reserve:", lpReserve);
        }
        console2.log("startBlock:", parameters.startBlock);
        console2.log("endBlock:", parameters.endBlock);
        console2.log("claimBlock:", parameters.claimBlock);
    }

    function _resolveRecipients(address gccToken) internal returns (Recipients memory rec) {
        rec.seederEnabled = vm.envOr("CCA_V4_SEEDER_ENABLED", false);
        if (rec.seederEnabled) {
            // Subsequent CCA rounds reuse the seeder that bootstrapped the V4
            // pool — same address tracks all liquidity over time, treasury
            // only manages one LP NFT collection. The first round deploys
            // a fresh seeder; later rounds set CCA_V4_REUSE_SEEDER to its
            // address and skip the deploy step entirely.
            address reuse = vm.envOr("CCA_V4_REUSE_SEEDER", address(0));
            rec.seederAddr = reuse == address(0) ? _deploySeeder(gccToken) : reuse;
            rec.tokensRecipient = rec.seederAddr;
            rec.fundsRecipient = rec.seederAddr;
        } else {
            rec.tokensRecipient = vm.envAddress("CCA_TOKENS_RECIPIENT");
            rec.fundsRecipient = vm.envAddress("CCA_FUNDS_RECIPIENT");
        }
    }

    function _buildAuctionParameters(Recipients memory rec)
        internal
        view
        returns (AuctionParameters memory p)
    {
        uint64 startBlock = uint64(block.number + vm.envOr("CCA_START_DELAY_BLOCKS", uint256(5)));
        uint64 durationBlocks = uint64(vm.envOr("CCA_DURATION_BLOCKS", uint256(7200)));
        uint64 endBlock = startBlock + durationBlocks;
        uint64 claimBlock = endBlock + uint64(vm.envOr("CCA_CLAIM_DELAY_BLOCKS", uint256(0)));

        p.currency = vm.envAddress("CCA_CURRENCY");
        p.tokensRecipient = rec.tokensRecipient;
        p.fundsRecipient = rec.fundsRecipient;
        p.startBlock = startBlock;
        p.endBlock = endBlock;
        p.claimBlock = claimBlock;
        p.tickSpacing = vm.envUint("CCA_TICK_SPACING");
        p.validationHook = vm.envAddress("CCA_VALIDATION_HOOK");
        p.floorPrice = vm.envUint("CCA_FLOOR_PRICE_Q96");
        p.requiredCurrencyRaised = uint128(vm.envOr("CCA_REQUIRED_CURRENCY_RAISED", uint256(0)));
        p.auctionStepsData = AuctionSteps.forDuration(durationBlocks);
    }

    /// @dev Bps of GCC reserved for the V4 LP seed (default 2000 = 20 %). The
    ///      remainder goes to the auction. When the seeder is disabled the
    ///      entire supply still flows through the auction (legacy behaviour).
    function _lpReserve(bool seederEnabled, uint256 totalSupply)
        internal
        view
        returns (uint256)
    {
        if (!seederEnabled) return 0;
        uint256 bps = vm.envOr("CCA_V4_LP_RESERVE_BPS", uint256(2000));
        require(bps <= 10_000, "CCA_V4_LP_RESERVE_BPS out of range");
        return (totalSupply * bps) / 10_000;
    }

    function _runBroadcast(
        GCC token,
        AuctionParameters memory parameters,
        uint256 auctionSupply,
        Recipients memory rec,
        uint256 lpReserve
    ) internal returns (address auction) {
        IContinuousClearingAuctionFactory factory =
            IContinuousClearingAuctionFactory(vm.envAddress("CCA_FACTORY"));
        bytes32 salt = vm.envOr("CCA_SALT", bytes32(0));

        vm.startBroadcast();
        auction = factory.initializeDistribution(
            address(token), auctionSupply, abi.encode(parameters), salt
        );
        token.mint(auction, auctionSupply);
        IDistributionContract(auction).onTokensReceived();
        if (rec.seederEnabled && lpReserve > 0) {
            token.mint(rec.seederAddr, lpReserve);
        }
        if (vm.envOr("GCC_FINALIZE_MINTING", false)) {
            token.finalizeMinting();
        }
        vm.stopBroadcast();
    }

    /// @dev Deploy the seeder. Pulls V4 contract addresses + pool params from
    ///      env. Treasury (`CCA_V4_TREASURY`) becomes the seeder owner and
    ///      receives the LP NFT after bootstrap.
    function _deploySeeder(address gccToken) internal returns (address) {
        // Read env vars into transient locals to avoid stack-too-deep in the
        // script's `run()` (the compiler's stack budget for a single function
        // is small; spreading these reads into a helper restores breathing
        // room).
        address usdc = vm.envAddress("CCA_V4_USDC");
        address pm = vm.envAddress("CCA_V4_POOL_MANAGER");
        address posm = vm.envAddress("CCA_V4_POSITION_MANAGER");
        uint24 fee = uint24(vm.envOr("CCA_V4_POOL_FEE", uint256(3000)));
        int24 spacing = int24(vm.envOr("CCA_V4_TICK_SPACING", int256(60)));
        address treasury = vm.envAddress("CCA_V4_TREASURY");

        vm.startBroadcast();
        GCCCCAToV4Seeder seeder = new GCCCCAToV4Seeder(
            gccToken, usdc, pm, posm, fee, spacing, treasury
        );
        vm.stopBroadcast();
        return address(seeder);
    }
}

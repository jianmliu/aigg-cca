// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IContinuousClearingAuction } from "../src/interfaces/IContinuousClearingAuction.sol";

interface IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IPermit2 {
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract BidGCTCCA is Script {
    address private constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (uint256 bidId) {
        IContinuousClearingAuction auction =
            IContinuousClearingAuction(vm.envAddress("CCA_AUCTION"));
        uint256 maxPrice = vm.envUint("CCA_BID_MAX_PRICE_Q96");
        uint128 amount = uint128(vm.envUint("CCA_BID_AMOUNT"));
        address owner = vm.envOr("CCA_BID_OWNER", msg.sender);
        bytes memory hookData = vm.envOr("CCA_BID_HOOK_DATA", bytes(""));
        IPermit2 permit2 = IPermit2(vm.envOr("PERMIT2", DEFAULT_PERMIT2));

        vm.startBroadcast();
        if (auction.currency() == address(0)) {
            bidId = auction.submitBid{ value: amount }(maxPrice, amount, owner, hookData);
        } else {
            IERC20 currency = IERC20(auction.currency());
            if (currency.allowance(msg.sender, address(permit2)) < amount) {
                if (!currency.approve(address(permit2), amount)) {
                    revert("CCA currency Permit2 approval failed");
                }
            }
            (uint160 permitAmount, uint48 expiration,) =
                permit2.allowance(msg.sender, address(currency), address(auction));
            if (permitAmount < amount || expiration <= block.timestamp) {
                permit2.approve(
                    address(currency), address(auction), uint160(amount), type(uint48).max
                );
            }
            bidId = auction.submitBid(maxPrice, amount, owner, hookData);
        }
        vm.stopBroadcast();

        console2.log("CCA auction:", address(auction));
        console2.log("bidId:", bidId);
        console2.log("owner:", owner);
        console2.log("amount:", amount);
        console2.log("maxPriceQ96:", maxPrice);
    }
}

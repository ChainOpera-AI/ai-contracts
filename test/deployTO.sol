// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../contracts/to_subscription.sol";

/// The initializer call an ERC1967 proxy is constructed with, separated out so a test can put
/// `vm.expectRevert` immediately before the proxy's construction.
function toInitCall(address receiver, address feeCollector, address terminator, address owner_)
    pure
    returns (bytes memory)
{
    return abi.encodeCall(TOSubscription.initialize, (receiver, feeCollector, terminator, owner_));
}

/// Deploy TOSubscription the way production does: implementation behind an ERC1967 proxy,
/// initialised in the same transaction, owned by a TimelockController deployed alongside.
function deployTOSubscription(
    address receiver,
    address feeCollector,
    address terminator,
    uint minDelay,
    address[] memory proposers,
    address[] memory executors,
    address admin
) returns (TOSubscription) {
    TimelockController tl = new TimelockController(minDelay, proposers, executors, admin);
    TOSubscription impl = new TOSubscription();
    bytes memory data = toInitCall(receiver, feeCollector, terminator, address(tl));
    return TOSubscription(address(new ERC1967Proxy(address(impl), data)));
}

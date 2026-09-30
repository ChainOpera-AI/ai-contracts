// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../contracts/subscription_fee_collector.sol";

/// The initializer call an ERC1967 proxy is constructed with. Separated out so a test can put
/// `vm.expectRevert` immediately before the proxy's construction, where the revert happens —
/// deploying the implementation first would otherwise consume the expectation.
function subscriptionInitCall(
    address receiver,
    address feeCollector,
    address terminator,
    address importer,
    address owner_
) pure returns (bytes memory) {
    return abi.encodeCall(Subscription.initialize, (receiver, feeCollector, terminator, importer, owner_));
}

/// Deploy Subscription the way production does: an implementation contract behind an ERC1967
/// proxy, initialised in the same transaction. Tests then drive the proxy address, so they
/// exercise the delegatecall path rather than a bare implementation.
/// The timelock is deployed here rather than inside initialize, which is how production does
/// it now — embedding TimelockController's creation code in the initializer cost 8.7KB of the
/// deployable limit. Test call sites keep the old argument list; only this helper knows.
function deploySubscription(
    address receiver,
    address feeCollector,
    address terminator,
    address importer,
    uint minDelay,
    address[] memory proposers,
    address[] memory executors,
    address admin
) returns (Subscription) {
    TimelockController tl = new TimelockController(minDelay, proposers, executors, admin);
    Subscription impl = new Subscription();
    bytes memory data = subscriptionInitCall(receiver, feeCollector, terminator, importer, address(tl));
    return Subscription(address(new ERC1967Proxy(address(impl), data)));
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../contracts/subscription_fee_collector.sol";

/// The subset of Foundry's cheatcode interface this script uses. Declared here rather than
/// pulled from forge-std, which this repo deliberately does not depend on.
interface VmScript {
    function envAddress(string calldata name) external view returns (address);
    function envAddress(string calldata name, string calldata delim) external view returns (address[] memory);
    function envUint(string calldata name) external view returns (uint256);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// Deploy Subscription to BSC.
///
/// Run this with --slow. BSC rejects gapped-nonce transactions from EIP-7702 delegated
/// accounts, and forge pushes every transaction at once by default, so a delegated deployer
/// gets its second transaction refused while the first is still pending. --slow waits for
/// each receipt. IMPL then lets a retry reuse whatever already landed.
///
/// Three transactions: a TimelockController (unless one is supplied to reuse), the Subscription
/// implementation, and an ERC1967 proxy that runs initialize in the same transaction. Only the
/// proxy address is ever used afterwards.
///
/// Every parameter comes from the environment so the script itself holds no addresses:
///
///   RECEIVER      where subscription payments land
///   FEE_COLLECTOR the hot key that calls renew/renewBatch
///   TERMINATOR    the key that can force-cancel a subscription
///   IMPORTER      the key allowed to call importAccounts (address(0) to leave imports shut)
///   IMPL          an already-deployed Subscription implementation to reuse; omit to deploy one
///   OWNER         the address to own the contract. Usually a TimelockController, but the
///                 contract only requires it to be non-zero -- a plain EOA is legitimate for a
///                 test deployment, and makes every owner call a single transaction instead of
///                 schedule() then execute(). Omit to deploy a fresh timelock from the values
///                 below. TIMELOCK is accepted as an older name for the same thing.
///   MIN_DELAY     new timelock only: seconds a queued call must wait (0 is allowed)
///   PROPOSERS     new timelock only: comma-separated addresses that may queue calls
///   EXECUTORS     new timelock only: comma-separated; the zero address means anyone may execute
///   TIMELOCK_ADMIN new timelock only: retains the right to reshuffle roles
contract Deploy {
    VmScript constant vm = VmScript(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function run() external {
        address receiver = vm.envAddress("RECEIVER");
        address feeCollector = vm.envAddress("FEE_COLLECTOR");
        address terminator = vm.envAddress("TERMINATOR");
        address importer = vm.envOr("IMPORTER", address(0));
        address owner_ = vm.envOr("OWNER", vm.envOr("TIMELOCK", address(0)));

        vm.startBroadcast();

        if (owner_ == address(0)) {
            owner_ = address(new TimelockController(
                vm.envUint("MIN_DELAY"),
                vm.envAddress("PROPOSERS", ","),
                vm.envAddress("EXECUTORS", ","),
                vm.envAddress("TIMELOCK_ADMIN")
            ));
        }

        address impl = vm.envOr("IMPL", address(0));
        if (impl == address(0)) impl = address(new Subscription());

        Subscription sub = Subscription(address(new ERC1967Proxy(
            impl,
            abi.encodeCall(Subscription.initialize, (receiver, feeCollector, terminator, importer, owner_))
        )));

        vm.stopBroadcast();

        // Nothing is left to configure: initialize sets every role, price, period, discount
        // and the trial, and turns the switch on. The deployer holds no power at any point.
        _report(address(sub), impl, owner_, importer);
    }

    event Deployed(address proxy, address implementation, address owner, address importerToSet);

    function _report(address proxy, address impl, address owner_, address importer) private {
        emit Deployed(proxy, impl, owner_, importer);
    }
}

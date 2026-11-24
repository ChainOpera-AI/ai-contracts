// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../contracts/to_subscription.sol";

/// The subset of Foundry's cheatcode interface this script uses.
interface VmScriptTO {
    function envAddress(string calldata name) external view returns (address);
    function envAddress(string calldata name, string calldata delim) external view returns (address[] memory);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// Deploy TOSubscription to BSC. Same shape as Deploy.s.sol, minus the importer: run with
/// --slow (the deployer is an EIP-7702 delegated account and BSC refuses gapped nonces from
/// those), and every parameter comes from the environment:
///
///   RECEIVER      where subscription payments land
///   FEE_COLLECTOR who may call renew/renewBatch; address(0) opens them to anyone
///   TERMINATOR    the key that can force-cancel a subscription
///   IMPL          an already-deployed TOSubscription implementation to reuse; omit to deploy one
///   OWNER         the address to own the contract (a TimelockController). Omit to deploy a
///                 fresh timelock from MIN_DELAY / PROPOSERS / EXECUTORS / TIMELOCK_ADMIN.
contract DeployTO {
    VmScriptTO constant vm = VmScriptTO(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function run() external {
        address receiver = vm.envAddress("RECEIVER");
        address feeCollector = vm.envOr("FEE_COLLECTOR", address(0));
        address terminator = vm.envAddress("TERMINATOR");
        address owner_ = vm.envOr("OWNER", address(0));
        uint minDelay = vm.envOr("MIN_DELAY", type(uint256).max);
        bool buildTimelock = minDelay != type(uint256).max;
        require(
            !(owner_ != address(0) && buildTimelock),
            "OWNER and MIN_DELAY are both set. Unset whichever you do not want, or start a new shell."
        );
        require(
            owner_ != address(0) || buildTimelock,
            "Set OWNER to an existing owner, or MIN_DELAY/PROPOSERS/EXECUTORS/TIMELOCK_ADMIN to deploy a timelock."
        );

        vm.startBroadcast();

        if (owner_ == address(0)) {
            owner_ = address(new TimelockController(
                minDelay,
                vm.envAddress("PROPOSERS", ","),
                vm.envAddress("EXECUTORS", ","),
                vm.envAddress("TIMELOCK_ADMIN")
            ));
        }

        address impl = vm.envOr("IMPL", address(0));
        if (impl == address(0)) impl = address(new TOSubscription());

        TOSubscription sub = TOSubscription(address(new ERC1967Proxy(
            impl,
            abi.encodeCall(TOSubscription.initialize, (receiver, feeCollector, terminator, owner_))
        )));

        vm.stopBroadcast();

        emit Deployed(address(sub), impl, owner_);
    }

    event Deployed(address proxy, address implementation, address owner);
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/to_subscription.sol";
import "./mocks.sol";
import "./deployTO.sol";

contract TOSubscriptionV2 is TOSubscription {
    function versionTag() external pure returns (string memory) { return "v2"; }
}

contract TOImpostor {
    function stealEverything() external pure returns (bool) { return true; }
}

/// The proxy keeps state across an upgrade, and only the owner can drive one.
contract TOUpgradeTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0x778121B464151FE5d931587c457E48FcAaA0dc7A;

    TOSubscription sub;
    address timelock;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address alice = address(0xA11CE);
    address mallory = address(0xBAD);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);
        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = deployTOSubscription(receiver, feeCollector, terminator, 0, roles, roles, address(0));
        timelock = sub.getOwner();
        MockERC20(USDT).mint(alice, 1_000_000e18);
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.warp(1_000_000);
    }

    function _assert(bool ok, string memory what) private pure { require(ok, what); }

    function test_ProxyCannotBeInitialisedAgainAndImplementationIsLocked() public {
        _assert(sub.getReceiver() == receiver && sub.getOwner() == timelock, "initialised through the proxy");
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        sub.initialize(receiver, feeCollector, terminator, timelock);
        TOSubscription impl = TOSubscription(sub.getImplementation());
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        impl.initialize(receiver, feeCollector, terminator, timelock);
    }

    function test_InitializeRefusesZeroRoles() public {
        TOSubscription impl = new TOSubscription();
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(impl), toInitCall(address(0), feeCollector, terminator, timelock));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(impl), toInitCall(receiver, feeCollector, address(0), timelock));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(impl), toInitCall(receiver, feeCollector, terminator, address(0)));
        // An open collector is a legitimate deployment.
        TOSubscription open = TOSubscription(address(new ERC1967Proxy(address(impl), toInitCall(receiver, address(0), terminator, timelock))));
        _assert(open.getFeeCollector() == address(0), "deployed with renewals open");
    }

    function test_UpgradeKeepsEveryAccountAndOnlyTheOwnerMayDoIt() public {
        vm.prank(alice);
        sub.subscribe(1, 20e8, 30 days, 0, keccak256("plus"), address(0));
        TOSubscription.SubscriptionInfo memory before = sub.getSubscription(alice);

        TOSubscriptionV2 v2 = new TOSubscriptionV2();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, mallory));
        sub.upgradeTo(address(v2));

        TOImpostor bad = new TOImpostor();
        vm.prank(timelock);
        vm.expectRevert(bytes("ERC1967Upgrade: new implementation is not UUPS"));
        sub.upgradeTo(address(bad));

        vm.prank(timelock);
        sub.upgradeTo(address(v2));
        _assert(sub.getImplementation() == address(v2), "implementation swapped");
        _assert(keccak256(bytes(TOSubscriptionV2(address(sub)).versionTag())) == keccak256("v2"), "new code runs");
        TOSubscription.SubscriptionInfo memory after_ = sub.getSubscription(alice);
        _assert(
            after_.amountUSD == before.amountUSD && after_.period == before.period && after_.planRef == before.planRef
                && after_.nextChargeableAt == before.nextChargeableAt && after_.payToken == before.payToken,
            "account state survived the upgrade"
        );
        _assert(sub.getOwner() == timelock && sub.getReceiver() == receiver, "configuration survived");
    }
}

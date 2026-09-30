// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "../contracts/top_up_collector.sol";
import "./mocks.sol";

/// The constructor guards that keep the timelock meaningful. Each one is here because
/// disabling it hands a single address control of the money, so these are the tests that
/// should fail loudly if anyone relaxes them to make local deployment easier.
contract DeploymentGuardsTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address coldWallet = address(0x1111);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);
        vm.warp(1_000_000);
    }

    function _assert(bool ok, string memory what) private pure { require(ok, what); }
    function _one(address a) private pure returns (address[] memory r) { r = new address[](1); r[0] = a; }
    function _none() private pure returns (address[] memory r) { r = new address[](0); }

    /// A non-zero admin holds TIMELOCK_ADMIN_ROLE, which grants and revokes every other role
    /// with no delay. It could give itself PROPOSER and EXECUTOR, strip everyone who might
    /// cancel, and then push any owner call through — the delay would postpone that, not stop
    /// it. Both contracts must refuse to deploy that way.
    function test_NonZeroAdminIsRejected() public {
        address[] memory roles = _one(coldWallet);

        vm.expectRevert(abi.encodeWithSignature("InvalidTimelockConfig()"));
        new Subscription(receiver, feeCollector, terminator, 0, roles, roles, coldWallet);

        vm.expectRevert(abi.encodeWithSignature("InvalidTimelockConfig()"));
        new TopUp(receiver, 0, roles, roles, coldWallet);
    }

    /// Empty role arrays would leave nobody able to propose or execute, permanently freezing
    /// every owner-gated parameter.
    function test_EmptyProposersOrExecutorsAreRejected() public {
        address[] memory some = _one(coldWallet);

        vm.expectRevert(abi.encodeWithSignature("InvalidTimelockConfig()"));
        new Subscription(receiver, feeCollector, terminator, 0, _none(), some, address(0));

        vm.expectRevert(abi.encodeWithSignature("InvalidTimelockConfig()"));
        new Subscription(receiver, feeCollector, terminator, 0, some, _none(), address(0));

        vm.expectRevert(abi.encodeWithSignature("InvalidTimelockConfig()"));
        new TopUp(receiver, 0, _none(), some, address(0));

        vm.expectRevert(abi.encodeWithSignature("InvalidTimelockConfig()"));
        new TopUp(receiver, 0, some, _none(), address(0));
    }

    /// With admin = 0 the timelock administers itself: it holds TIMELOCK_ADMIN_ROLE and no
    /// outside address does, so roles can only be changed through a delayed proposal.
    function test_TimelockSelfAdministersWhenDeployedCorrectly() public {
        address[] memory roles = _one(coldWallet);
        Subscription sub = new Subscription(receiver, feeCollector, terminator, 2 days, roles, roles, address(0));
        TimelockController tl = TimelockController(payable(sub.getOwner()));

        bytes32 adminRole = tl.TIMELOCK_ADMIN_ROLE();
        _assert(tl.hasRole(adminRole, address(tl)), "the timelock administers itself");
        _assert(!tl.hasRole(adminRole, coldWallet), "the cold wallet is not an admin");
        _assert(!tl.hasRole(adminRole, address(this)), "nor is the deployer");

        // the cold wallet can propose and execute, which is all it should be able to do
        _assert(tl.hasRole(tl.PROPOSER_ROLE(), coldWallet), "cold wallet proposes");
        _assert(tl.hasRole(tl.EXECUTOR_ROLE(), coldWallet), "cold wallet executes");
        _assert(tl.getMinDelay() == 2 days, "delay is what was configured");

        // and it cannot hand itself more power
        bytes32 proposer = tl.PROPOSER_ROLE();
        vm.prank(coldWallet);
        try tl.grantRole(proposer, address(0x9999)) { _assert(false, "cold wallet granted a role directly"); } catch {}
    }

    /// The owner is the timelock, never the deployer — so a compromised deployer key buys
    /// nothing after deployment.
    function test_DeployerRetainsNoPower() public {
        address[] memory roles = _one(coldWallet);
        Subscription sub = new Subscription(receiver, feeCollector, terminator, 1 days, roles, roles, address(0));

        _assert(sub.getOwner() != address(this), "deployer is not the owner");
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", sub.getOwner(), address(this)));
        sub.setReceiver(address(0x9999));
    }
}

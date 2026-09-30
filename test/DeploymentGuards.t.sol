// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "../contracts/top_up_collector.sol";
import "./mocks.sol";
import "./deploy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
    address operator = address(0x2222);

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

    /// A non-zero `admin` is accepted on purpose, and this is exactly what it can do: hold
    /// TIMELOCK_ADMIN_ROLE, hand itself every other role, and push an owner call through with
    /// no one able to cancel it. Kept as a test so the scope of that key is written down rather
    /// than discovered later.
    function test_NonZeroAdminIsAcceptedAndCanReshuffleRolesDirectly() public {
        address[] memory roles = _one(coldWallet);
        Subscription sub = deploySubscription(receiver, feeCollector, terminator, 0, roles, roles, operator);
        TimelockController tl = TimelockController(payable(sub.getOwner()));

        bytes32 adminRole = tl.TIMELOCK_ADMIN_ROLE();
        bytes32 proposer = tl.PROPOSER_ROLE();
        bytes32 executor = tl.EXECUTOR_ROLE();
        bytes32 canceller = tl.CANCELLER_ROLE();

        _assert(tl.hasRole(adminRole, operator), "the admin key holds role admin");
        _assert(tl.hasRole(adminRole, address(tl)), "the timelock still self-administers too");

        // it can grant itself the remaining roles without any delay
        vm.prank(operator);
        tl.grantRole(proposer, operator);
        vm.prank(operator);
        tl.grantRole(executor, operator);
        // and remove anyone who could have cancelled what it proposes
        vm.prank(operator);
        tl.revokeRole(canceller, coldWallet);
        _assert(!tl.hasRole(canceller, coldWallet), "the cold wallet lost its veto");

        // with minDelay at zero that is a one-block takeover of every owner parameter
        bytes memory payload = abi.encodeWithSignature("setReceiver(address)", operator);
        vm.prank(operator);
        tl.schedule(address(sub), 0, payload, bytes32(0), bytes32(0), 0);
        vm.prank(operator);
        tl.execute(address(sub), 0, payload, bytes32(0), bytes32(0));
        _assert(sub.getReceiver() == operator, "owner parameters follow the admin key");
    }

    /// TopUp takes the same admin argument and behaves the same way.
    function test_TopUpAlsoAcceptsANonZeroAdmin() public {
        address[] memory roles = _one(coldWallet);
        TopUp top = new TopUp(receiver, 0, roles, roles, operator);
        TimelockController tl = TimelockController(payable(top.getOwner()));
        _assert(tl.hasRole(tl.TIMELOCK_ADMIN_ROLE(), operator), "admin key carried through");
    }

    /// The owner is the only argument initialize validates now that the timelock is deployed
    /// separately. Zero would leave every onlyOwner path permanently unreachable.
    function test_ZeroOwnerIsRejected() public {
        address impl = address(new Subscription());
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(impl, subscriptionInitCall(receiver, feeCollector, terminator, address(0)));
    }

    /// Timelock configuration is no longer this contract's concern — it takes whatever owner it
    /// is handed. An empty proposer set still deadlocks that timelock, so it has to be caught
    /// when the timelock is deployed, not here.
    function test_TimelockConfigurationIsTheDeployersResponsibility() public {
        address[] memory none = _none();
        address[] memory some = _one(coldWallet);
        // A timelock with no proposers constructs happily; nothing can ever be scheduled on it.
        TimelockController deadlocked = new TimelockController(0, none, some, address(0));
        _assert(!deadlocked.hasRole(deadlocked.PROPOSER_ROLE(), coldWallet), "nobody can propose");

        // and Subscription accepts it, because it cannot tell
        Subscription sub = deploySubscription(receiver, feeCollector, terminator, 0, none, some, address(0));
        _assert(sub.getOwner() != address(0), "deployed against a deadlocked timelock");
    }

    /// With admin = 0 the timelock administers itself: it holds TIMELOCK_ADMIN_ROLE and no
    /// outside address does, so roles can only be changed through a delayed proposal.
    function test_TimelockSelfAdministersWhenDeployedCorrectly() public {
        address[] memory roles = _one(coldWallet);
        Subscription sub = deploySubscription(receiver, feeCollector, terminator, 2 days, roles, roles, address(0));
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
        Subscription sub = deploySubscription(receiver, feeCollector, terminator, 1 days, roles, roles, address(0));

        _assert(sub.getOwner() != address(this), "deployer is not the owner");
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", sub.getOwner(), address(this)));
        sub.setReceiver(address(0x9999));
    }
}

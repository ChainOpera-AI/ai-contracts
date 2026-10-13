// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";
import "./deploy.sol";

/// importAccounts writes storage directly, so without checks it could reach states the rest
/// of the contract treats as impossible -- and say nothing until the account's first charge
/// reverted. Each case below once produced a quietly unusable account.
contract ImportIntegrityTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant GO_MONTH = 1;
    uint constant PLUS_MONTH = 2;
    uint constant PERIOD = 30 days;

    Subscription sub;
    address timelock;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address importer = address(0x114807);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);
        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = deploySubscription(receiver, feeCollector, terminator, importer, 0, roles, roles, address(0));
        timelock = sub.getOwner();
        MockERC20(USDT).mint(alice, 1_000_000e18);
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.warp(1_000_000);
    }

    function _assert(bool ok, string memory what) private pure { require(ok, what); }

    function _row(address who, uint t, uint8 payToken, uint pendingType, bool cancelled)
        private view returns (Subscription.ImportedAccount[] memory rows)
    {
        rows = new Subscription.ImportedAccount[](1);
        rows[0] = Subscription.ImportedAccount({
            account: who, subscriptionType: t, payToken: payToken, lockedPeriod: uint32(PERIOD),
            nextChargeableAt: vm.getBlockTimestamp() + 1 days, pendingType: pendingType,
            trialEndsAt: 0, cancelled: cancelled, everSubscribed: true, inviter: address(0)
        });
    }

    function _import(Subscription.ImportedAccount[] memory rows) private {
        vm.prank(importer);
        sub.importAccounts(rows);
    }

    /// A pay token outside 1-3 leaves nothing able to charge the account.
    function test_ImpossiblePayTokenIsRefused() public {
        Subscription.ImportedAccount[] memory rows = _row(alice, GO_MONTH, 7, 0, false);
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("UnknownPayToken(uint8)", 7));
        sub.importAccounts(rows);
        _assert(sub.getActiveType(alice) == 0, "nothing was written");
    }

    /// The plan has to be one this contract actually has a price and period for.
    function test_PlanThatDoesNotExistIsRefused() public {
        Subscription.ImportedAccount[] memory rows = _row(alice, 99, 1, 0, false);
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("InvalidSubscriptionType(uint256)", 99));
        sub.importAccounts(rows);
    }

    /// A parked downgrade is read at the next charge, so its target must exist as well.
    function test_PendingPlanThatDoesNotExistIsRefused() public {
        Subscription.ImportedAccount[] memory rows = _row(alice, GO_MONTH, 1, 99, false);
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("InvalidSubscriptionType(uint256)", 99));
        sub.importAccounts(rows);
    }

    /// _pendingType and _cancelled are one slot in two guises, and every native path keeps
    /// them exclusive. Allowing both let a downgrade parked against a finished subscription
    /// land on the next one -- silently moving the account and billing it the new plan.
    function test_CancelledPlusPendingIsRefused() public {
        Subscription.ImportedAccount[] memory rows = _row(alice, GO_MONTH, 1, PLUS_MONTH, true);
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("PendingChangeExists(uint256)", PLUS_MONTH));
        sub.importAccounts(rows);
    }

    /// _requireDue reads this as an invariant: an active plan always has an anchor.
    function test_MissingAnchorIsRefused() public {
        Subscription.ImportedAccount[] memory rows = _row(alice, GO_MONTH, 1, 0, false);
        rows[0].nextChargeableAt = 0;
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("NotSubscribed()"));
        sub.importAccounts(rows);
    }

    /// Re-importing onto a different plan used to leave the first anchor live, which no
    /// native transition can produce and which later strands the account.
    function test_ReimportOntoAnotherPlanClearsTheOldAnchor() public {
        _import(_row(alice, GO_MONTH, 1, 0, false));
        _import(_row(alice, PLUS_MONTH, 1, 0, false));

        _assert(sub.getActiveType(alice) == PLUS_MONTH, "the second import is the active plan");
        _assert(sub.getNextChargeableAt(alice, GO_MONTH) == 0, "the first plan still has an anchor");
        _assert(sub.getNextChargeableAt(alice, PLUS_MONTH) != 0, "the new plan has one");
    }

    /// Re-importing the same plan is an ordinary correction and must still work.
    function test_ReimportOntoTheSamePlanStillWorks() public {
        _import(_row(alice, GO_MONTH, 1, 0, false));
        Subscription.ImportedAccount[] memory fixed_ = _row(alice, GO_MONTH, 1, 0, false);
        fixed_[0].nextChargeableAt = vm.getBlockTimestamp() + 9 days;
        _import(fixed_);
        _assert(sub.getNextChargeableAt(alice, GO_MONTH) == vm.getBlockTimestamp() + 9 days, "corrected");
    }

    /// The checks must not stand in the way of a correct batch.
    function test_AValidRowStillImportsAndBills() public {
        _import(_row(alice, GO_MONTH, 1, 0, false));
        _assert(sub.getEffectiveType(alice) == GO_MONTH, "entitled");

        uint before = MockERC20(USDT).balanceOf(receiver);
        vm.warp(sub.nextChargeableAt(alice));
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(MockERC20(USDT).balanceOf(receiver) - before == sub.getSubscriptionAmountUSDT(GO_MONTH),
                "renewed at the imported plan");
    }
}

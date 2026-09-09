// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";

contract SubscriptionTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant GO_MONTH = 1;
    uint constant PLUS_MONTH = 2;
    uint constant PREMIUM_MONTH = 3;
    uint constant PERIOD = 30 days;
    uint constant TRIAL = 3 days;
    uint constant PLUS_PRICE = 1999000000 * 1e18 / 1e8; // $19.99 in 18-dec USDT
    uint constant GO_PRICE = 500000000 * 1e18 / 1e8;    // $5

    Subscription sub;
    address timelock;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);

        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = new Subscription(receiver, feeCollector, terminator, 0, roles, roles, address(0));
        timelock = sub.getOwner();

        MockERC20(USDT).mint(alice, 1_000_000e18);
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.warp(1_000_000); // move off timestamp 0
    }

    function _bal(address a) private view returns (uint) { return MockERC20(USDT).balanceOf(a); }
    function _sub(address who, uint t) private { vm.prank(who); sub.subscriptionUSDT(t, address(0)); }
    function _assert(bool ok, string memory what) private pure { require(ok, what); }
    function _fund(address who) private {
        MockERC20(USDT).mint(who, 1_000_000e18);
        vm.prank(who);
        MockERC20(USDT).approve(address(sub), type(uint).max);
    }

    // --- the requested behaviour -------------------------------------------

    function test_TrialTakesNoMoneyUpfront() public {
        uint before = _bal(alice);
        _sub(alice, PLUS_MONTH);
        _assert(_bal(alice) == before, "trial must not charge");
        _assert(_bal(receiver) == 0, "receiver must get nothing");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + TRIAL, "anchor = now + 3d");
        _assert(sub.getEffectiveType(alice) == PLUS_MONTH, "entitled during trial");
    }

    function test_FirstChargeLandsWhenTrialEnds() public {
        _sub(alice, PLUS_MONTH);
        uint trialEnd = sub.nextChargeableAt(alice);

        vm.warp(trialEnd - 1);
        vm.prank(feeCollector);
        vm.expectRevert(abi.encodeWithSignature("NotDueYet(uint256)", trialEnd));
        sub.renew(alice);
        _assert(_bal(receiver) == 0, "nothing charged before trial ends");

        vm.warp(trialEnd);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(_bal(receiver) == PLUS_PRICE, "one full month at trial end");
        _assert(sub.nextChargeableAt(alice) == trialEnd + PERIOD, "next = trialEnd + 30d");
    }

    function test_CancelInsideTrialAvoidsTheCharge() public {
        _sub(alice, PLUS_MONTH);
        uint trialEnd = sub.nextChargeableAt(alice);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        sub.cancelSubscription();
        _assert(_bal(receiver) == 0, "cancel inside trial charges nothing");
        _assert(sub.getEffectiveType(alice) == PLUS_MONTH, "still served until trial end");

        vm.warp(trialEnd);
        vm.prank(feeCollector);
        vm.expectRevert(abi.encodeWithSignature("AlreadyCancelled()"));
        sub.renew(alice);
        _assert(_bal(receiver) == 0, "never charged");
        _assert(sub.getEffectiveType(alice) == 0, "entitlement over");
    }

    function test_OtherPlansStillChargeOnSubscribe() public {
        uint before = _bal(alice);
        _sub(alice, GO_MONTH);
        _assert(before - _bal(alice) == GO_PRICE, "GO charges upfront");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + PERIOD, "anchor = now + 30d");
    }

    /// Any plan can be given or denied a trial; a zero trial period simply means "no trial".
    function test_OwnerCanGiveAnyPlanATrial() public {
        _assert(sub.getTrialPeriod(PREMIUM_MONTH) == 0, "no trial by default");
        _assert(!sub.startsTrial(alice, PREMIUM_MONTH), "so none is offered");

        vm.prank(timelock);
        sub.setTrialPeriod(PREMIUM_MONTH, 7 days);
        _assert(sub.startsTrial(alice, PREMIUM_MONTH), "trial now offered");
        uint before = _bal(alice);
        _sub(alice, PREMIUM_MONTH);
        _assert(_bal(alice) == before, "premium trial charges nothing");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + 7 days, "7d trial honoured");

        vm.prank(timelock);
        sub.setTrialPeriod(PLUS_MONTH, 0);
        _assert(!sub.startsTrial(address(0xB0B), PLUS_MONTH), "plus trial withdrawn");
    }

    // --- abuse guards -------------------------------------------------------

    function test_TrialCannotBeFarmedByCancelling() public {
        _sub(alice, PLUS_MONTH);
        uint trialEnd = sub.nextChargeableAt(alice);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(trialEnd + 1);

        _assert(!sub.startsTrial(alice, PLUS_MONTH), "trial already consumed");
        uint before = _bal(alice);
        _sub(alice, PLUS_MONTH);
        _assert(before - _bal(alice) == PLUS_PRICE, "second time must be paid");
    }

    function test_ExistingPayerGetsNoTrialWhenOneIsAddedLater() public {
        vm.prank(timelock);
        sub.setTrialPeriod(PLUS_MONTH, 0); // withdraw it, so alice subscribes as a payer
        _sub(alice, PLUS_MONTH);
        vm.prank(timelock);
        sub.setTrialPeriod(PLUS_MONTH, uint32(TRIAL)); // offered again afterwards

        vm.warp(block.timestamp + PERIOD); // period up, alice resubscribes herself
        _assert(!sub.startsTrial(alice, PLUS_MONTH), "renewal is not a fresh start");
        uint before = _bal(alice);
        _sub(alice, PLUS_MONTH);
        _assert(before - _bal(alice) == PLUS_PRICE * 2, "settles due period + pays one more");
    }

    // --- cancel / restore / plan change ------------------------------------

    function test_RestoreInsideTrialKeepsTheSchedule() public {
        _sub(alice, PLUS_MONTH);
        uint trialEnd = sub.nextChargeableAt(alice);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(block.timestamp + 1 days);
        _assert(sub.canRestore(alice), "restorable inside trial");
        vm.prank(alice);
        sub.restoreSubscription();

        vm.warp(trialEnd);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(_bal(receiver) == PLUS_PRICE, "charge resumes after restore");
    }

    function test_RestoreAfterPeriodElapsedReverts() public {
        _sub(alice, GO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(next);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SubscriptionExpired(uint256)", next));
        sub.restoreSubscription();
    }

    function test_PlanChangeRequiresCancelThenWait() public {
        _sub(alice, GO_MONTH);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("MustCancelFirst(uint256)", GO_MONTH));
        sub.subscriptionUSDT(PREMIUM_MONTH, address(0));

        vm.prank(alice);
        sub.cancelSubscription();
        uint next = sub.nextChargeableAt(alice);

        vm.prank(alice); // still inside the paid period
        vm.expectRevert(abi.encodeWithSignature("NotDueYet(uint256)", next));
        sub.subscriptionUSDT(PREMIUM_MONTH, address(0));

        vm.warp(next);
        _sub(alice, PREMIUM_MONTH);
        _assert(sub.getEffectiveType(alice) == PREMIUM_MONTH, "switched after the period");
    }

    function test_GapAfterCancelIsNeverBilled() public {
        _sub(alice, GO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        vm.prank(alice);
        sub.cancelSubscription();

        vm.warp(next + 100 days); // long gap away
        uint before = _bal(alice);
        _sub(alice, GO_MONTH);
        _assert(before - _bal(alice) == GO_PRICE, "only one period, gap not billed");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + PERIOD, "anchor restarts at now");
    }

    // --- setSubscriptionPeriod only ever affects new subscriptions ----------

    function test_PeriodChangeLeavesExistingSubscribersOnTheirOwnCadence() public {
        _sub(alice, GO_MONTH);
        uint t0 = block.timestamp;
        _assert(sub.getLockedPeriod(alice) == PERIOD, "locked at 30d");

        vm.prank(timelock);
        sub.setSubscriptionPeriod(GO_MONTH, 7 days);
        _assert(sub.getSubscriptionPeriod(GO_MONTH) == 7 days, "plan is now weekly");
        _assert(sub.getLockedPeriod(alice) == PERIOD, "alice keeps 30d");

        // her renewals keep stepping by 30d, not 7d
        vm.warp(t0 + PERIOD);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(sub.nextChargeableAt(alice) == t0 + 2 * PERIOD, "still stepping by 30d");
    }

    function test_PeriodChangeAppliesToNewSubscribers() public {
        _sub(alice, GO_MONTH);
        vm.prank(timelock);
        sub.setSubscriptionPeriod(GO_MONTH, 7 days);

        address bob = address(0xB0B);
        _fund(bob);
        _sub(bob, GO_MONTH);
        _assert(sub.getLockedPeriod(bob) == 7 days, "bob locked at the new 7d");
        _assert(sub.nextChargeableAt(bob) == block.timestamp + 7 days, "bob renews in 7d");
        _assert(sub.getLockedPeriod(alice) == PERIOD, "alice untouched");
    }

    /// The regression this whole mechanism exists for: shortening a plan must not re-slice
    /// arrears that accrued while the old period was in force.
    function test_ShorteningPeriodCannotInflateExistingArrears() public {
        _sub(alice, GO_MONTH);
        uint t0 = block.timestamp;
        uint paid = _bal(receiver);

        // fee collector is 60 days late, and the owner shortens the plan before the catch-up
        vm.warp(t0 + PERIOD + 60 days);
        vm.prank(timelock);
        sub.setSubscriptionPeriod(GO_MONTH, 10 days);

        vm.prank(feeCollector);
        sub.renew(alice);
        // 60 days of arrears at her locked 30d period => 3 periods.
        // Sliced at the new 10d period it would have been 7.
        _assert((_bal(receiver) - paid) / GO_PRICE == 3, "arrears billed at the locked period");
    }

    function test_ResubscribeAfterCancelAdoptsTheNewPeriod() public {
        _sub(alice, GO_MONTH);
        vm.prank(timelock);
        sub.setSubscriptionPeriod(GO_MONTH, 7 days);

        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(sub.nextChargeableAt(alice)); // let the paid-up period run out
        _sub(alice, GO_MONTH);

        _assert(sub.getLockedPeriod(alice) == 7 days, "fresh start picks up the new period");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + 7 days, "and anchors on it");
    }
}

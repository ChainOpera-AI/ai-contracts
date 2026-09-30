// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";
import "./deploy.sol";

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
    uint constant GO_PRICE = 499000000 * 1e18 / 1e8;    // $4.99

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
        sub = deploySubscription(receiver, feeCollector, terminator, address(0), 0, roles, roles, address(0));
        timelock = sub.getOwner();

        MockERC20(USDT).mint(alice, 1_000_000e18);
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        MockERC20(USDC).mint(alice, 1_000_000e18);
        vm.prank(alice);
        MockERC20(USDC).approve(address(sub), type(uint).max);
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
        _assert(sub.nextChargeableAt(alice) == vm.getBlockTimestamp() + TRIAL, "anchor = now + 3d");
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

        vm.warp(vm.getBlockTimestamp() + 2 days);
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
        _assert(sub.nextChargeableAt(alice) == vm.getBlockTimestamp() + PERIOD, "anchor = now + 30d");
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
        _assert(sub.nextChargeableAt(alice) == vm.getBlockTimestamp() + 7 days, "7d trial honoured");

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

        vm.warp(vm.getBlockTimestamp() + PERIOD); // period up, alice resubscribes herself
        _assert(!sub.startsTrial(alice, PLUS_MONTH), "renewal is not a fresh start");
        uint before = _bal(alice);
        _sub(alice, PLUS_MONTH);
        _assert(before - _bal(alice) == PLUS_PRICE, "one period owed, one period charged");
    }

    // --- cancel / restore / plan change ------------------------------------

    function test_RestoreInsideTrialKeepsTheSchedule() public {
        _sub(alice, PLUS_MONTH);
        uint trialEnd = sub.nextChargeableAt(alice);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(vm.getBlockTimestamp() + 1 days);
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
        _assert(sub.nextChargeableAt(alice) == vm.getBlockTimestamp() + PERIOD, "anchor restarts at now");
    }

    // --- setSubscriptionPeriod only ever affects new subscriptions ----------

    function test_PeriodChangeLeavesExistingSubscribersOnTheirOwnCadence() public {
        _sub(alice, GO_MONTH);
        uint t0 = vm.getBlockTimestamp();
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
        _assert(sub.nextChargeableAt(bob) == vm.getBlockTimestamp() + 7 days, "bob renews in 7d");
        _assert(sub.getLockedPeriod(alice) == PERIOD, "alice untouched");
    }

    /// The regression this whole mechanism exists for: shortening a plan must not re-slice
    /// arrears that accrued while the old period was in force.
    function test_ShorteningPeriodCannotInflateExistingArrears() public {
        _sub(alice, GO_MONTH);
        uint t0 = vm.getBlockTimestamp();
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
        _assert(sub.nextChargeableAt(alice) == vm.getBlockTimestamp() + 7 days, "and anchors on it");
    }

    // --- the price list itself ----------------------------------------------

    /// Locks the deployed price table down, and the rule that a year costs ten months.
    function test_DefaultPriceTable() public view {
        uint[8] memory expected = [
            uint(499000000),    // 1 GO_MONTH        $4.99
            1999000000,         // 2 PLUS_MONTH      $19.99
            9999000000,         // 3 PREMIUM_MONTH   $99.99
            19999000000,        // 4 PRO_MONTH       $199.99
            4990000000,         // 5 GO_YEAR         $49.90
            19990000000,        // 6 PLUS_YEAR       $199.90
            99990000000,        // 7 PREMIUM_YEAR    $999.90
            199990000000        // 8 PRO_YEAR        $1999.90
        ];
        for (uint i = 0; i < 8; i++) {
            _assert(sub.getSubscriptionPrice(i + 1) == expected[i], "price table drifted");
        }
        // every yearly plan is exactly ten times its monthly counterpart
        for (uint m = 1; m <= 4; m++) {
            _assert(
                sub.getSubscriptionPrice(m + 4) == sub.getSubscriptionPrice(m) * 10,
                "a yearly plan is not ten months"
            );
        }
    }

    // --- renewing while in arrears -----------------------------------------

    /// Resubscribing while a period is owed charges exactly that period, not that period
    /// plus another one. This is the whole point of the arrears branch in _activate.
    function test_ResubscribingInArrearsChargesOnlyWhatIsOwed() public {
        _sub(alice, GO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next + 3 days);              // one period owed, three days late

        uint before = _bal(alice);
        _sub(alice, GO_MONTH);
        _assert(before - _bal(alice) == GO_PRICE, "exactly one period");
        _assert(sub.nextChargeableAt(alice) == next + PERIOD, "anchor advanced by exactly one");
        _assert(sub.nextChargeableAt(alice) > vm.getBlockTimestamp(), "and is no longer in arrears");
    }

    /// Several periods owed: every one of them is charged, and not one more.
    function test_ResubscribingClearsEveryOwedPeriodAndNoMore() public {
        _sub(alice, GO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next + 2 * PERIOD + 1 days); // three periods owed

        uint before = _bal(alice);
        _sub(alice, GO_MONTH);
        _assert(before - _bal(alice) == GO_PRICE * 3, "three owed, three charged");
        _assert(sub.nextChargeableAt(alice) == next + 3 * PERIOD, "anchor advanced by three");
    }

    /// The case seen on chain: a trial lapses, the fee collector misses it, and the user
    /// renews by hand. One period was owed, so one period is charged.
    function test_RenewingAfterALapsedTrialChargesOnePeriod() public {
        _sub(alice, PLUS_MONTH);                 // opens the 3-day trial, charges nothing
        uint trialEnd = sub.nextChargeableAt(alice);
        _assert(_bal(receiver) == 0, "trial is free");

        vm.warp(trialEnd + 3 days);              // trial over, nobody called renew
        uint before = _bal(alice);
        _sub(alice, PLUS_MONTH);

        _assert(before - _bal(alice) == PLUS_PRICE, "one period, not two");
        _assert(sub.nextChargeableAt(alice) == trialEnd + PERIOD, "anchor is one period past the trial");
    }

    /// Arrears are settled in the token the account owed them in; the token it renews with
    /// takes over from there.
    function test_RenewingInArrearsCanSwitchPayToken() public {
        _sub(alice, GO_MONTH);                   // subscribed in USDT
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next);

        uint usdtBefore = _bal(alice);
        uint usdcBefore = MockERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        sub.subscriptionUSDC(GO_MONTH, address(0));

        _assert(usdtBefore - _bal(alice) == GO_PRICE, "the debt was paid in USDT");
        _assert(MockERC20(USDC).balanceOf(alice) == usdcBefore, "USDC was not touched");
        _assert(sub.getActivePayToken(alice) == 3, "but future charges are USDC");

        // and the next renewal does come out of USDC
        vm.warp(sub.nextChargeableAt(alice));
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(usdcBefore - MockERC20(USDC).balanceOf(alice) == GO_PRICE, "renewed in USDC");
    }
}

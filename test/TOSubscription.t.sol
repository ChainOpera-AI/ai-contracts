// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/to_subscription.sol";
import "./mocks.sol";
import "./deployTO.sol";

/// The subscriber brings the terms; the contract freezes them and bills by them. These tests
/// pin down what "by them" means on every path, and that nothing the owner holds can change
/// what an existing subscriber pays.
contract TOSubscriptionTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0x778121B464151FE5d931587c457E48FcAaA0dc7A;

    uint8 constant PT_USDT = 1;
    uint8 constant PT_COAI = 2;
    uint8 constant PT_USDC = 3;

    uint constant AMOUNT = 20e8;            // $20.00 per period
    uint32 constant PERIOD = 30 days;
    uint32 constant TRIAL = 3 days;
    bytes32 constant REF = keccak256("plus-month");
    bytes32 constant REF2 = keccak256("pro-month");
    uint constant PRICE = 20e18;            // $20 in an 18-decimal stablecoin

    TOSubscription sub;
    address timelock;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address stranger = address(0x5712A);

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

        _fund(alice);
        _fund(bob);
        vm.warp(1_000_000);
    }

    function _fund(address who) private {
        MockERC20(USDT).mint(who, 1_000_000e18);
        MockERC20(USDC).mint(who, 1_000_000e18);
        MockERC20(COAI).mint(who, 1_000_000e18);
        vm.prank(who); MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.prank(who); MockERC20(USDC).approve(address(sub), type(uint).max);
        vm.prank(who); MockERC20(COAI).approve(address(sub), type(uint).max);
    }
    function _bal(address a) private view returns (uint) { return MockERC20(USDT).balanceOf(a); }
    function _assert(bool ok, string memory what) private pure { require(ok, what); }
    function _now() private view returns (uint) { return vm.getBlockTimestamp(); }
    function _sub(address who, uint amount, uint32 period, uint32 trial, bytes32 ref) private {
        vm.prank(who);
        sub.subscribe(PT_USDT, amount, period, trial, ref, address(0));
    }
    function _subPlus(address who) private { _sub(who, AMOUNT, PERIOD, 0, REF); }
    function _renew(address who) private { vm.prank(feeCollector); sub.renew(who); }
    function _expect(string memory sig) private { vm.expectRevert(abi.encodeWithSignature(sig)); }
    function _count(Vm.Log[] memory logs, bytes32 sig) private pure returns (uint n) {
        for (uint i = 0; i < logs.length; i++) if (logs[i].topics[0] == sig) n++;
    }

    // --- subscribing on one's own terms ---------------------------------------

    function test_SubscribeChargesTheCommittedAmountAndFreezesTheTerms() public {
        uint before = _bal(alice);
        _subPlus(alice);
        _assert(before - _bal(alice) == PRICE, "charged exactly the committed amount");
        _assert(_bal(receiver) == PRICE, "and it went to the receiver");
        TOSubscription.SubscriptionInfo memory s = sub.getSubscription(alice);
        _assert(s.amountUSD == AMOUNT && s.period == PERIOD && s.planRef == REF, "terms stored as given");
        _assert(s.payToken == PT_USDT, "pay token recorded");
        _assert(s.nextChargeableAt == _now() + PERIOD, "anchor = now + period");
        _assert(s.active && !s.cancelled && s.trialEndsAt == 0 && s.pendingAmountUSD == 0, "fresh and active");
        _assert(sub.isSubscribed(alice) && sub.isActive(alice), "subscribed and active");
        _assert(sub.hasEverSubscribed(alice) && !sub.startsTrial(alice), "trial eligibility burnt");
    }

    function test_SubscribedEventCarriesEverythingTheBackendChecks() public {
        vm.recordLogs();
        vm.prank(alice);
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF, bob);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Subscribed(address,uint8,bytes32,uint256,uint32,address,uint256,uint256,uint256)");
        bool found;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            _assert(address(uint160(uint(logs[i].topics[1]))) == alice, "account indexed");
            _assert(uint(logs[i].topics[2]) == PT_USDT, "pay token indexed");
            _assert(logs[i].topics[3] == REF, "planRef indexed");
            (uint amount, uint32 period, address inviter, uint chargedUSD, uint tokenAmount, uint next) =
                abi.decode(logs[i].data, (uint, uint32, address, uint, uint, uint));
            _assert(amount == AMOUNT && period == PERIOD, "terms in the event");
            _assert(inviter == bob, "inviter in the event");
            _assert(chargedUSD == AMOUNT && tokenAmount == PRICE, "no discount on USDT");
            _assert(next == _now() + PERIOD, "anchor in the event");
        }
        _assert(found, "Subscribed emitted");
        _assert(sub.getInviter(alice) == bob, "inviter stored");
    }

    function test_CoaiPaysTheDiscountedAmountAtTheTwap() public {
        // MockPool quotes 1 COAI = 1 USDT; COAI carries the default 10% discount.
        vm.prank(alice);
        sub.subscribe(PT_COAI, AMOUNT, PERIOD, 0, REF, address(0));
        _assert(MockERC20(COAI).balanceOf(receiver) == 18e18, "$20 at 900/1000 = 18 COAI");
        _assert(sub.quoteTokenAmount(PT_COAI, AMOUNT) == 18e18, "quote agrees");
        _assert(sub.getSubscriptionAmount(alice) == 18e18, "per-period amount agrees");
        _assert(sub.getActivePayToken(alice) == PT_COAI, "pay token recorded");
    }

    function test_TheOwnerCannotChangeWhatASubscriberPays() public {
        _subPlus(alice);
        // The only owner knobs that touch money are the discounts, and they apply to the
        // transfer, not the commitment. Nothing can raise what alice committed to.
        vm.prank(timelock);
        sub.setDiscount(PT_USDT, 500);
        vm.warp(_now() + PERIOD);
        uint before = _bal(alice);
        _renew(alice);
        _assert(before - _bal(alice) == PRICE / 2, "a discount can only lower the transfer");
        _assert(sub.getSubscription(alice).amountUSD == AMOUNT, "the commitment itself never moves");
    }

    // --- trials -----------------------------------------------------------------

    function test_TrialTakesNoMoneyAndAnchorsAtItsEnd() public {
        uint before = _bal(alice);
        vm.recordLogs();
        _sub(alice, AMOUNT, PERIOD, TRIAL, REF);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assert(_bal(alice) == before && _bal(receiver) == 0, "trial must not charge");
        _assert(sub.nextChargeableAt(alice) == _now() + TRIAL, "anchor = now + trial");
        _assert(sub.isInTrial(alice) && sub.isActive(alice), "entitled during the trial");
        bytes32 sig = keccak256("TrialStarted(address,uint8,bytes32,uint256,uint32,uint32,address,uint256)");
        _assert(_count(logs, sig) == 1, "TrialStarted emitted");
        _assert(_count(logs, keccak256("Subscribed(address,uint8,bytes32,uint256,uint32,address,uint256,uint256,uint256)")) == 0, "no Subscribed");
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            (uint amount, uint32 period, uint32 trial,, uint endsAt) = abi.decode(logs[i].data, (uint, uint32, uint32, address, uint));
            _assert(amount == AMOUNT && period == PERIOD && trial == TRIAL, "the backend sees the trial it has to judge");
            _assert(endsAt == _now() + TRIAL, "trial end in the event");
        }
    }

    function test_FirstChargeLandsWhenTheTrialEnds() public {
        _sub(alice, AMOUNT, PERIOD, TRIAL, REF);
        uint trialEnd = sub.nextChargeableAt(alice);
        vm.warp(trialEnd - 1);
        vm.prank(feeCollector);
        vm.expectRevert(abi.encodeWithSignature("NotDueYet(uint256)", trialEnd));
        sub.renew(alice);
        vm.warp(trialEnd);
        _renew(alice);
        _assert(_bal(receiver) == PRICE, "one full period at the trial's end");
        _assert(sub.nextChargeableAt(alice) == trialEnd + PERIOD, "schedule runs off the trial end");
        _assert(!sub.isInTrial(alice), "trial over");
    }

    function test_CancelInsideTheTrialAvoidsTheCharge() public {
        _sub(alice, AMOUNT, PERIOD, TRIAL, REF);
        uint trialEnd = sub.nextChargeableAt(alice);
        vm.warp(_now() + 2 days);
        vm.prank(alice);
        sub.cancelSubscription();
        _assert(_bal(receiver) == 0 && sub.isActive(alice), "nothing charged, still served");
        vm.warp(trialEnd);
        vm.prank(feeCollector);
        _expect("AlreadyCancelled()");
        sub.renew(alice);
        _assert(!sub.isActive(alice), "entitlement ends with the trial");
    }

    function test_TrialIsRefusedOnceAnAccountHasSubscribed() public {
        _subPlus(alice);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(_now() + PERIOD);
        _assert(!sub.startsTrial(alice), "front end can see it");
        vm.prank(alice);
        _expect("TrialNotAvailable()");
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, TRIAL, REF, address(0));
        // A second address is a second chance -- that is the model, and the backend knows.
        _sub(bob, AMOUNT, PERIOD, TRIAL, REF);
        _assert(sub.isInTrial(bob), "a fresh account may trial");
    }

    function test_TrialLongerThanTheCapIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("TrialTooLong(uint32,uint32)", uint32(31 days), uint32(30 days)));
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 31 days, REF, address(0));
        vm.prank(timelock);
        sub.setMaxTrialPeriod(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("TrialTooLong(uint32,uint32)", uint32(1), uint32(0)));
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 1, REF, address(0));
        _subPlus(alice); // trial-less subscribe is unaffected
        _assert(sub.isSubscribed(alice), "paid subscribe still works");
    }

    // --- sanity bounds on the terms ---------------------------------------------

    function test_TermsOutsideTheBoundsAreRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PeriodOutOfRange(uint32,uint32,uint32)", uint32(1 hours), uint32(1 days), uint32(366 days)));
        sub.subscribe(PT_USDT, AMOUNT, 1 hours, 0, REF, address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PeriodOutOfRange(uint32,uint32,uint32)", uint32(400 days), uint32(1 days), uint32(366 days)));
        sub.subscribe(PT_USDT, AMOUNT, 400 days, 0, REF, address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AmountOutOfRange(uint256)", uint(0)));
        sub.subscribe(PT_USDT, 0, PERIOD, 0, REF, address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AmountOutOfRange(uint256)", uint(1_000_000_001e8)));
        sub.subscribe(PT_USDT, 1_000_000_001e8, PERIOD, 0, REF, address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("UnknownPayToken(uint8)", uint8(4)));
        sub.subscribe(4, AMOUNT, PERIOD, 0, REF, address(0));
    }

    function test_OwnerCanWidenTheBoundsForATestDeployment() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, alice));
        sub.setPeriodBounds(60, 366 days);
        vm.prank(timelock);
        _expect("InvalidPeriodBounds()");
        sub.setPeriodBounds(0, 1 days);
        vm.prank(timelock);
        _expect("InvalidPeriodBounds()");
        sub.setPeriodBounds(2 days, 1 days);
        vm.prank(timelock);
        sub.setPeriodBounds(60, 366 days);
        (uint32 lo, uint32 hi) = sub.getPeriodBounds();
        _assert(lo == 60 && hi == 366 days, "bounds stored");
        _sub(alice, 499, 60, 0, REF); // the debug shape the CO test contract uses
        _assert(sub.getSubscription(alice).period == 60, "a 60-second period is now accepted");
    }

    // --- renewing ---------------------------------------------------------------

    function test_RenewChargesEveryPeriodOwedAndAdvancesTheAnchor() public {
        _subPlus(alice);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next + 2 * PERIOD + 1 days); // three periods have come due
        uint before = _bal(alice);
        _renew(alice);
        _assert(before - _bal(alice) == 3 * PRICE, "three periods charged");
        _assert(sub.nextChargeableAt(alice) == next + 3 * PERIOD, "anchor advanced by three periods");
    }

    function test_RenewIsGatedByTheCollectorUntilItIsOpened() public {
        _subPlus(alice);
        vm.warp(_now() + PERIOD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotFeeCollector(address,address)", feeCollector, stranger));
        sub.renew(alice);
        vm.prank(timelock);
        sub.setFeeCollector(address(0));
        vm.prank(stranger);
        sub.renew(alice);
        _assert(_bal(receiver) == 2 * PRICE, "a stranger collected the period owed, nothing more");
    }

    function test_RenewBatchIsolatesFailures() public {
        _subPlus(alice);
        _subPlus(bob);
        vm.prank(bob);
        MockERC20(USDT).approve(address(sub), 0); // bob can no longer pay
        vm.warp(_now() + PERIOD);
        address[] memory batch = new address[](2);
        batch[0] = alice; batch[1] = bob;
        vm.recordLogs();
        vm.prank(feeCollector);
        sub.renewBatch(batch);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assert(_bal(receiver) == 3 * PRICE, "alice was charged, bob was not");
        bytes32 sig = keccak256("RenewBatchFailed(address,uint256,address[])");
        _assert(_count(logs, sig) == 1, "failure reported once");
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            (uint n, address[] memory failed) = abi.decode(logs[i].data, (uint, address[]));
            _assert(n == 1 && failed[0] == bob, "exactly bob failed");
        }
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("NotSelf(address)", stranger));
        sub.renewSelf(alice);
    }

    function test_SettleDebtPaysTheCallersOwnArrears() public {
        _subPlus(alice);
        vm.prank(alice);
        _expect("NoDebt()");
        sub.settleDebt();
        vm.warp(_now() + PERIOD + 1);
        uint before = _bal(alice);
        vm.prank(alice);
        sub.settleDebt();
        _assert(before - _bal(alice) == PRICE, "one period settled");
        vm.prank(bob);
        _expect("NotSubscribed()");
        sub.settleDebt();
    }

    // --- re-subscribing -----------------------------------------------------------

    function test_ResubscribeOnTheSameTermsSettlesArrearsAndMaySwitchToken() public {
        _subPlus(alice);
        vm.warp(_now() + 2 * PERIOD); // two periods owed
        uint usdtBefore = _bal(alice);
        vm.recordLogs();
        vm.prank(alice);
        sub.subscribe(PT_USDC, AMOUNT, PERIOD, 0, REF, address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assert(usdtBefore - _bal(alice) == 2 * PRICE, "arrears settled in the token held");
        _assert(MockERC20(USDC).balanceOf(receiver) == 0, "nothing charged on top");
        _assert(_count(logs, keccak256("DebtSettled(address,uint8,bytes32,uint256,uint256,uint256,uint256)")) == 1, "DebtSettled");
        _assert(_count(logs, keccak256("Subscribed(address,uint8,bytes32,uint256,uint32,address,uint256,uint256,uint256)")) == 0, "no Subscribed");
        _assert(sub.getActivePayToken(alice) == PT_USDC, "later charges use the new token");
        vm.warp(_now() + PERIOD);
        _renew(alice);
        _assert(MockERC20(USDC).balanceOf(receiver) == PRICE, "renewed in USDC");
    }

    function test_ResubscribeOnDifferentTermsIsRefusedWhileActive() public {
        _subPlus(alice);
        vm.warp(_now() + PERIOD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("MustCancelFirst(uint256,uint32,bytes32)", AMOUNT, PERIOD, REF));
        sub.subscribe(PT_USDT, AMOUNT + 1, PERIOD, 0, REF, address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("MustCancelFirst(uint256,uint32,bytes32)", AMOUNT, PERIOD, REF));
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF2, address(0));
    }

    function test_ResubscribeIsRefusedWhilePaidUpOrWithAParkedChange() public {
        _subPlus(alice);
        uint next = sub.nextChargeableAt(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotDueYet(uint256)", next));
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF, address(0));
        vm.prank(alice);
        sub.changeSubscription(AMOUNT / 2, PERIOD, REF2); // parked
        vm.warp(next);
        vm.prank(alice);
        _expect("PendingChangeExists()");
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF, address(0));
    }

    function test_CancelledAndElapsedStartsAfreshOnNewTerms() public {
        _subPlus(alice);
        vm.prank(alice);
        sub.cancelSubscription();
        uint next = sub.nextChargeableAt(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotDueYet(uint256)", next));
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF, address(0));
        vm.warp(next + 10 days); // the gap is never billed
        uint before = _bal(alice);
        _sub(alice, 5e8, 7 days, 0, REF2);
        _assert(before - _bal(alice) == 5e18, "charged the new amount only");
        TOSubscription.SubscriptionInfo memory s = sub.getSubscription(alice);
        _assert(s.amountUSD == 5e8 && s.period == 7 days && s.planRef == REF2, "new terms");
        _assert(s.nextChargeableAt == _now() + 7 days && !s.cancelled && s.active, "fresh anchor from now");
    }

    // --- cancelling and restoring ----------------------------------------------------

    function test_CancelWritesOffArrearsAndEndsServiceAtOnce() public {
        _subPlus(alice);
        vm.warp(sub.nextChargeableAt(alice) + 2 * PERIOD + 1); // three periods owed
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), 0); // cannot pay, must still be able to leave
        vm.recordLogs();
        vm.prank(alice);
        sub.cancelSubscription();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("DebtWrittenOff(address,bytes32,uint8,uint256,uint256)");
        _assert(_count(logs, sig) == 1, "arrears reported as written off");
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            (uint periods,) = abi.decode(logs[i].data, (uint, uint));
            _assert(periods == 3, "three periods written off");
        }
        _assert(!sub.isActive(alice) && !sub.canRestore(alice), "in arrears, so service ends now");
        vm.prank(feeCollector);
        _expect("AlreadyCancelled()");
        sub.renew(alice);
        vm.prank(alice);
        _expect("AlreadyCancelled()");
        sub.cancelSubscription();
    }

    function test_RestoreInsideThePaidUpWindowIsFree() public {
        _subPlus(alice);
        uint next = sub.nextChargeableAt(alice);
        vm.prank(alice);
        _expect("NotCancelled()");
        sub.restoreSubscription();
        vm.prank(alice);
        sub.cancelSubscription();
        _assert(sub.isActive(alice) && sub.canRestore(alice), "coasting on the paid period");
        uint before = _bal(alice);
        vm.prank(alice);
        sub.restoreSubscription();
        _assert(_bal(alice) == before && !sub.isCancelled(alice), "restored for free");
        _assert(sub.nextChargeableAt(alice) == next, "anchor untouched");
        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(next);
        _assert(!sub.isActive(alice), "entitlement over");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SubscriptionExpired(uint256)", next));
        sub.restoreSubscription();
    }

    // --- changing terms --------------------------------------------------------------

    function test_UpgradeWithTheSamePeriodChargesProRataAndKeepsTheAnchor() public {
        _subPlus(alice);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(_now() + PERIOD / 2);
        (bool immediate, uint chargedUSD, uint tokenAmount, uint effectiveAt) = sub.previewChange(alice, 50e8, PERIOD, REF2);
        _assert(immediate && chargedUSD == 15e8 && tokenAmount == 15e18 && effectiveAt == _now(), "preview: ($50-$20) * 1/2");
        uint before = _bal(alice);
        vm.prank(alice);
        sub.changeSubscription(50e8, PERIOD, REF2);
        _assert(before - _bal(alice) == 15e18, "charged the pro-rata difference");
        TOSubscription.SubscriptionInfo memory s = sub.getSubscription(alice);
        _assert(s.amountUSD == 50e8 && s.planRef == REF2 && s.nextChargeableAt == next, "new terms, same renewal date");
        vm.warp(next);
        _renew(alice);
        _assert(_bal(receiver) == PRICE + 15e18 + 50e18, "next renewal at the new amount");
    }

    function test_UpgradeToADifferentPeriodRestartsTheCycle() public {
        _subPlus(alice);
        vm.warp(_now() + PERIOD / 2);
        uint before = _bal(alice);
        vm.prank(alice);
        sub.changeSubscription(200e8, 365 days, REF2);
        _assert(before - _bal(alice) == 190e18, "$200 for the new cycle less $10 unused");
        _assert(sub.nextChargeableAt(alice) == _now() + 365 days, "cycle restarts now");
        _assert(sub.getSubscription(alice).period == 365 days, "period updated");
    }

    function test_DowngradeIsParkedAndLandsAtTheNextRenewal() public {
        _subPlus(alice);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(_now() + 10 days);
        (bool immediate, uint chargedUSD,, uint effectiveAt) = sub.previewChange(alice, 5e8, PERIOD, REF2);
        _assert(!immediate && chargedUSD == 0 && effectiveAt == next, "preview: parked until period end");
        uint before = _bal(alice);
        vm.prank(alice);
        sub.changeSubscription(5e8, PERIOD, REF2);
        _assert(_bal(alice) == before, "nothing charged now");
        TOSubscription.SubscriptionInfo memory s = sub.getSubscription(alice);
        _assert(s.amountUSD == AMOUNT && s.pendingAmountUSD == 5e8 && s.pendingPlanRef == REF2, "parked, current terms intact");
        vm.warp(next);
        vm.recordLogs();
        _renew(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assert(_count(logs, keccak256("SubscriptionDowngraded(address,bytes32,bytes32,uint256,uint32,uint256)")) == 1, "landed");
        _assert(_bal(receiver) == PRICE + 5e18, "renewed at the new amount");
        s = sub.getSubscription(alice);
        _assert(s.amountUSD == 5e8 && s.planRef == REF2 && s.pendingAmountUSD == 0, "terms swapped, slot cleared");
    }

    function test_AParkedChangeCanBeCalledOff() public {
        _subPlus(alice);
        vm.prank(alice);
        _expect("NoScheduledChange()");
        sub.cancelScheduledChange();
        vm.prank(alice);
        _expect("NoScheduledChange()");
        sub.changeSubscription(AMOUNT, PERIOD, REF); // same terms, nothing parked
        vm.prank(alice);
        sub.changeSubscription(5e8, PERIOD, REF2);
        vm.prank(alice);
        sub.changeSubscription(AMOUNT, PERIOD, REF); // same terms = call it off
        _assert(sub.getSubscription(alice).pendingAmountUSD == 0, "cleared by restating the terms");
        vm.prank(alice);
        sub.changeSubscription(5e8, PERIOD, REF2);
        vm.prank(alice);
        sub.cancelScheduledChange();
        _assert(sub.getSubscription(alice).pendingAmountUSD == 0, "cleared explicitly");
        // Paying to move up supersedes a parked downgrade.
        vm.prank(alice);
        sub.changeSubscription(5e8, PERIOD, REF2);
        vm.prank(alice);
        sub.changeSubscription(50e8, PERIOD, REF2);
        _assert(sub.getSubscription(alice).pendingAmountUSD == 0 && sub.getSubscription(alice).amountUSD == 50e8, "upgrade wins");
    }

    function test_ChangingMidTrialEndsItAndChargesAFullPeriod() public {
        _sub(alice, AMOUNT, PERIOD, TRIAL, REF);
        vm.warp(_now() + 1 days);
        uint before = _bal(alice);
        vm.prank(alice);
        sub.changeSubscription(5e8, PERIOD, REF2); // even a cheaper plan
        _assert(before - _bal(alice) == 5e18, "a whole period of the new terms, now");
        _assert(!sub.isInTrial(alice) && sub.getTrialEndsAt(alice) == 0, "trial over");
        _assert(sub.nextChargeableAt(alice) == _now() + PERIOD, "cycle starts now");
    }

    function test_ChangeInArrearsMustSettleFirst() public {
        _subPlus(alice);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SettleDebtFirst(uint256)", next));
        sub.changeSubscription(50e8, PERIOD, REF2);
        vm.expectRevert(abi.encodeWithSignature("SettleDebtFirst(uint256)", next));
        sub.previewChange(alice, 50e8, PERIOD, REF2);
        vm.expectRevert(abi.encodeWithSignature("SameTerms()"));
        sub.previewChange(alice, AMOUNT, PERIOD, REF);
    }

    function test_ChangeRespectsTheSameBoundsAsSubscribe() public {
        _subPlus(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PeriodOutOfRange(uint32,uint32,uint32)", uint32(1 hours), uint32(1 days), uint32(366 days)));
        sub.changeSubscription(50e8, 1 hours, REF2);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.prank(alice);
        _expect("AlreadyCancelled()");
        sub.changeSubscription(50e8, PERIOD, REF2);
    }

    // --- terminating ------------------------------------------------------------------

    function test_TerminateClearsEverythingButTrialEligibility() public {
        _sub(alice, AMOUNT, PERIOD, TRIAL, REF);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotSubscriptionTerminator(address,address)", terminator, alice));
        sub.terminateSubscription(alice);
        vm.prank(terminator);
        sub.terminateSubscription(alice);
        TOSubscription.SubscriptionInfo memory s = sub.getSubscription(alice);
        _assert(s.amountUSD == 0 && s.nextChargeableAt == 0 && s.payToken == 0 && s.trialEndsAt == 0 && !s.active, "wiped");
        _assert(sub.hasEverSubscribed(alice) && !sub.startsTrial(alice), "no second trial after a terminate");
        vm.prank(terminator);
        _expect("NotSubscribed()");
        sub.terminateSubscription(alice);
        _subPlus(alice);
        _assert(sub.nextChargeableAt(alice) == _now() + PERIOD, "can subscribe again afresh");
    }

    // --- guards -----------------------------------------------------------------------

    function test_SwitchStopsNewMoneyButNotLeaving() public {
        _subPlus(alice);
        vm.prank(timelock);
        sub.setSwitch(false);
        vm.prank(bob);
        _expect("SwitchOff()");
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF, address(0));
        vm.prank(alice);
        _expect("SwitchOff()");
        sub.changeSubscription(50e8, PERIOD, REF2);
        vm.warp(_now() + PERIOD);
        _renew(alice); // billing commitments still run
        vm.prank(alice);
        sub.cancelSubscription(); // and leaving always works
        _assert(sub.isCancelled(alice), "cancelled while paused");
    }

    function test_SelfReferralIsRefusedAndInviterChangesAreReported() public {
        vm.prank(alice);
        _expect("InvalidInviter()");
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF, alice);
        vm.recordLogs();
        vm.prank(alice);
        sub.subscribe(PT_USDT, AMOUNT, PERIOD, 0, REF, bob);
        _assert(_count(vm.getRecordedLogs(), keccak256("InviterChanged(address,address,address)")) == 1, "reported");
        _assert(sub.getInviter(alice) == bob, "stored");
    }

    function test_OwnerSettersRefuseEveryoneElse() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, alice));
        sub.setFeeCollector(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, alice));
        sub.setMaxTrialPeriod(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, alice));
        sub.setReceiver(alice);
        vm.prank(timelock);
        sub.setFeeCollector(alice);
        _assert(sub.getFeeCollector() == alice, "owner may");
    }

    function test_TheContractNeverHoldsTokens() public {
        _subPlus(alice);
        vm.warp(_now() + 3 * PERIOD);
        _renew(alice);
        _assert(_bal(address(sub)) == 0, "every transfer goes straight to the receiver");
    }
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";

/// changeSubscription: upgrades charge now, downgrades wait for the period to end.
contract PlanChangeTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant GO_MONTH = 1;
    uint constant PLUS_MONTH = 2;
    uint constant PRO_MONTH = 4;
    uint constant GO_YEAR = 5;
    uint constant PLUS_YEAR = 6;
    uint constant PERIOD = 30 days;
    uint constant YEAR = 365 days;
    uint constant TRIAL = 3 days;

    uint constant USD = 1e8;
    uint constant GO_PRICE = 5 * USD;
    uint constant PRO_PRICE = 200 * USD;
    uint constant PLUS_PRICE = 1999 * USD / 100;
    uint constant GO_YEAR_PRICE = 48 * USD;
    uint constant PLUS_YEAR_PRICE = 19188 * USD / 100;

    function _usdt(uint usd18) private pure returns (uint) { return usd18 * 1e18 / USD; }

    Subscription sub;
    address timelock;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);
        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = new Subscription(receiver, feeCollector, address(0xDEAD), 0, roles, roles, address(0));
        timelock = sub.getOwner();
        MockERC20(USDT).mint(alice, 1_000_000e18);
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.warp(1_000_000);
    }

    function _assert(bool ok, string memory what) private pure { require(ok, what); }
    function _rcv() private view returns (uint) { return MockERC20(USDT).balanceOf(receiver); }
    function _sub(uint t) private { vm.prank(alice); sub.subscriptionUSDT(t, address(0)); }
    function _change(uint t) private { vm.prank(alice); sub.changeSubscription(t); }

    // --- upgrades -----------------------------------------------------------

    /// Same-length plans keep the renewal date; only the pro-rata difference is charged.
    function test_UpgradeSamePeriodKeepsTheAnchorAndChargesTheDifference() public {
        _sub(GO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(block.timestamp + 10 days);
        uint paid = _rcv();

        // (200 - 5) * 20/30 = $130
        (bool immediate, uint charged, uint tokens, uint effectiveAt) = sub.previewChange(alice, PRO_MONTH);
        _assert(immediate, "upgrade is immediate");
        _assert(charged == 130 * USD, "preview says $130");
        _assert(tokens == _usdt(130 * USD), "in USDT");
        _assert(effectiveAt == block.timestamp, "effective now");

        _change(PRO_MONTH);
        _assert(_rcv() - paid == _usdt(130 * USD), "charged the difference");
        _assert(sub.getActiveType(alice) == PRO_MONTH, "on PRO now");
        _assert(sub.nextChargeableAt(alice) == next, "renewal date unchanged");
        _assert(sub.getLockedPeriod(alice) == PERIOD, "still a 30d cycle");

        // and the next renewal is a full PRO period
        vm.warp(next);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(sub.nextChargeableAt(alice) == next + PERIOD, "steps by 30d");
    }

    /// A different-length plan buys a whole new cycle, crediting the unused tail of the old one.
    function test_UpgradeToDifferentPeriodRestartsTheCycle() public {
        _sub(GO_MONTH);
        vm.warp(block.timestamp + 10 days);
        uint paid = _rcv();

        // 48 - 5 * 20/30 = 48 - 3.33333333 = $44.66666667
        uint expected = GO_YEAR_PRICE - GO_PRICE * 20 days / PERIOD;
        (, uint charged,,) = sub.previewChange(alice, GO_YEAR);
        _assert(charged == expected, "credits the unused tail");

        _change(GO_YEAR);
        _assert(_rcv() - paid == _usdt(expected), "charged a year minus the credit");
        _assert(sub.getLockedPeriod(alice) == YEAR, "now on a yearly cycle");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + YEAR, "cycle restarts now");
    }

    /// Dropping a tier but moving to a yearly plan still costs money, so it goes through
    /// immediately rather than being parked.
    function test_LowerTierButLongerPeriodIsStillPaidUpfront() public {
        _sub(PRO_MONTH);
        vm.warp(block.timestamp + 10 days);
        uint paid = _rcv();

        // 191.88 - 200 * 20/30 = $58.54666667
        uint expected = PLUS_YEAR_PRICE - PRO_PRICE * 20 days / PERIOD;
        _change(PLUS_YEAR);
        _assert(_rcv() - paid == _usdt(expected), "pays the difference for the year");
        _assert(sub.getActiveType(alice) == PLUS_YEAR, "switched immediately");
    }

    // --- downgrades ---------------------------------------------------------

    function test_DowngradeIsParkedUntilThePeriodEnds() public {
        _sub(PRO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(block.timestamp + 10 days);
        uint paid = _rcv();

        (bool immediate, uint charged,, uint effectiveAt) = sub.previewChange(alice, GO_MONTH);
        _assert(!immediate, "downgrade waits");
        _assert(charged == 0, "nothing charged");
        _assert(effectiveAt == next, "lands at period end");

        _change(GO_MONTH);
        _assert(_rcv() == paid, "no money moved");
        _assert(sub.getActiveType(alice) == PRO_MONTH, "still on PRO for now");
        _assert(sub.getPendingType(alice) == GO_MONTH, "GO is parked");

        // at period end the renewal itself performs the switch and bills the cheaper plan
        vm.warp(next);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(sub.getActiveType(alice) == GO_MONTH, "switched at period end");
        _assert(sub.getPendingType(alice) == 0, "slot cleared");
        _assert(_rcv() - paid == _usdt(GO_PRICE), "billed at the new plan");
    }

    function test_DowngradeToADifferentPeriodTakesTheNewCycleLength() public {
        _sub(PRO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        _change(GO_YEAR); // 48 - 200 = negative => parked
        _assert(sub.getPendingType(alice) == GO_YEAR, "parked");

        vm.warp(next);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(sub.getLockedPeriod(alice) == YEAR, "picks up the yearly cycle");
        _assert(sub.nextChargeableAt(alice) == next + YEAR, "and anchors on it");
    }

    // --- what happens to a parked change ------------------------------------

    function test_UpgradingDiscardsAParkedDowngrade() public {
        _sub(PLUS_MONTH);
        vm.warp(block.timestamp + TRIAL); // let the trial lapse
        vm.prank(feeCollector);
        sub.renew(alice);

        _change(GO_MONTH);
        _assert(sub.getPendingType(alice) == GO_MONTH, "parked");
        _change(PRO_MONTH);
        _assert(sub.getActiveType(alice) == PRO_MONTH, "upgraded now");
        _assert(sub.getPendingType(alice) == 0, "parked downgrade discarded");
    }

    function test_ASecondDowngradeOverwritesTheParkedOne() public {
        _sub(PRO_MONTH);
        _change(GO_MONTH);
        _change(PLUS_MONTH);
        _assert(sub.getPendingType(alice) == PLUS_MONTH, "overwritten, not stacked");
    }

    function test_ParkedDowngradeCanBeCalledOff() public {
        _sub(PRO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        _change(GO_MONTH);
        vm.prank(alice);
        sub.cancelScheduledChange();
        _assert(sub.getPendingType(alice) == 0, "slot cleared");

        vm.warp(next);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(sub.getActiveType(alice) == PRO_MONTH, "stayed on PRO");
    }

    /// Asking to change to the plan already held is how a front end calls off a parked change.
    function test_ChangingToTheCurrentPlanClearsTheSlot() public {
        _sub(PRO_MONTH);
        _change(GO_MONTH);
        _change(PRO_MONTH);
        _assert(sub.getPendingType(alice) == 0, "slot cleared");
        _assert(sub.getActiveType(alice) == PRO_MONTH, "unchanged");
    }

    function test_CancellingSupersedesAParkedDowngrade() public {
        _sub(PRO_MONTH);
        _change(GO_MONTH);
        vm.prank(alice);
        sub.cancelSubscription();
        _assert(sub.getPendingType(alice) == 0, "downgrade dropped");
        _assert(sub.isCancelled(alice), "cancellation owns the slot");
    }

    // --- trials -------------------------------------------------------------

    /// The trial belongs to the plan it was offered on. Leaving it ends it there and then,
    /// and a full period of the new plan is charged immediately.
    function test_MidTrialChangeEndsTheTrialAndChargesNow() public {
        _sub(PLUS_MONTH); // 3-day trial, nothing charged
        _assert(sub.isInTrial(alice), "on trial");
        _assert(_rcv() == 0, "nothing charged yet");

        vm.warp(block.timestamp + 1 days);
        (bool immediate, uint charged,, uint effectiveAt) = sub.previewChange(alice, PRO_MONTH);
        _assert(immediate, "takes effect now");
        _assert(charged == PRO_PRICE, "a whole PRO period, nothing pro-rated");
        _assert(effectiveAt == block.timestamp, "effective now");

        _change(PRO_MONTH);
        _assert(_rcv() == _usdt(PRO_PRICE), "charged a full PRO period on the spot");
        _assert(sub.getActiveType(alice) == PRO_MONTH, "swapped");
        _assert(!sub.isInTrial(alice), "trial is over");
        _assert(sub.getTrialEndsAt(alice) == 0, "trial cleared");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + PERIOD, "cycle restarts now");
    }

    /// Even a cheaper plan is charged in full: nothing was ever paid, so there is no remaining
    /// value to pro-rate and nothing to park until period end.
    function test_MidTrialChangeToACheaperPlanAlsoChargesNow() public {
        _sub(PLUS_MONTH);
        vm.warp(block.timestamp + 1 days);
        _change(GO_MONTH);
        _assert(_rcv() == _usdt(GO_PRICE), "a whole GO period charged now");
        _assert(sub.getActiveType(alice) == GO_MONTH, "swapped immediately, not parked");
        _assert(sub.getPendingType(alice) == 0, "nothing parked");
    }

    /// Leaving the trial spends it for good — coming back to PLUS_MONTH later is paid.
    function test_MidTrialChangeSpendsThePlusTrialForGood() public {
        _sub(PLUS_MONTH);
        _change(PRO_MONTH);
        _assert(sub.hasEverSubscribed(alice), "trial eligibility is spent");
        _assert(!sub.startsTrial(alice, PLUS_MONTH), "no second free ride on PLUS");
    }

    /// The trial is a one-off tied to the first subscription, so moving onto another
    /// trial-bearing plan is charged in full just like any other destination.
    function test_MidTrialChangeToAnotherTrialPlanIsStillCharged() public {
        vm.prank(timelock);
        sub.setTrialPeriod(PRO_MONTH, 7 days);
        _sub(PLUS_MONTH);
        vm.warp(block.timestamp + 1 days);

        (bool immediate, uint charged,,) = sub.previewChange(alice, PRO_MONTH);
        _assert(immediate, "immediate");
        _assert(charged == PRO_PRICE, "a whole PRO period, no second trial");

        _change(PRO_MONTH);
        _assert(_rcv() == _usdt(PRO_PRICE), "charged in full");
        _assert(!sub.isInTrial(alice), "no trial running");
        _assert(sub.nextChargeableAt(alice) == block.timestamp + PERIOD, "a paid cycle from now");
    }

    /// Having ever subscribed — even to a plan with no trial, even after cancelling and
    /// lapsing — permanently ends trial eligibility.
    function test_TrialIsGoneOnceAnyPlanHasBeenHeld() public {
        vm.prank(timelock);
        sub.setTrialPeriod(PLUS_MONTH, uint32(TRIAL));
        _assert(sub.startsTrial(alice, PLUS_MONTH), "eligible before the first subscribe");

        _sub(GO_MONTH); // a paid plan with no trial of its own
        _assert(sub.hasEverSubscribed(alice), "eligibility burnt");
        _assert(!sub.startsTrial(alice, PLUS_MONTH), "no trial any more");

        // cancel, let it lapse, come back: still no trial
        uint next = sub.nextChargeableAt(alice);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.warp(next);
        uint paid = _rcv();
        _sub(PLUS_MONTH);
        _assert(_rcv() - paid == _usdt(PLUS_PRICE), "PLUS is paid for");
        _assert(!sub.isInTrial(alice), "no trial on return");
    }

    /// Changing plans can never open a trial: changing presupposes a subscription, and having
    /// one is exactly what disqualifies an account.
    function test_ChangeOntoATrialPlanNeverTrials() public {
        vm.prank(timelock);
        sub.setTrialPeriod(PRO_MONTH, 7 days);
        _sub(GO_MONTH);
        vm.warp(block.timestamp + 10 days);
        uint paid = _rcv();

        // priced as an ordinary pro-rata upgrade, taking effect at once
        (bool immediate, uint charged,,) = sub.previewChange(alice, PRO_MONTH);
        _assert(immediate, "immediate, not parked for a trial");
        _assert(charged == (PRO_PRICE - GO_PRICE) * 20 days / PERIOD, "plain pro-rata difference");

        _change(PRO_MONTH);
        _assert(_rcv() > paid, "money moved");
        _assert(!sub.isInTrial(alice), "no trial");
    }

    /// Cancelling during the trial is unaffected: it still costs nothing.
    function test_CancellingDuringTrialStillCostsNothing() public {
        _sub(PLUS_MONTH);
        uint trialEnd = sub.nextChargeableAt(alice);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        sub.cancelSubscription();
        _assert(_rcv() == 0, "no charge");
        vm.warp(trialEnd);
        vm.prank(feeCollector);
        vm.expectRevert(abi.encodeWithSignature("AlreadyCancelled()"));
        sub.renew(alice);
    }

    // --- guards -------------------------------------------------------------

    function test_CancelledAccountMustRestoreBeforeChanging() public {
        _sub(PRO_MONTH);
        vm.prank(alice);
        sub.cancelSubscription();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("AlreadyCancelled()"));
        sub.changeSubscription(GO_MONTH);
    }

    function test_ArrearsMustBeSettledBeforeChanging() public {
        _sub(GO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SettleDebtFirst(uint256)", next));
        sub.changeSubscription(PRO_MONTH);
    }

    function test_ResubscribingWithAParkedChangeIsRejected() public {
        _sub(PRO_MONTH);
        uint next = sub.nextChargeableAt(alice);
        _change(GO_MONTH);
        vm.warp(next);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PendingChangeExists(uint256)", GO_MONTH));
        sub.subscriptionUSDT(PRO_MONTH, address(0));
    }

    function test_NothingToCallOff() public {
        _sub(PRO_MONTH);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NoScheduledChange()"));
        sub.cancelScheduledChange();
    }
}

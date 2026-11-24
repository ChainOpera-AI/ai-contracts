// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/to_subscription.sol";
import "./mocks.sol";
import "./deployTO.sol";

/// Drives TOSubscription with bounded random user actions. Every call is wrapped: a revert is
/// a legitimate outcome, what matters is the state left behind.
contract TOHandler {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    TOSubscription public sub;
    bool public cancelWasRefused;
    bool public cancelSucceededWrongly;
    address public feeCollector;
    address public terminator;
    address[] public actors;

    constructor(TOSubscription s, address fc, address term, address[] memory a) {
        sub = s; feeCollector = fc; terminator = term; actors = a;
    }

    function _actor(uint seed) internal view returns (address) { return actors[seed % actors.length]; }
    function _amount(uint seed) internal pure returns (uint) { return 1e8 + (seed % 200) * 1e8; }
    function _period(uint seed) internal pure returns (uint32) {
        uint32[4] memory p = [uint32(1 days), 7 days, 30 days, 365 days];
        return p[seed % 4];
    }
    function _ref(uint seed) internal pure returns (bytes32) { return bytes32(seed % 5); }

    function subscribe(uint actorSeed, uint amountSeed, uint periodSeed, uint trialSeed, uint tokenSeed) external {
        address a = _actor(actorSeed);
        uint8 token = uint8(tokenSeed % 3) + 1;
        uint32 trial = trialSeed % 3 == 0 ? 0 : uint32(1 days + (trialSeed % 29 days));
        vm.prank(a);
        try sub.subscribe(token, _amount(amountSeed), _period(periodSeed), trial, _ref(amountSeed), address(0)) {} catch {}
    }

    function change(uint actorSeed, uint amountSeed, uint periodSeed) external {
        vm.prank(_actor(actorSeed));
        try sub.changeSubscription(_amount(amountSeed), _period(periodSeed), _ref(periodSeed)) {} catch {}
    }

    /// Arrears are written off rather than charged, so an account that holds terms and has
    /// not already cancelled must ALWAYS be able to leave.
    function cancel(uint actorSeed) external {
        address a = _actor(actorSeed);
        bool shouldSucceed = sub.isSubscribed(a) && !sub.isCancelled(a);
        vm.prank(a);
        try sub.cancelSubscription() {
            if (!shouldSucceed) cancelSucceededWrongly = true;
        } catch {
            if (shouldSucceed) cancelWasRefused = true;
        }
    }

    function terminate(uint actorSeed) external {
        vm.prank(terminator);
        try sub.terminateSubscription(_actor(actorSeed)) {} catch {}
    }

    function restore(uint actorSeed) external {
        vm.prank(_actor(actorSeed));
        try sub.restoreSubscription() {} catch {}
    }

    function callOffScheduled(uint actorSeed) external {
        vm.prank(_actor(actorSeed));
        try sub.cancelScheduledChange() {} catch {}
    }

    function settle(uint actorSeed) external {
        vm.prank(_actor(actorSeed));
        try sub.settleDebt() {} catch {}
    }

    function renew(uint actorSeed) external {
        vm.prank(feeCollector);
        try sub.renew(_actor(actorSeed)) {} catch {}
    }

    function renewAll() external {
        address[] memory batch = actors;
        vm.prank(feeCollector);
        try sub.renewBatch(batch) {} catch {}
    }

    function passTime(uint secondsSeed) external {
        // 1 hour .. ~45 days, so periods and trials both get crossed
        vm.warp(vm.getBlockTimestamp() + 1 hours + (secondsSeed % 39 days));
    }
}

contract TOInvariantTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0x778121B464151FE5d931587c457E48FcAaA0dc7A;

    uint constant MINT_EACH = 1_000_000e18;
    uint constant ACTORS = 4;

    TOSubscription sub;
    TOHandler handler;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address[] actors;

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);
        vm.warp(1_000_000);

        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = deployTOSubscription(receiver, feeCollector, terminator, 0, roles, roles, address(0));

        for (uint i = 0; i < ACTORS; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            MockERC20(USDT).mint(a, MINT_EACH);
            MockERC20(USDC).mint(a, MINT_EACH);
            MockERC20(COAI).mint(a, MINT_EACH);
            vm.prank(a); MockERC20(USDT).approve(address(sub), type(uint).max);
            vm.prank(a); MockERC20(USDC).approve(address(sub), type(uint).max);
            vm.prank(a); MockERC20(COAI).approve(address(sub), type(uint).max);
        }
        handler = new TOHandler(sub, feeCollector, terminator, actors);
    }

    function targetContracts() public view returns (address[] memory) {
        address[] memory t = new address[](1);
        t[0] = address(handler);
        return t;
    }

    function _assert(bool ok, string memory what) internal pure { require(ok, what); }
    function _held(address who) private view returns (uint) {
        return MockERC20(USDT).balanceOf(who) + MockERC20(USDC).balanceOf(who) + MockERC20(COAI).balanceOf(who);
    }

    function invariant_CancellingIsAlwaysAvailable() public view {
        _assert(!handler.cancelWasRefused(), "a subscribed account was refused a cancel");
        _assert(!handler.cancelSucceededWrongly(), "cancel went through on an account with no terms");
    }

    function invariant_ContractNeverHoldsTokens() public view {
        _assert(_held(address(sub)) == 0, "tokens stuck in the contract");
    }

    function invariant_TokensAreConserved() public view {
        uint held = _held(receiver);
        for (uint i = 0; i < actors.length; i++) held += _held(actors[i]);
        _assert(held == 3 * MINT_EACH * actors.length, "tokens appeared or vanished");
    }

    /// Terms on an account always come with the bookkeeping the charging path depends on,
    /// and always inside the bounds that were in force -- the owner never changed them here.
    function invariant_SubscribedAccountIsFullyFormed() public view {
        (uint32 lo, uint32 hi) = sub.getPeriodBounds();
        for (uint i = 0; i < actors.length; i++) {
            TOSubscription.SubscriptionInfo memory s = sub.getSubscription(actors[i]);
            if (s.amountUSD == 0) {
                _assert(s.nextChargeableAt == 0 && s.payToken == 0 && !s.cancelled && s.pendingAmountUSD == 0, "state without terms");
                continue;
            }
            _assert(s.nextChargeableAt != 0, "terms without an anchor");
            _assert(s.period >= lo && s.period <= hi, "period outside the bounds");
            _assert(s.payToken != 0, "terms without a pay token");
            if (s.pendingAmountUSD != 0) {
                _assert(s.pendingPeriod >= lo && s.pendingPeriod <= hi, "parked period outside the bounds");
            }
        }
    }

    function invariant_CancelAndPendingAreMutuallyExclusive() public view {
        for (uint i = 0; i < actors.length; i++) {
            TOSubscription.SubscriptionInfo memory s = sub.getSubscription(actors[i]);
            if (s.cancelled) _assert(s.pendingAmountUSD == 0, "cancelled account still has a parked change");
            if (s.pendingAmountUSD != 0) _assert(s.amountUSD != 0 && !s.cancelled, "parked change without a live subscription");
        }
    }

    function invariant_TrialStateIsCoherent() public view {
        for (uint i = 0; i < actors.length; i++) {
            address a = actors[i];
            if (sub.getTrialEndsAt(a) != 0) _assert(sub.hasEverSubscribed(a), "trial on an account that never subscribed");
            if (sub.isInTrial(a)) _assert(sub.isSubscribed(a), "in trial without terms");
            _assert(sub.startsTrial(a) == !sub.hasEverSubscribed(a), "eligibility is exactly first-subscription");
        }
    }

    function invariant_ActiveAgreesWithState() public view {
        for (uint i = 0; i < actors.length; i++) {
            address a = actors[i];
            TOSubscription.SubscriptionInfo memory s = sub.getSubscription(a);
            bool expected = s.amountUSD != 0 && !(s.cancelled && vm.getBlockTimestamp() >= s.nextChargeableAt);
            _assert(sub.isActive(a) == expected, "isActive diverged from the stored state");
            _assert(sub.canRestore(a) == (s.amountUSD != 0 && s.cancelled && vm.getBlockTimestamp() < s.nextChargeableAt), "canRestore diverged");
        }
    }
}

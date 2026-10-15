// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";
import "./deploy.sol";

/// Drives the contract with bounded random user actions so the fuzzer can explore state the
/// hand-written tests do not reach. Every call is wrapped: a revert is a legitimate outcome,
/// what matters is the state left behind.
contract Handler {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    Subscription public sub;
    bool public cancelWasRefused;        // a subscribed, uncancelled account could not leave
    bool public cancelSucceededWrongly;  // cancel went through where it had no right to
    address public feeCollector;
    address public terminator;
    address public importer;
    address[] public actors;
    address public usdt;

    constructor(Subscription s, address fc, address term, address imp, address usdtAddr, address[] memory a) {
        sub = s; feeCollector = fc; terminator = term; importer = imp; usdt = usdtAddr; actors = a;
    }

    function _actor(uint seed) internal view returns (address) { return actors[seed % actors.length]; }
    function _type(uint seed) internal pure returns (uint) { return (seed % 8) + 1; }

    function subscribe(uint actorSeed, uint typeSeed, uint tokenSeed) external {
        address a = _actor(actorSeed);
        uint t = _type(typeSeed);
        vm.prank(a);
        if (tokenSeed % 2 == 0) {
            try sub.subscriptionUSDT(t, address(0)) {} catch {}
        } else {
            try sub.subscriptionUSDC(t, address(0)) {} catch {}
        }
    }

    function change(uint actorSeed, uint typeSeed) external {
        address a = _actor(actorSeed);
        vm.prank(a);
        try sub.changeSubscription(_type(typeSeed)) {} catch {}
    }

    /// Since arrears are written off rather than charged, an account that holds a plan and
    /// has not already cancelled must ALWAYS be able to leave -- no balance, no allowance and
    /// no working COAI quote required. Swallowing a revert here would hide exactly that.
    function cancel(uint actorSeed) external {
        address a = _actor(actorSeed);
        bool shouldSucceed = sub.getActiveType(a) != 0 && !sub.isCancelled(a);
        vm.prank(a);
        // Recorded rather than required: fail_on_revert is off, so a revert raised here would
        // only be counted, never surfaced. invariant_CancellingIsAlwaysAvailable reads these.
        try sub.cancelSubscription() {
            if (!shouldSucceed) cancelSucceededWrongly = true;
        } catch {
            if (shouldSucceed) cancelWasRefused = true;
        }
    }

    /// The terminator wipes an account outright, and nothing else in the handler clears
    /// _activeType, so without this the fuzzer never sees a post-terminate account.
    function terminate(uint actorSeed) external {
        vm.prank(terminator);
        try sub.terminateSubscription(_actor(actorSeed)) {} catch {}
    }

    /// Imported accounts must behave like natively subscribed ones. Rows are built to pass
    /// the import checks, so anything the invariants catch here is a real interaction and
    /// not just bad input -- ImportIntegrity covers the rejections.
    function importOne(uint actorSeed, uint typeSeed, uint tokenSeed, uint whenSeed, bool cancelled) external {
        address a = _actor(actorSeed);
        uint t = _type(typeSeed);
        uint32 period = sub.getSubscriptionPeriod(t);
        if (period == 0) return;
        Subscription.ImportedAccount[] memory rows = new Subscription.ImportedAccount[](1);
        rows[0] = Subscription.ImportedAccount({
            account: a,
            subscriptionType: t,
            payToken: uint8(tokenSeed % 3) + 1,
            lockedPeriod: period,
            // straddle the anchor so both paid-up and in-arrears accounts get imported
            nextChargeableAt: _anchorAround(uint(period), whenSeed),
            // the pending slot and the cancelled flag are mutually exclusive
            pendingType: cancelled ? 0 : (typeSeed % 2 == 0 ? 0 : _type(typeSeed + 1)),
            trialEndsAt: 0,
            cancelled: cancelled,
            everSubscribed: true,
            inviter: address(0)
        });
        vm.prank(importer);
        try sub.importAccounts(rows) {} catch {}
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

    /// An anchor on either side of now, so both paid-up and in-arrears accounts get imported.
    /// Import refuses 0, and subtracting a yearly period from an early timestamp would underflow.
    function _anchorAround(uint period, uint seed) internal view returns (uint) {
        uint base = vm.getBlockTimestamp();
        uint a = base > period ? base - period + (seed % (2 * period)) : base + 1 + (seed % period);
        return a == 0 ? 1 : a;
    }

    function actorCount() external view returns (uint) { return actors.length; }
}

contract InvariantTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant MINT_EACH = 1_000_000e18;
    uint constant ACTORS = 4;

    Subscription sub;
    Handler handler;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address importer = address(0x1A4F);
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
        sub = deploySubscription(receiver, feeCollector, terminator, importer, 0, roles, roles, address(0));

        for (uint i = 0; i < ACTORS; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            MockERC20(USDT).mint(a, MINT_EACH);
            MockERC20(USDC).mint(a, MINT_EACH);
            vm.prank(a);
            MockERC20(USDT).approve(address(sub), type(uint).max);
            vm.prank(a);
            MockERC20(USDC).approve(address(sub), type(uint).max);
        }

        handler = new Handler(sub, feeCollector, terminator, importer, USDT, actors);
    }

    /// Foundry reads this to confine the fuzzer to the handler, instead of letting it call
    /// owner-only functions on the contract under test directly.
    function targetContracts() public view returns (address[] memory) {
        address[] memory t = new address[](1);
        t[0] = address(handler);
        return t;
    }

    function _assert(bool ok, string memory what) internal pure { require(ok, what); }

    /// Leaving is unconditional: the 2026-10-10 change gives arrears up rather than charging
    /// them, so no balance, allowance or oracle state can trap a subscriber in a plan.
    function invariant_CancellingIsAlwaysAvailable() public view {
        _assert(!handler.cancelWasRefused(), "a subscribed account was refused a cancel");
        _assert(!handler.cancelSucceededWrongly(), "cancel went through on an account with no plan");
    }

    /// The contract forwards every payment and must never sit on a balance.
    function invariant_ContractNeverHoldsTokens() public view {
        _assert(MockERC20(USDT).balanceOf(address(sub)) == 0, "USDT stuck in the contract");
        _assert(MockERC20(USDC).balanceOf(address(sub)) == 0, "USDC stuck in the contract");
    }

    /// Nothing is minted or burnt: what left the actors is exactly what the receiver holds.
    function invariant_TokensAreConserved() public view {
        uint held = MockERC20(USDT).balanceOf(receiver) + MockERC20(USDC).balanceOf(receiver);
        for (uint i = 0; i < actors.length; i++) {
            held += MockERC20(USDT).balanceOf(actors[i]) + MockERC20(USDC).balanceOf(actors[i]);
        }
        _assert(held == 2 * MINT_EACH * actors.length, "tokens appeared or vanished");
    }

    /// A live subscription always has the bookkeeping the charging path depends on.
    function invariant_ActiveSubscriptionIsFullyFormed() public view {
        for (uint i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint t = sub.getActiveType(a);
            if (t == 0) continue;
            _assert(sub.getNextChargeableAt(a, t) != 0, "active type without an anchor");
            _assert(sub.getLockedPeriod(a) != 0, "active type without a locked period");
            _assert(sub.getActivePayToken(a) != 0, "active type without a pay token");
        }
    }

    /// Cancellation and a parked downgrade share one end-of-period slot.
    function invariant_CancelAndPendingAreMutuallyExclusive() public view {
        for (uint i = 0; i < actors.length; i++) {
            address a = actors[i];
            if (sub.isCancelled(a)) {
                _assert(sub.getPendingType(a) == 0, "cancelled account still has a parked change");
            }
            if (sub.getPendingType(a) != 0) {
                _assert(sub.getActiveType(a) != 0, "parked change without a subscription");
                _assert(!sub.isCancelled(a), "parked change on a cancelled account");
            }
        }
    }

    /// Trial state can only exist on an account that has subscribed, and eligibility is one-way.
    function invariant_TrialStateIsCoherent() public view {
        for (uint i = 0; i < actors.length; i++) {
            address a = actors[i];
            if (sub.getTrialEndsAt(a) != 0) {
                _assert(sub.hasEverSubscribed(a), "trial recorded on an account that never subscribed");
            }
            if (sub.isInTrial(a)) {
                _assert(sub.getActiveType(a) != 0, "in trial without a subscription");
            }
            if (sub.hasEverSubscribed(a)) {
                _assert(!sub.startsTrial(a, 2), "trial offered to an account that has subscribed");
            }
        }
    }

    /// getEffectiveType must never claim entitlement the account does not have.
    function invariant_EffectiveTypeAgreesWithState() public view {
        for (uint i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint eff = sub.getEffectiveType(a);
            if (eff == 0) continue;
            _assert(eff == sub.getActiveType(a), "effective type diverged from the stored one");
            if (sub.isCancelled(a)) {
                _assert(vm.getBlockTimestamp() < sub.getNextChargeableAt(a, eff), "entitled past a cancelled period");
            }
        }
    }
}

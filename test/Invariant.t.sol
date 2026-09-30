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
    address public feeCollector;
    address[] public actors;
    address public usdt;

    constructor(Subscription s, address fc, address usdtAddr, address[] memory a) {
        sub = s; feeCollector = fc; usdt = usdtAddr; actors = a;
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

    function cancel(uint actorSeed) external {
        vm.prank(_actor(actorSeed));
        try sub.cancelSubscription() {} catch {}
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
        sub = deploySubscription(receiver, feeCollector, address(0xDEAD), 0, roles, roles, address(0));

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

        handler = new Handler(sub, feeCollector, USDT, actors);
    }

    /// Foundry reads this to confine the fuzzer to the handler, instead of letting it call
    /// owner-only functions on the contract under test directly.
    function targetContracts() public view returns (address[] memory) {
        address[] memory t = new address[](1);
        t[0] = address(handler);
        return t;
    }

    function _assert(bool ok, string memory what) internal pure { require(ok, what); }

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

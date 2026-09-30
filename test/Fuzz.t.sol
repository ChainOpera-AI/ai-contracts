// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";
import "./deploy.sol";

/// A PancakeV3 pool whose TWAP can be moved between calls.
contract VariableTickPool {
    address public token0;
    address public token1;
    int56 tickPerSecond;
    bool broken;

    function setTokens(address a, address b) external { token0 = a; token1 = b; }
    function setTick(int24 t) external { tickPerSecond = int56(t); }
    function breakIt(bool b) external { broken = b; }

    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory, uint160[] memory)
    {
        require(!broken, "OLD");
        int56[] memory ticks = new int56[](secondsAgos.length);
        // cumulative tick at `secondsAgo` back: older entry is smaller by tick * elapsed
        for (uint i = 0; i < secondsAgos.length; i++) {
            ticks[i] = tickPerSecond * int56(int32(int(uint(1_000_000)) - int(uint(secondsAgos[i]))));
        }
        return (ticks, new uint160[](secondsAgos.length));
    }
}

contract FuzzTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant PERIOD = 30 days;

    Subscription sub;
    address timelock;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(VariableTickPool).runtimeCode);
        VariableTickPool(POOL).setTokens(COAI, USDT);
        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = deploySubscription(receiver, feeCollector, address(0xDEAD), 0, roles, roles, address(0));
        timelock = sub.getOwner();
        MockERC20(USDT).mint(alice, 1e30);
        MockERC20(COAI).mint(alice, 1e30);
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.prank(alice);
        MockERC20(COAI).approve(address(sub), type(uint).max);
        vm.warp(1_000_000);
    }

    function _assert(bool ok, string memory what) private pure { require(ok, what); }
    function _bound(uint x, uint lo, uint hi) private pure returns (uint) { return lo + (x % (hi - lo + 1)); }
    function _paid() private view returns (uint) { return MockERC20(USDT).balanceOf(receiver); }

    /// Upgrading part-way through a period must never cost more in total than having
    /// subscribed to the destination plan from the start of that same period.
    function testFuzz_UpgradingNeverCostsMoreThanStartingOnTheDearerPlan(
        uint elapsedSeed,
        uint fromSeed,
        uint toSeed
    ) public {
        // PLUS_MONTH ships with a trial, which anchors the first charge 3 days out instead of
        // 30 and would put the account in arrears long before `elapsed` runs out. This test is
        // about pro-rata maths, so take the trial out of the picture.
        vm.prank(timelock);
        sub.setTrialPeriod(2, 0);

        uint fromType = _bound(fromSeed, 1, 4);   // monthly plans only, so periods match
        uint toType = _bound(toSeed, 1, 4);
        if (fromType == toType) return;
        uint elapsed = _bound(elapsedSeed, 0, PERIOD - 1);

        vm.prank(alice);
        sub.subscriptionUSDT(fromType, address(0));
        uint spentOnFirstPeriod = _paid();

        if (elapsed > 0) vm.warp(vm.getBlockTimestamp() + elapsed);
        (bool immediate, uint charged,,) = sub.previewChange(alice, toType);
        if (!immediate) return; // parked downgrade, nothing charged

        vm.prank(alice);
        sub.changeSubscription(toType);
        uint total = _paid();

        // Everything paid for this one period, versus the destination's list price.
        uint destinationFull = sub.getSubscriptionAmountUSDT(toType);
        _assert(total <= destinationFull, "upgrade path overcharged for the period");
        _assert(total == spentOnFirstPeriod + _usdtOf(charged), "charged more than previewed");
    }

    function _usdtOf(uint usd) private pure returns (uint) { return usd * 1e18 / 1e8; }

    /// Whatever the timing, the account is always left on a coherent schedule.
    function testFuzz_AnyChangeLeavesACoherentSchedule(uint elapsedSeed, uint toSeed) public {
        uint toType = _bound(toSeed, 1, 8);
        vm.prank(alice);
        sub.subscriptionUSDT(1, address(0));
        vm.warp(vm.getBlockTimestamp() + _bound(elapsedSeed, 0, PERIOD - 1));

        vm.prank(alice);
        try sub.changeSubscription(toType) {} catch { return; }

        uint active = sub.getActiveType(alice);
        _assert(active != 0, "lost the subscription");
        _assert(sub.getLockedPeriod(alice) != 0, "lost the period");
        uint next = sub.getNextChargeableAt(alice, active);
        _assert(next > vm.getBlockTimestamp(), "left already in arrears");
        uint pending = sub.getPendingType(alice);
        if (pending != 0) _assert(pending == toType && active == 1, "parked the wrong thing");
        else _assert(active == toType, "immediate change did not take effect");
    }

    /// Renewing after an arbitrary delay charges exactly one period per period elapsed.
    function testFuzz_ArrearsAreBilledPeriodByPeriod(uint delaySeed) public {
        uint delay = _bound(delaySeed, 0, 365 days);
        vm.prank(alice);
        sub.subscriptionUSDT(1, address(0));
        uint unitPrice = sub.getSubscriptionAmountUSDT(1);
        uint next = sub.nextChargeableAt(alice);
        uint paidBefore = _paid();

        vm.warp(next + delay);
        vm.prank(feeCollector);
        sub.renew(alice);

        uint expectedPeriods = delay / PERIOD + 1;
        _assert(_paid() - paidBefore == unitPrice * expectedPeriods, "arrears mispriced");
        _assert(sub.nextChargeableAt(alice) == next + expectedPeriods * PERIOD, "anchor drifted");
        _assert(sub.nextChargeableAt(alice) > vm.getBlockTimestamp(), "still due right after renewing");
    }

    // --- COAI pricing under a moving TWAP ----------------------------------

    /// COAI quotes must track the pool and stay strictly positive across the usable tick range.
    function testFuzz_CoaiQuoteTracksTheTwap(int24 tickSeed) public {
        int24 tick = int24(int(_bound(uint(int(tickSeed)) % 200000, 0, 200000)) - 100000);
        VariableTickPool(POOL).setTick(tick);

        uint quote = sub.getSubscriptionAmountCOAI(1);
        _assert(quote > 0, "zero COAI quote");
        _assert(sub.getCoaiTwapHealth(), "healthy tick reported unhealthy");

        // COAI is token0 and the pool price is token1/token0, so a higher tick means one COAI
        // buys more USDT — COAI is dearer and FEWER of them are needed for the same USD price.
        if (tick < 100000) {
            VariableTickPool(POOL).setTick(tick + 1000);
            uint dearer = sub.getSubscriptionAmountCOAI(1);
            _assert(dearer < quote, "a dearer COAI should cost fewer tokens");
            _assert(dearer > 0, "and still be quotable");
        }
    }

    /// If the oracle goes down, COAI paths fail closed and the stablecoin paths keep working.
    function test_BrokenOracleFailsClosedWithoutBlockingStablecoins() public {
        VariableTickPool(POOL).breakIt(true);
        _assert(!sub.getCoaiTwapHealth(), "broken oracle reported healthy");

        try sub.getSubscriptionAmountCOAI(1) { _assert(false, "quoted off a broken oracle"); } catch {}
        vm.prank(alice);
        try sub.subscriptionCOAI(1, address(0)) { _assert(false, "charged off a broken oracle"); } catch {}

        vm.prank(alice);
        sub.subscriptionUSDT(1, address(0));
        _assert(sub.getActiveType(alice) == 1, "USDT path still works");
    }

    /// A COAI subscriber whose oracle breaks cannot be renewed — they must not be silently
    /// charged a wrong amount, and they must still be able to leave.
    function test_CoaiSubscriberCanAlwaysCancelEvenIfTheOracleBreaks() public {
        vm.prank(alice);
        sub.subscriptionCOAI(1, address(0));
        uint next = sub.nextChargeableAt(alice);

        VariableTickPool(POOL).breakIt(true);
        vm.warp(next);
        vm.prank(feeCollector);
        try sub.renew(alice) { _assert(false, "renewed off a broken oracle"); } catch {}

        // cancelling settles the debt, which also needs the oracle => it reverts too.
        vm.prank(alice);
        try sub.cancelSubscription() { _assert(false, "settled off a broken oracle"); } catch {}

        // the terminator is the escape hatch, and it works without any pricing
        vm.prank(address(0xDEAD));
        sub.terminateSubscription(alice);
        _assert(sub.getActiveType(alice) == 0, "terminator could not clear the account");
    }

    /// However many periods are owed, renewing by hand charges exactly that many — never one
    /// extra. This is the property the on-chain double charge violated.
    function testFuzz_RenewingByHandChargesExactlyWhatIsOwed(uint lateSeed, uint planSeed) public {
        uint plan = _bound(planSeed, 1, 4);
        vm.prank(timelock);
        sub.setTrialPeriod(2, 0);                      // keep the trial out of the arithmetic

        vm.prank(alice);
        sub.subscriptionUSDT(plan, address(0));
        uint unit = sub.getSubscriptionAmountUSDT(plan);
        uint next = sub.nextChargeableAt(alice);

        uint late = _bound(lateSeed, 0, 10 * PERIOD);
        vm.warp(next + late);
        uint owed = late / PERIOD + 1;

        uint before = _paid();
        vm.prank(alice);
        sub.subscriptionUSDT(plan, address(0));

        _assert(_paid() - before == unit * owed, "charged something other than what was owed");
        _assert(sub.nextChargeableAt(alice) == next + owed * PERIOD, "anchor moved by the wrong amount");
        _assert(sub.nextChargeableAt(alice) > vm.getBlockTimestamp(), "still in arrears after renewing");
    }

    /// Renewing by hand and letting the fee collector renew must cost the same.
    function testFuzz_ManualRenewalCostsTheSameAsTheCollectors(uint lateSeed) public {
        vm.prank(timelock);
        sub.setTrialPeriod(2, 0);
        uint late = _bound(lateSeed, 0, 5 * PERIOD);

        // path A: the fee collector renews
        vm.prank(alice);
        sub.subscriptionUSDT(1, address(0));
        uint next = sub.nextChargeableAt(alice);
        uint mark = _paid();
        vm.warp(next + late);
        vm.prank(feeCollector);
        sub.renew(alice);
        uint viaCollector = _paid() - mark;
        uint anchorA = sub.nextChargeableAt(alice);

        // path B: a second account renews itself at the same point
        address bob = address(0xB0B);
        MockERC20(USDT).mint(bob, 1e30);
        vm.prank(bob);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.warp(1_000_000);
        vm.prank(bob);
        sub.subscriptionUSDT(1, address(0));
        uint nextB = sub.nextChargeableAt(bob);
        mark = _paid();
        vm.warp(nextB + late);
        vm.prank(bob);
        sub.subscriptionUSDT(1, address(0));
        uint viaSelf = _paid() - mark;

        _assert(viaSelf == viaCollector, "renewing by hand costs more than being renewed");
        _assert(sub.nextChargeableAt(bob) - nextB == anchorA - next, "anchors advanced differently");
    }
}

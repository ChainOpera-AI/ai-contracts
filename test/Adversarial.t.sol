// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";

/// A token that tries to re-enter the subscription contract from inside transferFrom.
contract ReentrantToken {
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    uint8 public constant decimals = 18;
    Subscription public target;
    uint8 public mode; // 0 = passive, 1 = re-subscribe, 2 = cancel, 3 = change
    bool entered;
    bool public reenteredSuccessfully;

    function arm(Subscription t, uint8 m) external { target = t; mode = m; entered = false; }
    function mint(address to, uint amount) external { balanceOf[to] += amount; }
    function approve(address s, uint a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function totalSupply() external pure returns (uint) { return 0; }
    function transfer(address, uint) external pure returns (bool) { return true; }

    function transferFrom(address from, address to, uint amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (mode != 0 && !entered) {
            entered = true;
            if (mode == 1) {
                try target.subscriptionUSDT(1, address(0)) { reenteredSuccessfully = true; } catch {}
            } else if (mode == 2) {
                try target.cancelSubscription() { reenteredSuccessfully = true; } catch {}
            } else {
                try target.changeSubscription(4) { reenteredSuccessfully = true; } catch {}
            }
        }
        return true;
    }
}

/// A stablecoin with six decimals, the way USDC is deployed on most chains.
contract SixDecimalToken {
    uint8 public constant decimals = 6;
    function totalSupply() external pure returns (uint) { return 0; }
    function balanceOf(address) external pure returns (uint) { return 0; }
    function transfer(address, uint) external pure returns (bool) { return true; }
    function allowance(address, address) external pure returns (uint) { return 0; }
    function approve(address, uint) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint) external pure returns (bool) { return true; }
}

contract AdversarialTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant GO_MONTH = 1;
    uint constant PLUS_MONTH = 2;
    uint constant PREMIUM_MONTH = 3;
    uint constant PRO_MONTH = 4;
    uint constant PERIOD = 30 days;
    uint constant USD = 1e8;

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

    // --- reentrancy ---------------------------------------------------------

    /// slither flags _activate as reentrancy-eth because _settleIfDebt transfers before state is
    /// written. Drive it with a token that actually re-enters and confirm nonReentrant holds.
    function test_ReentrancyFromTheTokenIsBlocked() public {
        ReentrantToken evil = new ReentrantToken();
        vm.etch(USDT, address(evil).code);
        ReentrantToken t = ReentrantToken(USDT);
        t.mint(alice, 1_000_000e18);

        for (uint8 mode = 1; mode <= 3; mode++) {
            t.arm(sub, mode);
            vm.prank(alice);
            try sub.subscriptionUSDT(GO_MONTH, address(0)) {} catch {}
            _assert(!t.reenteredSuccessfully(), "re-entered through the pay token");
        }
    }

    // --- arithmetic edges ---------------------------------------------------

    /// With one second left the pro-rata difference truncates toward zero. Check what that buys:
    /// it must never let an account move to a MORE expensive plan without paying.
    function test_TruncationAtOneSecondLeftCannotYieldAFreeUpgrade() public {
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0));
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next - 1); // one second of the period left

        (bool immediate, uint charged,,) = sub.previewChange(alice, PRO_MONTH);
        if (immediate) {
            _assert(charged > 0, "an immediate move to a dearer plan must charge something");
        } else {
            // parked: the account keeps the CHEAPER plan until period end, so nothing is stolen
            _assert(sub.getActiveType(alice) == GO_MONTH, "still on the cheap plan");
        }
    }

    /// Two plans one cent apart, one second left: delta truncates to 0 and is treated as a
    /// downgrade. Confirm that path parks the change rather than switching for free.
    function test_SubCentDifferenceParksInsteadOfSwitchingFree() public {
        // One cent above whatever GO currently costs, so this holds when prices change. Read it
        // before the prank: that read is itself an external call and would consume the prank.
        uint target = sub.getSubscriptionPrice(GO_MONTH) + 1000000;
        vm.prank(timelock);
        sub.setSubscriptionPrice(PREMIUM_MONTH, target);
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0));
        uint next = sub.nextChargeableAt(alice);
        vm.warp(next - 1);
        uint paid = _rcv();

        (bool immediate, uint charged,,) = sub.previewChange(alice, PREMIUM_MONTH);
        _assert(!immediate && charged == 0, "truncates to zero => treated as a downgrade");
        vm.prank(alice);
        sub.changeSubscription(PREMIUM_MONTH);
        _assert(_rcv() == paid, "no money moved");
        _assert(sub.getActiveType(alice) == GO_MONTH, "NOT switched early");
        _assert(sub.getPendingType(alice) == PREMIUM_MONTH, "parked to period end instead");
    }

    /// A very large configured price must not wrap when cast to int for the delta maths.
    function test_HugePriceDoesNotWrapTheDeltaSign() public {
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0));
        vm.warp(block.timestamp + 10 days);

        // 1e30 USD*1e8 — absurd, but reachable by a fat-fingered setSubscriptionPrice
        vm.prank(timelock);
        sub.setSubscriptionPrice(PRO_MONTH, 1e30);
        (bool immediate, uint charged,,) = sub.previewChange(alice, PRO_MONTH);
        _assert(immediate, "a dearer plan is still an upgrade");
        _assert(charged > 1e29, "and the amount did not wrap to something small");
    }

    // --- state machine dead ends -------------------------------------------

    /// An account with a parked change must always have a way out.
    function test_ParkedChangeNeverTrapsTheAccount() public {
        vm.prank(alice);
        sub.subscriptionUSDT(PRO_MONTH, address(0));
        vm.prank(alice);
        sub.changeSubscription(GO_MONTH); // parked
        _assert(sub.getPendingType(alice) == GO_MONTH, "parked");

        // subscribing is refused...
        vm.prank(alice);
        try sub.subscriptionUSDT(PRO_MONTH, address(0)) { _assert(false, "should be refused"); } catch {}
        // ...but cancelling always works
        vm.prank(alice);
        sub.cancelSubscription();
        _assert(sub.isCancelled(alice), "can always cancel out");
        _assert(sub.getPendingType(alice) == 0, "and the parked change is dropped");
    }

    /// Delisting the destination after a change was parked must not brick the renewal.
    function test_DelistingAParkedDestinationStillLands() public {
        vm.prank(alice);
        sub.subscriptionUSDT(PRO_MONTH, address(0));
        uint next = sub.nextChargeableAt(alice);
        vm.prank(alice);
        sub.changeSubscription(GO_MONTH);

        vm.prank(timelock);
        sub.delistSubscription(GO_MONTH);

        vm.warp(next);
        vm.prank(feeCollector);
        sub.renew(alice); // must not revert
        _assert(sub.getActiveType(alice) == GO_MONTH, "landed despite the delist");
    }

    /// terminateSubscription must leave no residue that could confuse a later subscribe.
    function test_TerminateLeavesACleanSlateExceptTrialEligibility() public {
        vm.prank(alice);
        sub.subscriptionUSDT(PLUS_MONTH, address(0)); // starts the 3-day trial
        _assert(sub.isInTrial(alice), "on trial");

        vm.prank(address(0xDEAD));
        sub.terminateSubscription(alice);
        _assert(sub.getActiveType(alice) == 0, "type cleared");
        _assert(sub.getPendingType(alice) == 0, "pending cleared");
        _assert(sub.getLockedPeriod(alice) == 0, "period cleared");
        _assert(!sub.isInTrial(alice), "trial cleared");
        _assert(sub.hasEverSubscribed(alice), "but eligibility stays burnt");
        _assert(!sub.startsTrial(alice, PLUS_MONTH), "no fresh trial after a terminate");

        // and a fresh paid subscribe works normally
        uint paid = _rcv();
        vm.prank(alice);
        sub.subscriptionUSDT(PLUS_MONTH, address(0));
        _assert(_rcv() > paid, "charged this time");
    }

    // --- fee collector surface ---------------------------------------------

    /// renewSelf is external; make sure nobody but the contract can drive it.
    function test_RenewSelfIsUnreachableFromOutside() public {
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0));
        vm.warp(block.timestamp + PERIOD);

        vm.prank(feeCollector);
        try sub.renewSelf(alice) { _assert(false, "fee collector must not reach it"); } catch {}
        vm.prank(alice);
        try sub.renewSelf(alice) { _assert(false, "nor anyone else"); } catch {}
        _assert(_rcv() == MockERC20(USDT).balanceOf(receiver), "no charge happened");
    }

    /// toCoaiAmount reads the pool's other side as an 18-decimal USD stablecoin. A pool quoted
    /// in a six-decimal token would misprice COAI by twelve orders of magnitude, and nothing
    /// downstream could detect it — so the pool has to be refused when it is set.
    function test_CoaiPoolQuotedInASixDecimalTokenIsRefused() public {
        SixDecimalToken six = new SixDecimalToken();
        address badPool = address(0xBADF00D);
        vm.etch(badPool, type(MockPool).runtimeCode);
        MockPool(badPool).setTokens(COAI, address(six));

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature(
            "QuoteTokenNotEighteenDecimals(address,uint8)", address(six), uint8(6)));
        sub.setCOAIPriceFeedAddress(badPool);

        // the good pool is still accepted
        vm.prank(timelock);
        sub.setCOAIPriceFeedAddress(POOL);
        _assert(sub.getCOAIPriceFeedAddress() == POOL, "an 18-decimal quote is fine");
    }

    /// A pool that does not contain COAI at all is refused before the decimals check.
    function test_CoaiPoolWithoutCoaiIsRefused() public {
        address badPool = address(0xBADBEEF);
        vm.etch(badPool, type(MockPool).runtimeCode);
        MockPool(badPool).setTokens(USDT, USDC);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature("CoaiNotInPool()"));
        sub.setCOAIPriceFeedAddress(badPool);
    }

    /// terminateSubscription must not leave an anchor behind that would put a returning
    /// account straight back into arrears.
    function test_TerminateLeavesNoAnchorToTripOverLater() public {
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0));
        vm.warp(block.timestamp + 10 days);
        vm.prank(address(0xDEAD));
        sub.terminateSubscription(alice);
        _assert(sub.getNextChargeableAt(alice, GO_MONTH) == 0, "anchor cleared");

        // coming back to the same plan starts a clean period from now, not from a stale anchor
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0));
        _assert(sub.nextChargeableAt(alice) == block.timestamp + PERIOD, "fresh period");
        _assert(sub.nextChargeableAt(alice) > block.timestamp, "not born in arrears");

        // and the same holds after bouncing through a second plan
        vm.prank(address(0xDEAD));
        sub.terminateSubscription(alice);
        vm.prank(alice);
        sub.subscriptionUSDT(PRO_MONTH, address(0));
        vm.warp(block.timestamp + 5 days);
        vm.prank(address(0xDEAD));
        sub.terminateSubscription(alice);
        _assert(sub.getNextChargeableAt(alice, PRO_MONTH) == 0, "second plan cleared too");
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0));
        _assert(sub.nextChargeableAt(alice) == block.timestamp + PERIOD, "still clean");
    }
}

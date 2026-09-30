// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";
import "./deploy.sol";

/// How many accounts one renewBatch can actually carry, and what a failure costs.
contract BatchCapacityTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    Subscription sub;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);
        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = deploySubscription(receiver, feeCollector, address(0xDEAD), 0, roles, roles, address(0));
        vm.warp(1_000_000);
    }

    function _assert(bool ok, string memory what) private pure { require(ok, what); }

    function _enroll(uint n, uint fundEvery) private returns (address[] memory) {
        address[] memory list = new address[](n);
        for (uint i = 0; i < n; i++) {
            address a = address(uint160(0x10000 + i));
            list[i] = a;
            MockERC20(USDT).mint(a, 1_000_000e18);
            vm.prank(a);
            MockERC20(USDT).approve(address(sub), type(uint).max);
            vm.prank(a);
            sub.subscriptionUSDT(1, address(0));
            // starve every Nth account so it fails on renew
            if (fundEvery != 0 && i % fundEvery == 0) {
                vm.prank(a);
                MockERC20(USDT).approve(address(sub), 0);
            }
        }
        vm.warp(vm.getBlockTimestamp() + 30 days);
        return list;
    }

    function _measure(uint n) private {
        address[] memory list = _enroll(n, 0);
        uint before = gasleft();
        vm.prank(feeCollector);
        sub.renewBatch(list);
        uint used = before - gasleft();
        emit log_named_uint("accounts", n);
        emit log_named_uint("gas used", used);
        emit log_named_uint("gas per account", used / n);
    }

    function test_BatchGas_10() public { _measure(10); }
    function test_BatchGas_50() public { _measure(50); }
    function test_BatchGas_200() public { _measure(200); }

    /// A batch where every fourth account cannot pay must still charge the rest.
    function test_FailuresDoNotStopTheRest() public {
        address[] memory list = _enroll(20, 4);
        uint paidBefore = MockERC20(USDT).balanceOf(receiver);
        vm.prank(feeCollector);
        sub.renewBatch(list);
        uint unit = sub.getSubscriptionAmountUSDT(1);
        uint charged = (MockERC20(USDT).balanceOf(receiver) - paidBefore) / unit;
        _assert(charged == 15, "the 15 solvent accounts were charged");

        // failures left untouched and retryable
        for (uint i = 0; i < 20; i += 4) {
            _assert(sub.nextChargeableAt(list[i]) == 1_000_000 + 30 days, "failed account untouched");
        }
    }

    event log_named_uint(string key, uint val);
}

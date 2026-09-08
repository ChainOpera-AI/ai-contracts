// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/top_up_collector.sol";
import "./mocks.sol";

contract TopUpTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant TEN_USD = 1000000000;        // $10 at USD*1e8
    uint constant TEN_IN_TOKEN = 10e18;        // $10 in an 18-dec stable
    uint constant SEVEN_IN_COAI = 7e18;        // $10 * 0.7 discount, at 1 COAI = $1

    TopUp t;
    address timelock;
    address receiver = address(0xBEEF);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);

        address[] memory roles = new address[](1);
        roles[0] = address(this);
        t = new TopUp(receiver, 0, roles, roles, address(0));
        timelock = t.getOwner();

        address[3] memory toks = [USDT, COAI, USDC];
        for (uint i = 0; i < 3; i++) {
            MockERC20(toks[i]).mint(alice, 1_000_000e18);
            vm.prank(alice);
            MockERC20(toks[i]).approve(address(t), type(uint).max);
        }
    }

    function _bal(address tok, address who) private view returns (uint) { return MockERC20(tok).balanceOf(who); }
    function _assert(bool ok, string memory what) private pure { require(ok, what); }

    function test_TopUpUSDTChargesTenDollars() public {
        _assert(t.getTopUpAmountUSDT() == TEN_IN_TOKEN, "quote is $10");
        vm.prank(alice);
        t.topUpUSDT();
        _assert(_bal(USDT, receiver) == TEN_IN_TOKEN, "receiver got $10");
        _assert(_bal(USDT, alice) == 1_000_000e18 - TEN_IN_TOKEN, "alice paid $10");
        _assert(t.getTotalToppedUp(alice) == TEN_USD, "credit recorded");
    }

    function test_TopUpUSDCChargesTenDollars() public {
        vm.prank(alice);
        t.topUpUSDC();
        _assert(_bal(USDC, receiver) == TEN_IN_TOKEN, "receiver got $10 in USDC");
    }

    function test_TopUpCOAIAppliesTheDiscount() public {
        _assert(t.getDiscount(2) == 700, "COAI is 30% off by default");
        _assert(t.getTopUpAmountCOAI() == SEVEN_IN_COAI, "quote is $7 worth of COAI");
        vm.prank(alice);
        t.topUpCOAI();
        _assert(_bal(COAI, receiver) == SEVEN_IN_COAI, "receiver got the discounted COAI");
        _assert(t.getTotalToppedUp(alice) == TEN_USD, "still credits the full $10 face value");
    }

    function test_TopUpsAccumulate() public {
        for (uint i = 0; i < 3; i++) { vm.prank(alice); t.topUpUSDT(); }
        _assert(_bal(USDT, receiver) == 3 * TEN_IN_TOKEN, "three payments");
        _assert(t.getTotalToppedUp(alice) == 3 * TEN_USD, "three credits");
    }

    function test_OwnerCanChangeAmountAndReceiver() public {
        vm.prank(timelock);
        t.setTopUpAmount(2500000000); // $25
        address newReceiver = address(0xCAFE);
        vm.prank(timelock);
        t.setReceiver(newReceiver);

        vm.prank(alice);
        t.topUpUSDT();
        _assert(_bal(USDT, newReceiver) == 25e18, "new receiver got $25");
        _assert(_bal(USDT, receiver) == 0, "old receiver got nothing");
        _assert(t.getTotalToppedUp(alice) == 2500000000, "credit follows the new amount");
    }

    function test_ZeroAmountRejected() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature("InvalidTopUpAmount()"));
        t.setTopUpAmount(0);
    }

    function test_OnlyOwnerCanConfigure() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, alice));
        t.setTopUpAmount(1);
    }

    function test_SwitchOffBlocksTopUps() public {
        vm.prank(timelock);
        t.setSwitch(false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("SwitchOff()"));
        t.topUpUSDT();
    }

    function test_ContractNeverHoldsFunds() public {
        vm.prank(alice);
        t.topUpUSDT();
        vm.prank(alice);
        t.topUpCOAI();
        _assert(_bal(USDT, address(t)) == 0, "no USDT stuck");
        _assert(_bal(COAI, address(t)) == 0, "no COAI stuck");
    }

    function test_ReceiverCannotBeTheContract() public {
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature("InvalidReceiver()"));
        t.setReceiver(address(t));
    }
}

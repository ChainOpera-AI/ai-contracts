// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "../contracts/subscription_fee_collector.sol";
import "./mocks.sol";
import "./deploy.sol";

/// A second version, to prove an upgrade keeps every storage slot and can add behaviour.
contract SubscriptionV2 is Subscription {
    function versionTag() external pure returns (string memory) { return "v2"; }
}

/// Something that is NOT a Subscription, to prove the proxy refuses an unauthorised upgrade.
contract Impostor {
    function stealEverything() external pure returns (bool) { return true; }
}

contract UpgradeTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;

    uint constant GO_MONTH = 1;
    uint constant PLUS_MONTH = 2;
    uint constant PERIOD = 30 days;

    Subscription sub;
    address timelock;
    address receiver = address(0xBEEF);
    address feeCollector = address(0xFEE);
    address terminator = address(0xDEAD);
    address alice = address(0xA11CE);
    address mallory = address(0xBAD);
    address importer = address(0x114807);

    function setUp() public {
        vm.etch(USDT, type(MockERC20).runtimeCode);
        vm.etch(USDC, type(MockERC20).runtimeCode);
        vm.etch(COAI, type(MockERC20).runtimeCode);
        vm.etch(POOL, type(MockPool).runtimeCode);
        MockPool(POOL).setTokens(COAI, USDT);
        address[] memory roles = new address[](1);
        roles[0] = address(this);
        sub = deploySubscription(receiver, feeCollector, terminator, 0, roles, roles, address(0));
        timelock = sub.getOwner();
        MockERC20(USDT).mint(alice, 1_000_000e18);
        vm.prank(alice);
        MockERC20(USDT).approve(address(sub), type(uint).max);
        vm.warp(1_000_000);
        vm.prank(timelock);
        sub.setImporter(importer);
    }

    function _assert(bool ok, string memory what) private pure { require(ok, what); }

    // --- the proxy itself ---------------------------------------------------

    function test_ProxyIsInitialisedAndCannotBeInitialisedAgain() public {
        _assert(sub.getReceiver() == receiver, "initialised through the proxy");
        _assert(sub.getOwner() != address(0), "timelock deployed during initialize");

        vm.prank(mallory);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        sub.initialize(mallory, mallory, mallory, mallory);
    }

    /// The implementation must be inert on its own, or someone could initialize it directly
    /// and then drive an upgrade through _authorizeUpgrade on that instance.
    function test_ImplementationCannotBeInitialised() public {
        Subscription impl = new Subscription();
        vm.prank(mallory);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        impl.initialize(mallory, mallory, mallory, mallory);
    }

    // --- upgrading ----------------------------------------------------------

    /// State written before an upgrade must read back identically after it.
    function test_UpgradePreservesEveryAccountField() public {
        vm.prank(alice);
        sub.subscriptionUSDT(GO_MONTH, address(0xAAA1));
        uint next = sub.nextChargeableAt(alice);
        uint32 period = sub.getLockedPeriod(alice);
        uint8 payToken = sub.getActivePayToken(alice);

        SubscriptionV2 v2 = new SubscriptionV2();
        vm.prank(timelock);
        sub.upgradeTo(address(v2));

        _assert(sub.getImplementation() == address(v2), "implementation swapped");
        _assert(keccak256(bytes(SubscriptionV2(address(sub)).versionTag())) == keccak256("v2"), "new behaviour is live");
        _assert(sub.getActiveType(alice) == GO_MONTH, "active type survived");
        _assert(sub.nextChargeableAt(alice) == next, "anchor survived");
        _assert(sub.getLockedPeriod(alice) == period, "locked period survived");
        _assert(sub.getActivePayToken(alice) == payToken, "pay token survived");
        _assert(sub.getInviter(alice) == address(0xAAA1), "inviter survived");
        _assert(sub.hasEverSubscribed(alice), "trial eligibility survived");
        _assert(sub.getSubscriptionPrice(1) == 499000000, "price table survived");
        _assert(sub.getReceiver() == receiver, "receiver survived");

        // and billing carries on from where it left off
        vm.warp(next);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(sub.nextChargeableAt(alice) == next + PERIOD, "renewal still works after upgrade");
    }

    function test_OnlyOwnerCanUpgrade() public {
        SubscriptionV2 v2 = new SubscriptionV2();
        address impl = sub.getImplementation();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, mallory));
        sub.upgradeTo(address(v2));

        vm.prank(feeCollector);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, feeCollector));
        sub.upgradeTo(address(v2));

        _assert(sub.getImplementation() == impl, "implementation untouched");
    }

    /// UUPS refuses an implementation that is not itself upgradeable, which is what stops a
    /// bricking upgrade to an arbitrary contract.
    function test_UpgradeToANonUupsContractIsRefused() public {
        Impostor bad = new Impostor();
        vm.prank(timelock);
        try sub.upgradeTo(address(bad)) { _assert(false, "proxy accepted a non-UUPS implementation"); } catch {}
        _assert(sub.getReceiver() == receiver, "still the real contract");
    }

    // --- importing from an older deployment ---------------------------------

    function test_ImportedAccountBehavesLikeANativeOne() public {
        Subscription.ImportedAccount[] memory rows = new Subscription.ImportedAccount[](1);
        rows[0] = Subscription.ImportedAccount({
            account: alice,
            subscriptionType: PLUS_MONTH,
            payToken: 1,
            lockedPeriod: uint32(PERIOD),
            nextChargeableAt: vm.getBlockTimestamp() + 10 days,
            pendingType: 0,
            trialEndsAt: 0,
            cancelled: false,
            everSubscribed: true,
            inviter: address(0xAAA1)
        });
        vm.prank(importer);
        sub.importAccounts(rows);

        _assert(sub.getActiveType(alice) == PLUS_MONTH, "type imported");
        _assert(sub.getEffectiveType(alice) == PLUS_MONTH, "entitled");
        _assert(sub.getLockedPeriod(alice) == PERIOD, "period imported");
        _assert(sub.getInviter(alice) == address(0xAAA1), "inviter imported");
        _assert(!sub.startsTrial(alice, PLUS_MONTH), "eligibility imported as spent");

        // the fee collector can renew it, and it charges the right plan
        uint before = MockERC20(USDT).balanceOf(receiver);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(feeCollector);
        sub.renew(alice);
        _assert(MockERC20(USDT).balanceOf(receiver) - before == 1999000000 * 1e18 / 1e8, "renewed at PLUS");

        // and the account can cancel, which is the full lifecycle working off imported state
        vm.prank(alice);
        sub.cancelSubscription();
        _assert(sub.isCancelled(alice), "cancellable");
    }

    function test_ImportSkipsBlankRowsAndRejectsAZeroPeriod() public {
        Subscription.ImportedAccount[] memory rows = new Subscription.ImportedAccount[](2);
        // a gap in the batch, skipped rather than written
        rows[0].account = mallory;
        rows[0].subscriptionType = 0;
        rows[1] = Subscription.ImportedAccount({
            account: alice, subscriptionType: GO_MONTH, payToken: 1, lockedPeriod: uint32(PERIOD),
            nextChargeableAt: vm.getBlockTimestamp() + 1 days, pendingType: 0, trialEndsAt: 0,
            cancelled: false, everSubscribed: true, inviter: address(0)
        });
        vm.prank(importer);
        sub.importAccounts(rows);
        _assert(sub.getActiveType(mallory) == 0, "blank row skipped");
        _assert(sub.getActiveType(alice) == GO_MONTH, "real row written");

        // a period of zero would brick renew/settle for that account, so it is refused
        Subscription.ImportedAccount[] memory bad = new Subscription.ImportedAccount[](1);
        bad[0] = rows[1];
        bad[0].account = mallory;
        bad[0].lockedPeriod = 0;
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("UnknownPeriod()"));
        sub.importAccounts(bad);
    }

    function _oneRow() private view returns (Subscription.ImportedAccount[] memory rows) {
        rows = new Subscription.ImportedAccount[](1);
        rows[0] = Subscription.ImportedAccount({
            account: alice, subscriptionType: GO_MONTH, payToken: 1, lockedPeriod: uint32(PERIOD),
            nextChargeableAt: vm.getBlockTimestamp() + 1 days, pendingType: 0, trialEndsAt: 0,
            cancelled: false, everSubscribed: true, inviter: address(0)
        });
    }

    function test_OnlyTheNamedImporterCanImport() public {
        Subscription.ImportedAccount[] memory rows = _oneRow();

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotImporter(address,address)", importer, mallory));
        sub.importAccounts(rows);

        // the owner names the importer but is not one itself, so importing is a separate power
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSignature("NotImporter(address,address)", importer, timelock));
        sub.importAccounts(rows);

        _assert(sub.getActiveType(alice) == 0, "nothing written");
    }

    function test_OwnerCanRotateAndRevokeTheImporter() public {
        _assert(sub.getImporter() == importer, "named in setUp");

        address successor = address(0x50CC);
        vm.prank(timelock);
        sub.setImporter(successor);
        _assert(sub.getImporter() == successor, "rotated");

        Subscription.ImportedAccount[] memory rows = _oneRow();
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("NotImporter(address,address)", successor, importer));
        sub.importAccounts(rows);

        vm.prank(successor);
        sub.importAccounts(rows);
        _assert(sub.getActiveType(alice) == GO_MONTH, "successor can import");

        // zero parks the role: imports stop, but closeImport has not been spent
        vm.prank(timelock);
        sub.setImporter(address(0));
        vm.prank(successor);
        vm.expectRevert(abi.encodeWithSignature("NotImporter(address,address)", address(0), successor));
        sub.importAccounts(rows);
        _assert(!sub.isImportClosed(), "parked, not closed");
    }

    function test_OnlyOwnerCanNameTheImporter() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSignature("NotOwner(address,address)", timelock, mallory));
        sub.setImporter(mallory);
        _assert(sub.getImporter() == importer, "unchanged");
    }

    function test_CloseImportIsPermanent() public {
        _assert(!sub.isImportClosed(), "open to begin with");
        vm.prank(timelock);
        sub.closeImport();
        _assert(sub.isImportClosed(), "closed");

        Subscription.ImportedAccount[] memory rows = new Subscription.ImportedAccount[](1);
        rows[0] = Subscription.ImportedAccount({
            account: alice, subscriptionType: GO_MONTH, payToken: 1, lockedPeriod: uint32(PERIOD),
            nextChargeableAt: vm.getBlockTimestamp() + 1 days, pendingType: 0, trialEndsAt: 0,
            cancelled: false, everSubscribed: true, inviter: address(0)
        });
        vm.prank(importer);
        vm.expectRevert(abi.encodeWithSignature("ImportAlreadyClosed()"));
        sub.importAccounts(rows);
    }
}

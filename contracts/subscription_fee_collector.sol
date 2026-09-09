// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "./lib/IPancakeV3PoolState.sol";
import "./lib/CoaiTwapPricing.sol";
import "./lib/UsdPricing.sol";

contract Subscription is ReentrancyGuard {
    using SafeERC20 for ERC20;
    error SwitchOff();
    error InvalidTwapInterval();
    error UnsupportedDecimals();
    error InvalidSubscriptionType(uint subscriptionType);
    error InvalidDiscount();
    error NotFeeCollector(address feeCollector, address caller);
    error NotSelf(address caller);
    error NotSubscriptionTerminator(address subscriptionTerminator, address caller);
    error NotDueYet(uint nextChargeableAt);
    error NotSubscribed();
    error AlreadyCancelled();
    error NotCancelled();
    error SubscriptionExpired(uint expiredAt);
    error MustCancelFirst(uint activeSubscriptionType);
    error SettleDebtFirst(uint dueAt);
    error NoScheduledChange();
    error SameSubscriptionType();
    error PendingChangeExists(uint pendingSubscriptionType);
    error UnknownPeriod();
    error UnknownPayToken(uint8 payToken);
    error NoDebt();
    error NotOwner(
        address owner,
        address caller
    );
    error NotPendingOwner(
        address pendingOwner,
        address caller
    );
    error ZeroAddress();
    error InvalidReceiver();
    error InvalidTimelockConfig();
    error NotListed(uint subscriptionType);
    error AlreadyListed(uint subscriptionType);
    error InvalidInviter();

    event SubscribedUSDT(
        address indexed account,
        uint indexed subscriptionType,
        address indexed inviter,
        uint amount,
        uint requiredUSDTAmount
    );
    event SubscribedCOAI(
        address indexed account,
        uint indexed subscriptionType,
        address indexed inviter,
        uint amount,
        uint requiredCOAIAmount
    );
    event SubscribedUSDC(
        address indexed account,
        uint indexed subscriptionType,
        address indexed inviter,
        uint amount,
        uint requiredUSDCAmount
    );
    event USDTAddressChanged(
        address indexed new_usdtAddress,
        uint8 usdtDecimals
    );
    event COAIAddressChanged(
        address indexed new_coaiAddress,
        uint8 coaiDecimals
    );
    event USDCAddressChanged(
        address indexed new_usdcAddress,
        uint8 usdcDecimals
    );
    event COAIPriceFeedAddressChanged(
        address indexed new_coaiPriceFeedAddress
    );
    event TwapIntervalChanged(
        uint32 new_twapInterval
    );
    event SwitchChanged(
        bool new_switch
    );
    event ReceiverChanged(
        address indexed new_receiver
    );
    event PendingOwnerChanged(
        address indexed new_pendingOwner
    );
    event OwnerChanged(
        address indexed previous_owner,
        address indexed new_owner
    );
    event SubscriptionPriceChanged(
        uint indexed subscriptionType,
        uint new_price
    );
    event DiscountChanged(
        uint8 indexed payToken,
        uint new_discount
    );
    event FeeCollectorChanged(
        address indexed new_feeCollector
    );
    event SubscriptionTerminatorChanged(
        address indexed new_subscriptionTerminator
    );
    event SubscriptionTerminated(
        address indexed account,
        uint indexed subscriptionType,
        address indexed terminator,
        uint terminatedAt
    );
    event SubscriptionPeriodChanged(
        uint indexed subscriptionType,
        uint32 new_periodSeconds
    );
    event SubscriptionListed(
        uint indexed subscriptionType
    );
    event SubscriptionDelisted(
        uint indexed subscriptionType
    );
    /// @dev Only emitted on the cancel -> period elapsed -> subscribe-to-another-type path,
    /// which is now the only way to change plan. Never emitted for a live switch.
    event SubscriptionSwitched(
        address indexed account,
        uint indexed previous_subscriptionType,
        uint indexed new_subscriptionType
    );
    event SubscriptionCancelled(
        address indexed account,
        uint indexed subscriptionType,
        uint cancelledAt
    );
    event SubscriptionRestored(
        address indexed account,
        uint indexed subscriptionType,
        uint restoredAt
    );
    /// @dev A change that cost money and took effect immediately. `chargedAmount` is the USD
    /// pro-rata top-up, `requiredTokenAmount` what was actually transferred.
    event SubscriptionUpgraded(
        address indexed account,
        uint indexed previous_subscriptionType,
        uint indexed new_subscriptionType,
        uint8 payToken,
        uint chargedAmount,
        uint requiredTokenAmount,
        uint nextChargeableAt
    );
    /// @dev A change worth nothing or less was parked until the paid-up period runs out. No
    /// money moves here; SubscriptionDowngraded fires later when it actually lands.
    event DowngradeScheduled(
        address indexed account,
        uint indexed current_subscriptionType,
        uint indexed new_subscriptionType,
        uint effectiveAt
    );
    event ScheduledChangeCancelled(
        address indexed account,
        uint indexed cancelled_subscriptionType
    );
    event SubscriptionDowngraded(
        address indexed account,
        uint indexed previous_subscriptionType,
        uint indexed new_subscriptionType,
        uint downgradedAt
    );
    /// @dev Plan swapped mid-trial for one that carries no trial of its own. The trial belonged
    /// to the plan being left, so it ends there and then and the account is charged a full
    /// period of the new plan up front.
    event TrialEndedByChange(
        address indexed account,
        uint indexed previous_subscriptionType,
        uint indexed new_subscriptionType,
        uint8 payToken,
        uint chargedAmount,
        uint requiredTokenAmount,
        uint nextChargeableAt
    );
    /// @dev Emitted instead of SubscribedUSDT/COAI/USDC when a subscribe starts a free trial:
    /// nothing is transferred, so no SubscribedXXX is emitted and revenue accounting stays clean.
    /// The first real charge lands at `trialEndsAt` via the fee collector's renew.
    event TrialStarted(
        address indexed account,
        uint indexed subscriptionType,
        address indexed inviter,
        uint8 payToken,
        uint trialEndsAt
    );
    event TrialPeriodChanged(
        uint indexed subscriptionType,
        uint32 new_trialSeconds
    );
    event DebtSettled(
        address indexed account,
        uint indexed subscriptionType,
        uint8 indexed payToken,
        uint price,
        uint requiredTokenAmount,
        uint periodsCharged,
        uint settledAt
    );
    event Renewed(
        address indexed account,
        uint indexed subscriptionType,
        uint8 indexed payToken, // 1 = USDT, 2 = COAI, 3 = USDC
        uint price,
        uint requiredTokenAmount,
        uint periodsCharged,
        uint chargedAt
    );
    /// @dev Emitted by renewBatch only when at least one account failed to be charged.
    /// `failedAccounts` holds exactly the accounts whose _renew reverted (insufficient
    /// balance/approval, not due yet, unknown pay token, unhealthy price feed, ...); every
    /// other account in the batch was charged normally. Individual revert reasons are not
    /// captured — re-run renew(account) on a single address to surface the exact error.
    event RenewBatchFailed(
        address indexed caller,
        uint failedCount,
        address[] failedAccounts
    );

    ERC20 private _usdt;
    uint8 private _usdtDecimals;
    ERC20 private _coai;
    uint8 private _coaiDecimals;
    ERC20 private _usdc;
    uint8 private _usdcDecimals;
    IPancakeV3PoolState private _coaiPriceFeed;
    bool private _coaiIsToken0;
    uint32 private _twapInterval;
    address private _owner;
    address private _pendingOwner;
    address private _receiver;
    bool private _switch;
    // subscriptionType => price in USD * 10^USD_DECIMALS (0 = inactive/undefined)
    mapping(uint => uint) private _subscriptionPrices;
    // payToken => discount numerator, denominator = DISCOUNT_BASE. e.g. 700 / 1000 = 30% off
    mapping(uint8 => uint) private _discounts;
    address private _feeCollector;
    // Privileged role that can force-cancel any subscription, ignoring debt. Intended as an
    // escape hatch for accounts that have become unable to pay and would otherwise accrue
    // unsettleable debt forever.
    address private _subscriptionTerminator;
    // subscriptionType => recurring period in seconds (0 = non-recurring/undefined)
    mapping(uint => uint32) private _subscriptionPeriods;
    // subscriptionType => listed (true => accepting new subscriptions). Delisting only blocks new
    // subscribeXXX entries; existing subscribers can still renew, settle, and cancel.
    mapping(uint => bool) private _subscriptionListed;
    // user => subscriptionType => next chargeable timestamp (0 = never subscribed; advanced by period on each charge, anchored to initial subscribe)
    mapping(address => mapping(uint => uint)) private _nextChargeableAt;
    // user => currently active subscriptionType (0 = none). Only one active subscription per user.
    mapping(address => uint) private _activeType;
    // user => payToken used at last subscribe (PAY_TOKEN_USDT / _COAI / _USDC). Determines renew currency.
    mapping(address => uint8) private _activePayToken;
    // user => the billing period, in seconds, snapshotted when they subscribed. Every charge is
    // sliced with THIS value, never with the plan's live _subscriptionPeriods. Two reasons:
    // the account keeps the cadence it agreed to, and — more importantly — a mid-flight
    // setSubscriptionPeriod can never retroactively re-slice arrears that accrued under the old
    // period (shortening the period would otherwise multiply an outstanding debt).
    mapping(address => uint32) private _lockedPeriod;
    // user => cancelled flag. Cancelling does NOT tear the subscription down: the account keeps
    // _activeType / _activePayToken / _nextChargeableAt and coasts on the period it already paid
    // for, while renewals stop. Inside that window restoreSubscription() clears the flag and the
    // subscription resumes untouched; once _nextChargeableAt elapses the subscription is over for
    // good and only a fresh subscribeXXX brings it back. The stale _activeType is deliberately
    // left behind — getEffectiveType() is what reports real entitlement.
    mapping(address => bool) private _cancelled;
    // subscriptionType => free trial length in seconds (0 = no trial, charge on subscribe).
    // Set per type by the owner, so any plan can be given a trial — or have it withdrawn —
    // at any time without touching code.
    mapping(uint => uint32) private _trialPeriods;
    // user => has ever held a subscription. The free trial is strictly a first-subscription
    // offer: once an account has subscribed to anything — trial or paid — it can never trial
    // again, on any plan. That makes this one flag the whole eligibility rule, and it is why
    // changing plans can never open a trial (the account has subscribed by definition).
    // Deliberately NOT cleared by terminateSubscription: being force-cancelled does not earn
    // a fresh trial.
    mapping(address => bool) private _everSubscribed;
    // user => the single pending end-of-period change, if any (0 = none). Holds the plan to
    // move to when the paid-up period runs out. Mutually exclusive with _cancelled: both mean
    // "something happens at the end of this period" and an account only ever has one such slot.
    mapping(address => uint) private _pendingType;
    // user => moment their free trial ends (0 = never had one). Only used to answer "is this
    // account mid-trial right now", which decides whether a plan change is free. Never needs
    // clearing: it simply falls into the past, and a plan change does not move it.
    mapping(address => uint) private _trialEndsAt;
    // user => inviter (referrer) address. Required (non-zero) on every subscribeXXX call;
    // each successful subscribe overwrites the stored value, so users can switch their referrer
    // on a later call. Subscribers cannot invite themselves. Persists across cancel/terminate.
    mapping(address => address) private _inviters;

    // subscriptionType id constants. Tier order (low → high): GO < PLUS < PREMIUM < PRO.
    // IDs 1-4 are monthly plans in tier order, 5-8 are yearly plans in tier order.
    uint constant SUB_TYPE_GO_MONTH      = 1;
    uint constant SUB_TYPE_PLUS_MONTH    = 2;
    uint constant SUB_TYPE_PREMIUM_MONTH = 3;
    uint constant SUB_TYPE_PRO_MONTH     = 4;
    uint constant SUB_TYPE_GO_YEAR       = 5;
    uint constant SUB_TYPE_PLUS_YEAR     = 6;
    uint constant SUB_TYPE_PREMIUM_YEAR  = 7;
    uint constant SUB_TYPE_PRO_YEAR      = 8;

    // Prices in USD * 10^USD_DECIMALS (USD * 1e8).
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_GO_MONTH      = 500000000;       // $5
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_MONTH    = 1999000000;      // $19.99
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PREMIUM_MONTH = 10000000000;     // $100
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PRO_MONTH     = 20000000000;     // $200
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_GO_YEAR       = 4800000000;      // $48 = $4 * 12
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_YEAR     = 19188000000;     // $191.88 = $15.99 * 12
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PREMIUM_YEAR  = 96000000000;     // $960 = $80 * 12
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PRO_YEAR      = 192000000000;    // $1920 = $160 * 12
    // Defined by UsdPricing; aliased so the many call sites below stay readable.
    uint constant DISCOUNT_BASE = UsdPricing.DISCOUNT_BASE;
    uint constant DEFAULT_DISCOUNT_COAI = 900; // 10% off, applied only to COAI payments by default
    uint32 constant PERIOD_MONTH = 30 days;
    uint32 constant DEFAULT_TRIAL_PLUS_MONTH = 3 days;
    uint32 constant PERIOD_YEAR = 365 days;
    // PAY_TOKEN_USDT/COAI/USDC values are stable identifiers; 0 reserved for "unset/never subscribed".
    uint8 constant PAY_TOKEN_USDT = 1;
    uint8 constant PAY_TOKEN_COAI = 2;
    uint8 constant PAY_TOKEN_USDC = 3;

    uint32 constant TWAP_INTERVAL = 1800; // 30 minutes
    address constant DEFAULT_PANCAKE_COAI_POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;
    address constant DEFAULT_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant DEFAULT_COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant DEFAULT_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    constructor(address receiver, address feeCollector, address subscriptionTerminator, uint minDelay, address[] memory proposers, address[] memory executors, address admin) {
        if (receiver == address(0) || feeCollector == address(0) || subscriptionTerminator == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidReceiver();
        // admin holds TIMELOCK_ADMIN_ROLE and can grant/revoke proposer/executor roles
        // without the delay, defeating the timelock — must be zero, the timelock self-administers.
        if (admin != address(0)) revert InvalidTimelockConfig();
        // Empty proposers/executors would deadlock the timelock and leave the contract
        // unable to ever execute onlyOwner mutations.
        if (proposers.length == 0 || executors.length == 0) revert InvalidTimelockConfig();
        _feeCollector = feeCollector;
        emit FeeCollectorChanged(feeCollector);
        _subscriptionTerminator = subscriptionTerminator;
        emit SubscriptionTerminatorChanged(subscriptionTerminator);
        _twapInterval = TWAP_INTERVAL;
        _usdt = ERC20(DEFAULT_USDT);
        _usdtDecimals = ERC20(DEFAULT_USDT).decimals();
        _coai = ERC20(DEFAULT_COAI);
        _coaiDecimals = ERC20(DEFAULT_COAI).decimals();
        if (_coaiDecimals != 18) revert UnsupportedDecimals();
        _usdc = ERC20(DEFAULT_USDC);
        _usdcDecimals = ERC20(DEFAULT_USDC).decimals();
        _coaiPriceFeed = IPancakeV3PoolState(DEFAULT_PANCAKE_COAI_POOL);
        _coaiIsToken0 = CoaiTwapPricing.resolveCoaiIsToken0(IPancakeV3PoolState(DEFAULT_PANCAKE_COAI_POOL), DEFAULT_COAI);
        _receiver = receiver;
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, admin);
        _owner = address(timelock);
        emit OwnerChanged(address(0), _owner);
        _switch = true;
        _subscriptionPrices[SUB_TYPE_GO_MONTH]      = DEFAULT_SUBSCRIPTION_AMOUNT_GO_MONTH;
        _subscriptionPrices[SUB_TYPE_PLUS_MONTH]    = DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_MONTH;
        _subscriptionPrices[SUB_TYPE_PREMIUM_MONTH] = DEFAULT_SUBSCRIPTION_AMOUNT_PREMIUM_MONTH;
        _subscriptionPrices[SUB_TYPE_PRO_MONTH]     = DEFAULT_SUBSCRIPTION_AMOUNT_PRO_MONTH;
        _subscriptionPrices[SUB_TYPE_GO_YEAR]       = DEFAULT_SUBSCRIPTION_AMOUNT_GO_YEAR;
        _subscriptionPrices[SUB_TYPE_PLUS_YEAR]     = DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_YEAR;
        _subscriptionPrices[SUB_TYPE_PREMIUM_YEAR]  = DEFAULT_SUBSCRIPTION_AMOUNT_PREMIUM_YEAR;
        _subscriptionPrices[SUB_TYPE_PRO_YEAR]      = DEFAULT_SUBSCRIPTION_AMOUNT_PRO_YEAR;
        emit SubscriptionPriceChanged(SUB_TYPE_GO_MONTH,      DEFAULT_SUBSCRIPTION_AMOUNT_GO_MONTH);
        emit SubscriptionPriceChanged(SUB_TYPE_PLUS_MONTH,    DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_MONTH);
        emit SubscriptionPriceChanged(SUB_TYPE_PREMIUM_MONTH, DEFAULT_SUBSCRIPTION_AMOUNT_PREMIUM_MONTH);
        emit SubscriptionPriceChanged(SUB_TYPE_PRO_MONTH,     DEFAULT_SUBSCRIPTION_AMOUNT_PRO_MONTH);
        emit SubscriptionPriceChanged(SUB_TYPE_GO_YEAR,       DEFAULT_SUBSCRIPTION_AMOUNT_GO_YEAR);
        emit SubscriptionPriceChanged(SUB_TYPE_PLUS_YEAR,     DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_YEAR);
        emit SubscriptionPriceChanged(SUB_TYPE_PREMIUM_YEAR,  DEFAULT_SUBSCRIPTION_AMOUNT_PREMIUM_YEAR);
        emit SubscriptionPriceChanged(SUB_TYPE_PRO_YEAR,      DEFAULT_SUBSCRIPTION_AMOUNT_PRO_YEAR);
        _discounts[PAY_TOKEN_USDT] = DISCOUNT_BASE; // no discount for USDT
        _discounts[PAY_TOKEN_COAI] = DEFAULT_DISCOUNT_COAI;
        _discounts[PAY_TOKEN_USDC] = DISCOUNT_BASE; // no discount for USDC
        emit DiscountChanged(PAY_TOKEN_USDT, DISCOUNT_BASE);
        emit DiscountChanged(PAY_TOKEN_COAI, DEFAULT_DISCOUNT_COAI);
        emit DiscountChanged(PAY_TOKEN_USDC, DISCOUNT_BASE);
        _subscriptionPeriods[SUB_TYPE_GO_MONTH]      = PERIOD_MONTH;
        _subscriptionPeriods[SUB_TYPE_PLUS_MONTH]    = PERIOD_MONTH;
        _subscriptionPeriods[SUB_TYPE_PREMIUM_MONTH] = PERIOD_MONTH;
        _subscriptionPeriods[SUB_TYPE_PRO_MONTH]     = PERIOD_MONTH;
        _subscriptionPeriods[SUB_TYPE_GO_YEAR]       = PERIOD_YEAR;
        _subscriptionPeriods[SUB_TYPE_PLUS_YEAR]     = PERIOD_YEAR;
        _subscriptionPeriods[SUB_TYPE_PREMIUM_YEAR]  = PERIOD_YEAR;
        _subscriptionPeriods[SUB_TYPE_PRO_YEAR]      = PERIOD_YEAR;
        emit SubscriptionPeriodChanged(SUB_TYPE_GO_MONTH,      PERIOD_MONTH);
        emit SubscriptionPeriodChanged(SUB_TYPE_PLUS_MONTH,    PERIOD_MONTH);
        emit SubscriptionPeriodChanged(SUB_TYPE_PREMIUM_MONTH, PERIOD_MONTH);
        emit SubscriptionPeriodChanged(SUB_TYPE_PRO_MONTH,     PERIOD_MONTH);
        emit SubscriptionPeriodChanged(SUB_TYPE_GO_YEAR,       PERIOD_YEAR);
        emit SubscriptionPeriodChanged(SUB_TYPE_PLUS_YEAR,     PERIOD_YEAR);
        emit SubscriptionPeriodChanged(SUB_TYPE_PREMIUM_YEAR,  PERIOD_YEAR);
        emit SubscriptionPeriodChanged(SUB_TYPE_PRO_YEAR,      PERIOD_YEAR);
        _trialPeriods[SUB_TYPE_PLUS_MONTH] = DEFAULT_TRIAL_PLUS_MONTH;
        emit TrialPeriodChanged(SUB_TYPE_PLUS_MONTH, DEFAULT_TRIAL_PLUS_MONTH);
        _subscriptionListed[SUB_TYPE_GO_MONTH]      = true;
        _subscriptionListed[SUB_TYPE_PLUS_MONTH]    = true;
        _subscriptionListed[SUB_TYPE_PREMIUM_MONTH] = true;
        _subscriptionListed[SUB_TYPE_PRO_MONTH]     = true;
        _subscriptionListed[SUB_TYPE_GO_YEAR]       = true;
        _subscriptionListed[SUB_TYPE_PLUS_YEAR]     = true;
        _subscriptionListed[SUB_TYPE_PREMIUM_YEAR]  = true;
        _subscriptionListed[SUB_TYPE_PRO_YEAR]      = true;
        emit SubscriptionListed(SUB_TYPE_GO_MONTH);
        emit SubscriptionListed(SUB_TYPE_PLUS_MONTH);
        emit SubscriptionListed(SUB_TYPE_PREMIUM_MONTH);
        emit SubscriptionListed(SUB_TYPE_PRO_MONTH);
        emit SubscriptionListed(SUB_TYPE_GO_YEAR);
        emit SubscriptionListed(SUB_TYPE_PLUS_YEAR);
        emit SubscriptionListed(SUB_TYPE_PREMIUM_YEAR);
        emit SubscriptionListed(SUB_TYPE_PRO_YEAR);
    }

    function subscriptionUSDT(uint subscriptionType, address inviter) switchOn external nonReentrant {
        _subscriptionUSDT(subscriptionType, inviter);
    }

    function subscriptionCOAI(uint subscriptionType, address inviter) switchOn external nonReentrant {
        _subscriptionCOAI(subscriptionType, inviter);
    }

    function subscriptionUSDC(uint subscriptionType, address inviter) switchOn external nonReentrant {
        _subscriptionUSDC(subscriptionType, inviter);
    }

    function renew(address account) onlyFeeCollector external nonReentrant {
        _renew(account);
    }

    /// @notice Charge a batch of accounts, isolating failures instead of reverting the
    /// whole batch: every account is attempted, and the ones that reverted are reported via
    /// RenewBatchFailed. A failed account's state changes are rolled back with its sub-call,
    /// so it stays exactly as it was and can simply be retried later.
    function renewBatch(address[] calldata accounts) onlyFeeCollector external nonReentrant {
        address[] memory buffer = new address[](accounts.length);
        uint failedCount;
        for (uint i = 0; i < accounts.length; i++) {
            // Self-call so a revert can be caught: try/catch only wraps external calls.
            try this.renewSelf(accounts[i]) {
            } catch {
                buffer[failedCount] = accounts[i];
                failedCount++;
            }
        }
        if (failedCount == 0) return;
        // Emit the exact-length list rather than the padded buffer.
        address[] memory failedAccounts = new address[](failedCount);
        for (uint i = 0; i < failedCount; i++) {
            failedAccounts[i] = buffer[i];
        }
        emit RenewBatchFailed(msg.sender, failedCount, failedAccounts);
    }

    /// @notice renewBatch's per-account trampoline. Callable ONLY by this contract, so it
    /// carries renewBatch's onlyFeeCollector authorization and cannot be used to bypass it.
    /// @dev Deliberately NOT nonReentrant: it executes inside renewBatch's guard, and a
    /// second guard would make every single call revert.
    function renewSelf(address account) external {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        _renew(account);
    }

    /// @notice Force-cancel `account`'s active subscription without settling any debt.
    /// Only callable by `_subscriptionTerminator`. Intended for accounts that have become
    /// unable to pay (lost approval, drained balance, etc.) so their unsettleable debt
    /// doesn't grow forever. Not gated by switchOn — must still work while paused.
    function terminateSubscription(address account) onlySubscriptionTerminator external {
        uint subscriptionType = _activeType[account];
        if (subscriptionType == 0) revert NotSubscribed();
        delete _nextChargeableAt[account][subscriptionType];
        delete _activeType[account];
        delete _activePayToken[account];
        delete _lockedPeriod[account];
        delete _pendingType[account];
        delete _trialEndsAt[account];
        delete _cancelled[account];
        emit SubscriptionTerminated(account, subscriptionType, msg.sender, block.timestamp);
    }

    /// @notice Cancel the caller's subscription. Service is not cut off immediately: the
    /// already-paid period runs to its end (_nextChargeableAt) and no further renewal is
    /// charged. Within that window restoreSubscription() puts the same plan back at no cost;
    /// once it elapses the subscription is over and a fresh subscribeXXX is required.
    /// @dev Switching plans goes through here: cancel, wait the period out, then subscribe to
    /// the new type. Subscribing straight into a different type is rejected by _requireDue.
    function cancelSubscription() external nonReentrant {
        address sender = msg.sender;
        uint subscriptionType = _activeType[sender];
        if (subscriptionType == 0) revert NotSubscribed();
        if (_cancelled[sender]) revert AlreadyCancelled();
        // If the caller is in debt, auto-settle so users always exit fully paid up
        // without needing a separate settleDebt tx first. This is also what guarantees a
        // cancelled account can never carry debt afterwards: renewals stop from here on.
        _settleIfDebt(sender, subscriptionType);
        // Cancelling supersedes a parked downgrade: the slot now holds "ends at period end".
        delete _pendingType[sender];
        _cancelled[sender] = true;
        emit SubscriptionCancelled(sender, subscriptionType, block.timestamp);
    }

    /// @notice Undo a cancellation while the paid-up period is still running. Free — that
    /// period was already paid for — and it keeps the original plan, pay token and anchor, so
    /// renewals just resume on the existing schedule. Once the period elapses this reverts
    /// with SubscriptionExpired and the caller has to subscribe again.
    function restoreSubscription() external nonReentrant {
        address sender = msg.sender;
        uint subscriptionType = _activeType[sender];
        if (subscriptionType == 0) revert NotSubscribed();
        if (!_cancelled[sender]) revert NotCancelled();
        uint next = _nextChargeableAt[sender][subscriptionType];
        if (block.timestamp >= next) revert SubscriptionExpired(next);
        delete _cancelled[sender];
        emit SubscriptionRestored(sender, subscriptionType, block.timestamp);
    }

    /// @notice Move to `newType`. The caller states an intent; the contract decides what that
    /// costs and when it happens:
    /// - mid-trial: swaps immediately, charges nothing, and keeps the trial's end date
    /// - worth money (an upgrade): swaps immediately and charges the pro-rata difference in the
    ///   caller's existing pay token. Same-length plans keep their renewal date; changing to a
    ///   plan of a different length restarts the cycle from now
    /// - worth nothing or less (a downgrade): parked until the paid-up period runs out, because
    ///   this contract holds no funds and so can never refund the difference
    /// Passing the plan already held clears a parked downgrade. Use previewChange() first to
    /// show the caller which of these will happen.
    function changeSubscription(uint newType) switchOn external nonReentrant {
        address sender = msg.sender;
        uint currentType = _activeType[sender];
        if (currentType == 0) revert NotSubscribed();
        // A cancelled account is on its way out; restoreSubscription first.
        if (_cancelled[sender]) revert AlreadyCancelled();

        if (newType == currentType) {
            // Not a change — the way to call off a parked downgrade.
            if (_pendingType[sender] == 0) revert NoScheduledChange();
            delete _pendingType[sender];
            emit ScheduledChangeCancelled(sender, currentType);
            return;
        }
        if (_subscriptionPrices[newType] == 0) revert InvalidSubscriptionType(newType);
        if (_subscriptionPeriods[newType] == 0) revert UnknownPeriod();
        if (!_subscriptionListed[newType]) revert NotListed(newType);

        // Mid-trial: the trial is a one-off offer tied to the account's first subscription, so
        // moving off that plan ends it, whatever the destination. Nothing was ever paid, so
        // there is no remaining value to pro-rate — a full period of the new plan is charged
        // now. Holds in both directions, cheaper plans included.
        if (block.timestamp < _trialEndsAt[sender]) {
            _endTrialWithChange(sender, currentType, newType);
            return;
        }

        uint next = _nextChargeableAt[sender][currentType];
        // Pro-rating needs a period that is still running. In arrears the remaining time is
        // negative, so make the caller square up first.
        if (block.timestamp >= next) revert SettleDebtFirst(next);

        int delta = _changeDeltaUSD(sender, currentType, newType, next);
        if (delta <= 0) {
            _pendingType[sender] = newType;
            emit DowngradeScheduled(sender, currentType, newType, next);
            return;
        }
        _upgradeNow(sender, currentType, newType, next, uint(delta));
    }

    /// @notice Call off a parked downgrade and stay on the current plan.
    function cancelScheduledChange() external nonReentrant {
        address sender = msg.sender;
        uint pending = _pendingType[sender];
        if (pending == 0) revert NoScheduledChange();
        delete _pendingType[sender];
        emit ScheduledChangeCancelled(sender, pending);
    }

    /// @notice What changeSubscription(newType) would do for `account` right now, so a front end
    /// can say "pay 120.01 USDT now" or "switches on the 15th" before asking for a signature.
    /// @return immediate Whether it takes effect now (true) or at the end of the paid-up period
    /// @return chargedAmount USD * 10^USD_DECIMALS taken now; 0 when the change is parked
    /// @return requiredTokenAmount `chargedAmount` in the account's pay token
    /// @return effectiveAt When the new plan starts applying
    function previewChange(address account, uint newType)
        external
        view
        returns (bool immediate, uint chargedAmount, uint requiredTokenAmount, uint effectiveAt)
    {
        uint currentType = _activeType[account];
        if (currentType == 0) revert NotSubscribed();
        if (_cancelled[account]) revert AlreadyCancelled();
        if (newType == currentType) revert SameSubscriptionType();
        if (_subscriptionPrices[newType] == 0) revert InvalidSubscriptionType(newType);
        if (_subscriptionPeriods[newType] == 0) revert UnknownPeriod();

        if (block.timestamp < _trialEndsAt[account]) {
            // Leaving the trial ends it and bills a whole period of the new plan right away.
            chargedAmount = _priceOf(newType, _activePayToken[account]);
            return (
                true,
                chargedAmount,
                _tokenAmountOf(_activePayToken[account], chargedAmount),
                block.timestamp
            );
        }
        uint next = _nextChargeableAt[account][currentType];
        if (block.timestamp >= next) revert SettleDebtFirst(next);

        int delta = _changeDeltaUSD(account, currentType, newType, next);
        if (delta <= 0) return (false, 0, 0, next);
        chargedAmount = uint(delta);
        return (
            true,
            chargedAmount,
            _tokenAmountOf(_activePayToken[account], chargedAmount),
            block.timestamp
        );
    }

    function settleDebt() external nonReentrant {
        address sender = msg.sender;
        uint subscriptionType = _activeType[sender];
        if (subscriptionType == 0) revert NotSubscribed();
        // A cancelled account was settled in full at cancel time and is never charged again,
        // so an elapsed _nextChargeableAt marks the subscription's end, not a debt.
        if (_cancelled[sender]) revert AlreadyCancelled();
        uint next = _nextChargeableAt[sender][subscriptionType];
        if (next == 0) revert NotSubscribed();
        if (block.timestamp < next) revert NoDebt();
        _settle(sender, subscriptionType);
    }

    function getFeeCollector() external view returns (address) {
        return _feeCollector;
    }

    function setFeeCollector(address new_feeCollector) onlyOwner external {
        if (new_feeCollector == address(0)) revert ZeroAddress();
        _feeCollector = new_feeCollector;
        emit FeeCollectorChanged(new_feeCollector);
    }

    function getSubscriptionTerminator() external view returns (address) {
        return _subscriptionTerminator;
    }

    function setSubscriptionTerminator(address new_subscriptionTerminator) onlyOwner external {
        if (new_subscriptionTerminator == address(0)) revert ZeroAddress();
        _subscriptionTerminator = new_subscriptionTerminator;
        emit SubscriptionTerminatorChanged(new_subscriptionTerminator);
    }

    function getSubscriptionPeriod(uint subscriptionType) external view returns (uint32) {
        return _subscriptionPeriods[subscriptionType];
    }

    /// @notice Set a plan's billing period. Applies to NEW subscriptions only: accounts already
    /// subscribed keep the period they locked in at subscribe time (getLockedPeriod), and only
    /// pick up the new one by cancelling and subscribing again. Note that price and period are
    /// independent — halving the period without halving the price doubles what a new subscriber
    /// pays per unit time.
    function setSubscriptionPeriod(uint subscriptionType, uint32 periodSeconds) onlyOwner external {
        // type 0 is the "unset / never subscribed" sentinel in _activeType.
        // Zero period would brick new subscribes on this type — use delistSubscription to stop
        // sign-ups instead.
        if (subscriptionType == 0) revert InvalidSubscriptionType(0);
        if (periodSeconds == 0) revert UnknownPeriod();
        _subscriptionPeriods[subscriptionType] = periodSeconds;
        emit SubscriptionPeriodChanged(subscriptionType, periodSeconds);
    }

    function getTrialPeriod(uint subscriptionType) external view returns (uint32) {
        return _trialPeriods[subscriptionType];
    }

    /// @notice Give `subscriptionType` a free trial of `trialSeconds`, or pass 0 to withdraw
    /// it. A plan with a non-zero trial is "trial-bearing"; that flag drives what happens when
    /// an account changes into or out of it (see changeSubscription). Affects new subscribes
    /// only — trials already running keep their anchor.
    /// @dev No upper bound on purpose: the trial length is whatever the owner (the timelock)
    /// decides, including longer than the plan's own period. It defers the first charge to
    /// now + trialSeconds; the billing schedule then runs off that anchor as usual.
    function setTrialPeriod(uint subscriptionType, uint32 trialSeconds) onlyOwner external {
        if (subscriptionType == 0) revert InvalidSubscriptionType(0);
        _trialPeriods[subscriptionType] = trialSeconds;
        emit TrialPeriodChanged(subscriptionType, trialSeconds);
    }

    /// @notice Whether `account` has ever held a subscription. Once true the account can never
    /// start a free trial again, on any plan — the trial is a first-subscription offer only.
    function hasEverSubscribed(address account) external view returns (bool) {
        return _everSubscribed[account];
    }

    /// @notice Whether a subscribe by `account` for `subscriptionType` right now would open a
    /// free trial rather than charge immediately. Front ends use this to pick the button.
    function startsTrial(address account, uint subscriptionType) external view returns (bool) {
        return _startsTrial(account, subscriptionType);
    }

    function isListed(uint subscriptionType) external view returns (bool) {
        return _subscriptionListed[subscriptionType];
    }

    function listSubscription(uint subscriptionType) onlyOwner external {
        if (subscriptionType == 0) revert InvalidSubscriptionType(0);
        if (_subscriptionListed[subscriptionType]) revert AlreadyListed(subscriptionType);
        // Require price and period configured before opening to new subscribers.
        if (_subscriptionPrices[subscriptionType] == 0) revert InvalidSubscriptionType(subscriptionType);
        if (_subscriptionPeriods[subscriptionType] == 0) revert UnknownPeriod();
        _subscriptionListed[subscriptionType] = true;
        emit SubscriptionListed(subscriptionType);
    }

    function delistSubscription(uint subscriptionType) onlyOwner external {
        if (!_subscriptionListed[subscriptionType]) revert NotListed(subscriptionType);
        _subscriptionListed[subscriptionType] = false;
        emit SubscriptionDelisted(subscriptionType);
    }

    function getNextChargeableAt(address account, uint subscriptionType) external view returns (uint) {
        return _nextChargeableAt[account][subscriptionType];
    }

    /// @notice Raw stored plan, which lingers after a cancelled period has elapsed.
    /// Use getEffectiveType for actual entitlement.
    function getActiveType(address account) external view returns (uint) {
        return _activeType[account];
    }

    /// @notice The plan `account` is entitled to right now, or 0 if none. Unlike
    /// getActiveType this reports 0 once a cancelled subscription's paid-up period has
    /// elapsed. This is what the fee collector should build its renew batches from.
    function getEffectiveType(address account) external view returns (uint) {
        uint subscriptionType = _activeType[account];
        if (subscriptionType == 0) return 0;
        if (_cancelled[account] && block.timestamp >= _nextChargeableAt[account][subscriptionType]) return 0;
        return subscriptionType;
    }

    function isCancelled(address account) external view returns (bool) {
        return _cancelled[account];
    }

    /// @notice The plan `account` switches to when the paid-up period ends, or 0 if none.
    function getPendingType(address account) external view returns (uint) {
        return _pendingType[account];
    }

    /// @notice When `account`'s free trial ends. In the past (or 0) means not on trial.
    function getTrialEndsAt(address account) external view returns (uint) {
        return _trialEndsAt[account];
    }

    /// @notice Whether `account` is inside its free trial right now, i.e. whether a plan change
    /// would be free.
    function isInTrial(address account) external view returns (bool) {
        return block.timestamp < _trialEndsAt[account];
    }

    /// @notice Whether restoreSubscription() would succeed for `account` right now.
    function canRestore(address account) external view returns (bool) {
        uint subscriptionType = _activeType[account];
        if (subscriptionType == 0) return false;
        if (!_cancelled[account]) return false;
        return block.timestamp < _nextChargeableAt[account][subscriptionType];
    }

    function getActivePayToken(address account) external view returns (uint8) {
        return _activePayToken[account];
    }

    /// @notice The billing period `account` is locked into, in seconds: the plan's period as it
    /// stood when they subscribed. setSubscriptionPeriod does not affect it — compare against
    /// getSubscriptionPeriod to see whether an account is on an outdated cadence. 0 if the
    /// account has never subscribed.
    function getLockedPeriod(address account) external view returns (uint32) {
        return _lockedPeriod[account];
    }

    function getInviter(address account) external view returns (address) {
        return _inviters[account];
    }

    function nextChargeableAt(address account) external view returns (uint) {
        uint subscriptionType = _activeType[account];
        if (subscriptionType == 0) return 0;
        return _nextChargeableAt[account][subscriptionType];
    }

    function getSubscriptionAmountUSDT(uint subscriptionType) external view returns (uint) {
        return _calculateAmountUSDT(_priceOf(subscriptionType, PAY_TOKEN_USDT));
    }

    function getSubscriptionAmountCOAI(uint subscriptionType) external view returns (uint) {
        return _calculateAmountCOAI(_priceOf(subscriptionType, PAY_TOKEN_COAI));
    }

    function getSubscriptionAmountUSDC(uint subscriptionType) external view returns (uint) {
        return _calculateAmountUSDC(_priceOf(subscriptionType, PAY_TOKEN_USDC));
    }

    function getSubscriptionPrice(uint subscriptionType) external view returns (uint) {
        return _subscriptionPrices[subscriptionType];
    }

    function setSubscriptionPrice(uint subscriptionType, uint price) onlyOwner external {
        // Zero price would brick _priceOf for existing subscribers — use delistSubscription
        // to stop new sign-ups instead.
        if (subscriptionType == 0) revert InvalidSubscriptionType(0);
        if (price == 0) revert InvalidSubscriptionType(subscriptionType);
        _subscriptionPrices[subscriptionType] = price;
        emit SubscriptionPriceChanged(subscriptionType, price);
    }

    function getDiscount(uint8 payToken) external view returns (uint) {
        return _discounts[payToken];
    }

    function setDiscount(uint8 payToken, uint new_discount) onlyOwner external {
        if (payToken != PAY_TOKEN_USDT && payToken != PAY_TOKEN_COAI && payToken != PAY_TOKEN_USDC) {
            revert UnknownPayToken(payToken);
        }
        if (new_discount == 0 || new_discount > DISCOUNT_BASE) revert InvalidDiscount();
        _discounts[payToken] = new_discount;
        emit DiscountChanged(payToken, new_discount);
    }

    function getCoaiTwapHealth() external view returns (bool) {
        return CoaiTwapPricing.isHealthy(_coaiPriceFeed, _twapInterval);
    }

    function getUSDTAddress() external view returns (address) {
        return address(_usdt);
    }

    function getUSDTDecimals() external view returns (uint8) {
        return _usdtDecimals;
    }

    function setUSDTAddress(address new_usdtAddress) onlyOwner external {
        if (new_usdtAddress == address(0)) revert ZeroAddress();
        _usdt = ERC20(new_usdtAddress);
        _usdtDecimals = ERC20(new_usdtAddress).decimals();
        emit USDTAddressChanged(new_usdtAddress, _usdtDecimals);
    }

    function getUSDCAddress() external view returns (address) {
        return address(_usdc);
    }

    function getUSDCDecimals() external view returns (uint8) {
        return _usdcDecimals;
    }

    function setUSDCAddress(address new_usdcAddress) onlyOwner external {
        if (new_usdcAddress == address(0)) revert ZeroAddress();
        _usdc = ERC20(new_usdcAddress);
        _usdcDecimals = ERC20(new_usdcAddress).decimals();
        emit USDCAddressChanged(new_usdcAddress, _usdcDecimals);
    }

    function getCOAIAddress() external view returns (address) {
        return address(_coai);
    }

    function getCOAIDecimals() external view returns (uint8) {
        return _coaiDecimals;
    }

    function getCOAIIsToken0() external view returns (bool) {
        return _coaiIsToken0;
    }

    function setCOAIAddress(address new_coaiAddress, address new_coaiPriceFeedAddress) onlyOwner external {
        if (new_coaiAddress == address(0)) revert ZeroAddress();
        if (new_coaiPriceFeedAddress == address(0)) revert ZeroAddress();
        uint8 dec = ERC20(new_coaiAddress).decimals();
        if (dec != 18) revert UnsupportedDecimals();
        _coai = ERC20(new_coaiAddress);
        _coaiDecimals = dec;
        _coaiPriceFeed = IPancakeV3PoolState(new_coaiPriceFeedAddress);
        _coaiIsToken0 = CoaiTwapPricing.resolveCoaiIsToken0(_coaiPriceFeed, new_coaiAddress);
        emit COAIAddressChanged(new_coaiAddress, dec);
        emit COAIPriceFeedAddressChanged(new_coaiPriceFeedAddress);
    }

    function getCOAIPriceFeedAddress() external view returns (address) {
        return address(_coaiPriceFeed);
    }

    function setCOAIPriceFeedAddress(address new_coaiPriceFeedAddress) onlyOwner external {
        if (new_coaiPriceFeedAddress == address(0)) revert ZeroAddress();
        _coaiPriceFeed = IPancakeV3PoolState(new_coaiPriceFeedAddress);
        _coaiIsToken0 = CoaiTwapPricing.resolveCoaiIsToken0(IPancakeV3PoolState(new_coaiPriceFeedAddress), address(_coai));
        emit COAIPriceFeedAddressChanged(new_coaiPriceFeedAddress);
    }

    function getTwapInterval() external view returns (uint32) {
        return _twapInterval;
    }

    function setTwapInterval(uint32 new_twapInterval) onlyOwner external {
        if (new_twapInterval < 300 || new_twapInterval > 1 days) revert InvalidTwapInterval();
        _twapInterval = new_twapInterval;
        emit TwapIntervalChanged(new_twapInterval);
    }

    function getSwitch() external view returns (bool) {
        return _switch;
    }

    function setSwitch(bool new_switch) onlyOwner external {
        _switch = new_switch;
        emit SwitchChanged(new_switch);
    }

    function getReceiver() external view returns (address) {
        return _receiver;
    }

    function setReceiver(address new_receiver) onlyOwner external {
        if (new_receiver == address(0)) revert ZeroAddress();
        if (new_receiver == address(this)) revert InvalidReceiver();
        _receiver = new_receiver;
        emit ReceiverChanged(new_receiver);
    }

    function getOwner() external view returns (address) {
        return _owner;
    }

    function getPendingOwner() external view returns (address) {
        return _pendingOwner;
    }

    function setOwner(address new_owner) onlyOwner external {
        if (new_owner == address(0) || new_owner == address(this)) revert ZeroAddress();
        _pendingOwner = new_owner;
        emit PendingOwnerChanged(new_owner);
    }

    function acceptOwnership() onlyPendingOwner external {
        address previousOwner = _owner;
        _owner = _pendingOwner;
        _pendingOwner = address(0);
        emit OwnerChanged(previousOwner, _owner);
    }

    modifier onlyPendingOwner() {
        address caller = msg.sender;
        if (caller != _pendingOwner) revert NotPendingOwner(_pendingOwner, caller);
        _;
    }

    modifier onlyOwner() {
        address caller = msg.sender;
        if (caller != _owner) revert NotOwner(_owner, caller);
        _;
    }

    modifier onlyFeeCollector() {
        if (msg.sender != _feeCollector) revert NotFeeCollector(_feeCollector, msg.sender);
        _;
    }

    modifier onlySubscriptionTerminator() {
        if (msg.sender != _subscriptionTerminator) revert NotSubscriptionTerminator(_subscriptionTerminator, msg.sender);
        _;
    }

    modifier switchOn() {
        if (!_switch) revert SwitchOff();
        _;
    }

    function _subscriptionUSDT(uint subscriptionType, address inviter) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        _recordInviter(sender, inviter);
        // Trial checked before pricing: a trial must not depend on a live quote (the COAI
        // path would revert on a stale TWAP) and nothing is charged, so there is no price
        // to compute.
        if (_startsTrial(sender, subscriptionType)) {
            _activate(sender, subscriptionType, PAY_TOKEN_USDT);
            emit TrialStarted(sender, subscriptionType, inviter, PAY_TOKEN_USDT, _nextChargeableAt[sender][subscriptionType]);
            return;
        }
        uint price = _priceOf(subscriptionType, PAY_TOKEN_USDT);
        uint requiredUSDTAmount = _calculateAmountUSDT(price);
        _activate(sender, subscriptionType, PAY_TOKEN_USDT);
        emit SubscribedUSDT(sender, subscriptionType, inviter, price, requiredUSDTAmount);
        _usdt.safeTransferFrom(sender, _receiver, requiredUSDTAmount);
    }

    function _subscriptionCOAI(uint subscriptionType, address inviter) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        _recordInviter(sender, inviter);
        // Trial checked before pricing: a trial must not depend on a live quote (the COAI
        // path would revert on a stale TWAP) and nothing is charged, so there is no price
        // to compute.
        if (_startsTrial(sender, subscriptionType)) {
            _activate(sender, subscriptionType, PAY_TOKEN_COAI);
            emit TrialStarted(sender, subscriptionType, inviter, PAY_TOKEN_COAI, _nextChargeableAt[sender][subscriptionType]);
            return;
        }
        uint price = _priceOf(subscriptionType, PAY_TOKEN_COAI);
        uint requiredCOAIAmount = _calculateAmountCOAI(price);
        _activate(sender, subscriptionType, PAY_TOKEN_COAI);
        emit SubscribedCOAI(sender, subscriptionType, inviter, price, requiredCOAIAmount);
        _coai.safeTransferFrom(sender, _receiver, requiredCOAIAmount);
    }

    function _subscriptionUSDC(uint subscriptionType, address inviter) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        _recordInviter(sender, inviter);
        // Trial checked before pricing: a trial must not depend on a live quote (the COAI
        // path would revert on a stale TWAP) and nothing is charged, so there is no price
        // to compute.
        if (_startsTrial(sender, subscriptionType)) {
            _activate(sender, subscriptionType, PAY_TOKEN_USDC);
            emit TrialStarted(sender, subscriptionType, inviter, PAY_TOKEN_USDC, _nextChargeableAt[sender][subscriptionType]);
            return;
        }
        uint price = _priceOf(subscriptionType, PAY_TOKEN_USDC);
        uint requiredUSDCAmount = _calculateAmountUSDC(price);
        _activate(sender, subscriptionType, PAY_TOKEN_USDC);
        emit SubscribedUSDC(sender, subscriptionType, inviter, price, requiredUSDCAmount);
        _usdc.safeTransferFrom(sender, _receiver, requiredUSDCAmount);
    }

    /// @dev Refreshable inviter recording. `inviter` is mandatory: must be non-zero and
    /// not equal to `sender` (self-referral blocked). Every successful subscribe overwrites
    /// the stored value, so users can switch their referrer on a later subscribe call.
    function _recordInviter(address sender, address inviter) private {
        if (inviter == sender) revert InvalidInviter();
        _inviters[sender] = inviter;
    }

    function _renew(address account) private {
        uint subscriptionType = _activeType[account];
        if (subscriptionType == 0) revert NotSubscribed();
        // Cancelled accounts coast on their paid-up period and are never charged again. The
        // fee collector should filter these out (getEffectiveType) rather than rely on this
        // revert, which would otherwise show up in RenewBatchFailed as noise.
        if (_cancelled[account]) revert AlreadyCancelled();
        uint next = _nextChargeableAt[account][subscriptionType];
        if (next == 0) revert NotSubscribed();
        // The account's own period, not the plan's current one — see _lockedPeriod.
        uint32 period = _lockedPeriod[account];
        if (period == 0) revert UnknownPeriod();
        if (block.timestamp < next) revert NotDueYet(next);
        // The paid-up period is over, so a parked downgrade lands now and everything charged
        // below is already at the new plan.
        (subscriptionType, period) = _applyPendingChange(account, subscriptionType, period);
        uint8 payToken = _activePayToken[account];
        // anchor-based accumulation: charge for every period elapsed since the anchor
        uint periodsCharged = (block.timestamp - next) / period + 1;
        _nextChargeableAt[account][subscriptionType] = next + periodsCharged * period;
        uint price = _priceOf(subscriptionType, payToken);
        uint requiredTokenAmount;
        if (payToken == PAY_TOKEN_USDT) {
            requiredTokenAmount = _calculateAmountUSDT(price) * periodsCharged;
            emit Renewed(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _usdt.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else if (payToken == PAY_TOKEN_COAI) {
            requiredTokenAmount = _calculateAmountCOAI(price) * periodsCharged;
            emit Renewed(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _coai.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else if (payToken == PAY_TOKEN_USDC) {
            requiredTokenAmount = _calculateAmountUSDC(price) * periodsCharged;
            emit Renewed(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _usdc.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else {
            revert UnknownPayToken(payToken);
        }
    }

    /// @dev Gate for every subscribeXXX entry. Enforces the plan-change rule: an account may
    /// only ever subscribe to the type it already holds, and moving to a different type
    /// requires cancelSubscription() plus waiting out the paid-up period.
    function _requireDue(address account, uint subscriptionType) private view {
        // Only block NEW subscriptions for delisted types — existing subscribers can still
        // renew, settle, cancel, and restore even after delist.
        if (!_subscriptionListed[subscriptionType]) revert NotListed(subscriptionType);
        uint32 period = _subscriptionPeriods[subscriptionType];
        if (period == 0) revert UnknownPeriod();
        uint previous = _activeType[account];
        if (previous == 0) return; // never subscribed (or terminated) — any listed type is open
        // Invariant: a non-zero _activeType always has a non-zero anchor on that type.
        uint previousNext = _nextChargeableAt[account][previous];
        if (_cancelled[account]) {
            // Cancelled: the paid-up period must run out before ANY new subscription, the
            // same type included. Inside the window the only way back is restoreSubscription,
            // which returns the already-paid plan for free.
            if (block.timestamp < previousNext) revert NotDueYet(previousNext);
            return;
        }
        // A parked downgrade would collide with the anchor bookkeeping below, and resubscribing
        // is not how you resolve one — changeSubscription overwrites it, cancelScheduledChange
        // drops it. Keeping this out also guarantees _activate never meets a pending change.
        uint pending = _pendingType[account];
        if (pending != 0) revert PendingChangeExists(pending);
        // Active: no direct plan switch — changeSubscription handles upgrades and downgrades.
        if (previous != subscriptionType) revert MustCancelFirst(previous);
        // Same type: cannot pay ahead while the current period is still running.
        if (block.timestamp < previousNext) revert NotDueYet(previousNext);
    }

    function _settleIfDebt(address account, uint subscriptionType) private {
        uint next = _nextChargeableAt[account][subscriptionType];
        if (next == 0) return; // not subscribed to this type
        if (block.timestamp < next) return; // not in debt
        _settle(account, subscriptionType);
    }

    function _settle(address account, uint subscriptionType) private {
        // Caller MUST have verified _nextChargeableAt[account][subscriptionType] != 0
        // AND block.timestamp >= that value (i.e. debt exists).
        uint next = _nextChargeableAt[account][subscriptionType];
        // The account's own period, not the plan's current one — see _lockedPeriod.
        uint32 period = _lockedPeriod[account];
        if (period == 0) revert UnknownPeriod();
        // Same as in _renew: the period being settled is over, so a parked downgrade lands
        // first and the arrears are billed at the new plan.
        (subscriptionType, period) = _applyPendingChange(account, subscriptionType, period);
        uint periodsCharged = (block.timestamp - next) / period + 1;
        _nextChargeableAt[account][subscriptionType] = next + periodsCharged * period;
        uint8 payToken = _activePayToken[account];
        uint price = _priceOf(subscriptionType, payToken);
        uint requiredTokenAmount;
        if (payToken == PAY_TOKEN_USDT) {
            requiredTokenAmount = _calculateAmountUSDT(price) * periodsCharged;
            emit DebtSettled(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _usdt.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else if (payToken == PAY_TOKEN_COAI) {
            requiredTokenAmount = _calculateAmountCOAI(price) * periodsCharged;
            emit DebtSettled(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _coai.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else if (payToken == PAY_TOKEN_USDC) {
            requiredTokenAmount = _calculateAmountUSDC(price) * periodsCharged;
            emit DebtSettled(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _usdc.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else {
            revert UnknownPayToken(payToken);
        }
    }

    /// @return trialStarted True when this subscribe opened a free trial and therefore
    /// charged nothing — the caller must skip its transfer and emit TrialStarted instead.
    function _activate(address account, uint subscriptionType, uint8 payToken) private returns (bool trialStarted) {
        // Must be read BEFORE the cancelled-account cleanup below, which clears the very
        // state _startsTrial inspects.
        trialStarted = _startsTrial(account, subscriptionType);
        uint previous = _activeType[account];
        if (previous != 0) {
            if (_cancelled[account]) {
                // _requireDue has confirmed the paid-up period ran out, so the cancelled
                // subscription is truly over. Drop both anchors and the flag so this counts as
                // a brand-new subscription: the gap between cancelling and coming back is
                // never billed, and the new plan starts from now rather than a stale anchor.
                delete _nextChargeableAt[account][previous];
                delete _nextChargeableAt[account][subscriptionType];
                delete _cancelled[account];
                if (previous != subscriptionType) {
                    emit SubscriptionSwitched(account, previous, subscriptionType);
                }
            } else {
                // Active resubscribe. _requireDue guarantees the type is unchanged and the
                // period is up, so settle every period accrued since the anchor — the caller
                // cannot walk away from unpaid periods — and this call pays for one more.
                _settleIfDebt(account, previous);
            }
        }
        _activeType[account] = subscriptionType;
        _activePayToken[account] = payToken;
        // Burns the one-off trial eligibility, whether or not this subscribe used it.
        _everSubscribed[account] = true;
        uint next = _nextChargeableAt[account][subscriptionType];
        // A fresh start adopts whatever the plan's period is right now and locks it in for the
        // life of this subscription. A resubscribe onto a running anchor keeps the period the
        // account already holds, so the two can never be mixed when advancing the anchor.
        uint32 period;
        if (next == 0) {
            period = _subscriptionPeriods[subscriptionType];
            _lockedPeriod[account] = period;
        } else {
            period = _lockedPeriod[account];
        }
        if (trialStarted) {
            // Free trial: nothing is charged now. Anchoring at the trial's end means the fee
            // collector's renew at that moment takes the first full period, and every later
            // period follows the normal schedule off that same anchor — no special casing
            // anywhere in _renew/_settle. Cancelling before it lands stops the charge outright.
            uint trialEndsAt = block.timestamp + _trialPeriods[subscriptionType];
            _nextChargeableAt[account][subscriptionType] = trialEndsAt;
            _trialEndsAt[account] = trialEndsAt;
            return true;
        }
        // Fresh start (first subscribe, post-terminate, or after a cancelled period elapsed):
        // anchor at now + period. Existing anchor (same-type resubscribe once due): advance
        // by one period.
        _nextChargeableAt[account][subscriptionType] = next == 0 ? block.timestamp + period : next + period;
        return false;
    }

    /// @dev What moving from `currentType` to `newType` is worth in USD * 10^USD_DECIMALS,
    /// positive when the caller owes money. Both plans are valued at their discounted price for
    /// the caller's pay token, so a COAI payer pro-rates against what COAI payers actually pay.
    /// Two shapes, picked by whether the new plan's length matches the one the account is on:
    ///   same length  -> (newPrice - oldPrice) * remaining / period, the renewal date is kept
    ///   different    -> newPrice - oldPrice * remaining / period, a whole new cycle is bought
    ///                   and the old one's unused tail is credited against it
    function _changeDeltaUSD(address account, uint currentType, uint newType, uint next)
        private
        view
        returns (int)
    {
        uint8 payToken = _activePayToken[account];
        uint32 period = _lockedPeriod[account];
        uint remaining = next - block.timestamp; // caller guarantees next > block.timestamp
        int oldPrice = int(_priceOf(currentType, payToken));
        int newPrice = int(_priceOf(newType, payToken));
        if (_subscriptionPeriods[newType] == period) {
            return (newPrice - oldPrice) * int(remaining) / int(uint(period));
        }
        return newPrice - oldPrice * int(remaining) / int(uint(period));
    }

    /// @dev Swap the plan now and collect `chargedAmount`. A same-length change keeps the
    /// renewal date; a different-length one restarts the cycle from now, which is what makes
    /// the whole-cycle price charged by _changeDeltaUSD the right amount.
    function _upgradeNow(address account, uint currentType, uint newType, uint next, uint chargedAmount) private {
        uint8 payToken = _activePayToken[account];
        uint requiredTokenAmount = _tokenAmountOf(payToken, chargedAmount);
        uint32 newPeriod = _subscriptionPeriods[newType];
        uint newNext = newPeriod == _lockedPeriod[account] ? next : block.timestamp + newPeriod;

        delete _nextChargeableAt[account][currentType];
        // Paying to move up supersedes any parked downgrade — it was decided against the plan
        // the account is now leaving.
        delete _pendingType[account];
        _activeType[account] = newType;
        _lockedPeriod[account] = newPeriod;
        _nextChargeableAt[account][newType] = newNext;

        emit SubscriptionUpgraded(account, currentType, newType, payToken, chargedAmount, requiredTokenAmount, newNext);
        _collect(payToken, account, requiredTokenAmount);
    }

    /// @dev Leave a running trial for another plan. The trial ends immediately and a full
    /// period of the new plan is charged now, so the cycle restarts from this moment.
    /// @dev The destination plan's own trial is deliberately NOT burnt: this account is paying
    /// for it, not trialling it, so a trial it never consumed stays available to it later.
    function _endTrialWithChange(address account, uint currentType, uint newType) private {
        uint8 payToken = _activePayToken[account];
        uint chargedAmount = _priceOf(newType, payToken);
        uint requiredTokenAmount = _tokenAmountOf(payToken, chargedAmount);
        uint32 newPeriod = _subscriptionPeriods[newType];
        uint newNext = block.timestamp + newPeriod;

        delete _nextChargeableAt[account][currentType];
        delete _pendingType[account];
        // The trial is over, so isInTrial() stops reporting it and a later change is priced
        // pro-rata like any other.
        delete _trialEndsAt[account];
        _activeType[account] = newType;
        _lockedPeriod[account] = newPeriod;
        _nextChargeableAt[account][newType] = newNext;

        emit TrialEndedByChange(account, currentType, newType, payToken, chargedAmount, requiredTokenAmount, newNext);
        _collect(payToken, account, requiredTokenAmount);
    }

    /// @dev Land a parked downgrade. Called from _renew/_settle once the paid-up period is over,
    /// so the charge that follows is already at the new plan. The anchor moves across untouched
    /// and the caller advances it with the returned period.
    /// @dev Arrears are billed wholly at the new plan even when several periods have piled up.
    /// The account asked to move down from `next` onward; a late fee collector should not make
    /// that cost more.
    function _applyPendingChange(address account, uint subscriptionType, uint32 period)
        private
        returns (uint, uint32)
    {
        uint pending = _pendingType[account];
        if (pending == 0) return (subscriptionType, period);
        uint32 newPeriod = _subscriptionPeriods[pending];
        if (newPeriod == 0) revert UnknownPeriod();
        uint next = _nextChargeableAt[account][subscriptionType];
        delete _nextChargeableAt[account][subscriptionType];
        delete _pendingType[account];
        _activeType[account] = pending;
        _lockedPeriod[account] = newPeriod;
        _nextChargeableAt[account][pending] = next;
        emit SubscriptionDowngraded(account, subscriptionType, pending, block.timestamp);
        return (pending, newPeriod);
    }

    function _tokenAmountOf(uint8 payToken, uint rawAmount) private view returns (uint) {
        if (payToken == PAY_TOKEN_USDT) return _calculateAmountUSDT(rawAmount);
        if (payToken == PAY_TOKEN_COAI) return _calculateAmountCOAI(rawAmount);
        if (payToken == PAY_TOKEN_USDC) return _calculateAmountUSDC(rawAmount);
        revert UnknownPayToken(payToken);
    }

    function _collect(uint8 payToken, address from, uint amount) private {
        if (payToken == PAY_TOKEN_USDT) _usdt.safeTransferFrom(from, _receiver, amount);
        else if (payToken == PAY_TOKEN_COAI) _coai.safeTransferFrom(from, _receiver, amount);
        else if (payToken == PAY_TOKEN_USDC) _usdc.safeTransferFrom(from, _receiver, amount);
        else revert UnknownPayToken(payToken);
    }

    /// @dev Single source of truth for "does this subscribe open a trial instead of charging".
    /// Called both by the subscribeXXX paths (to skip pricing and the transfer) and by
    /// _activate (to set the anchor), so the two can never disagree.
    /// @dev Two conditions, and that is the whole rule: the plan offers a trial, and this is
    /// the account's very first subscription. Nothing about renewals, cancelled-and-elapsed
    /// accounts or per-plan bookkeeping is needed — _everSubscribed covers all of it, because
    /// every one of those states implies the account has subscribed before.
    function _startsTrial(address account, uint subscriptionType) private view returns (bool) {
        if (_everSubscribed[account]) return false;
        return _trialPeriods[subscriptionType] != 0;
    }

    function _calculateAmountUSDT(uint rawAmount) private view returns (uint) {
        return UsdPricing.toStableAmount(rawAmount, _usdtDecimals);
    }

    function _calculateAmountUSDC(uint rawAmount) private view returns (uint) {
        return UsdPricing.toStableAmount(rawAmount, _usdcDecimals);
    }

    function _calculateAmountCOAI(uint rawAmount) private view returns (uint) {
        return CoaiTwapPricing.toCoaiAmount(_coaiPriceFeed, _twapInterval, _coaiIsToken0, _coaiDecimals, rawAmount);
    }

    function _priceOf(uint subscriptionType, uint8 payToken) private view returns (uint) {
        uint price = _subscriptionPrices[subscriptionType];
        if (price == 0) revert InvalidSubscriptionType(subscriptionType);
        return UsdPricing.applyDiscount(price, _discounts[payToken]);
    }

}

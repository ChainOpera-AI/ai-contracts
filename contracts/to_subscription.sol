// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./lib/IPancakeV3PoolState.sol";
import "./lib/CoaiTwapPricing.sol";
import "./lib/UsdPricing.sol";

/// @title Subscription billing where the plan lives with the subscriber, not the contract.
/// @notice TeamilyOpera's subscription contract. Unlike Subscription (ChainOpera) there is no
/// plan table on chain. The subscriber states the terms -- a USD amount, a period and an opaque
/// plan reference -- and the contract freezes them on the account. Every later charge is bounded
/// by those terms: `amountUSD` per `period`, in the pay token the account chose, straight to
/// `_receiver`. Nothing the owner can set changes what an existing subscriber pays; only the
/// subscriber can, by changing or re-subscribing. The backend reads the terms off the events,
/// checks them against its own catalogue and grants service accordingly -- the contract does
/// not know, or care, whether $20 per 30 days is a real product.
/// @dev Deployed behind an ERC1967 proxy. The storage layout below is part of the contract's
/// ABI as far as upgrades are concerned: existing variables may never be reordered, retyped or
/// removed, and anything new goes at the end, taking from __gap.
contract TOSubscription is Initializable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using SafeERC20 for ERC20;

    error SwitchOff();
    error InvalidTwapInterval();
    error UnsupportedDecimals();
    error InvalidDiscount();
    error NotFeeCollector(address feeCollector, address caller);
    error NotSelf(address caller);
    error NotSubscriptionTerminator(address subscriptionTerminator, address caller);
    error NotDueYet(uint nextChargeableAt);
    error NotSubscribed();
    error AlreadyCancelled();
    error NotCancelled();
    error SubscriptionExpired(uint expiredAt);
    /// @dev An active account may only re-subscribe on the terms it already holds (that is how
    /// arrears get settled); anything else goes through changeSubscription, or cancel and wait.
    error MustCancelFirst(uint amountUSD, uint32 period, bytes32 planRef);
    error SettleDebtFirst(uint dueAt);
    error NoScheduledChange();
    error SameTerms();
    error PendingChangeExists();
    error UnknownPayToken(uint8 payToken);
    error NoDebt();
    error NotOwner(address owner, address caller);
    error NotPendingOwner(address pendingOwner, address caller);
    error ZeroAddress();
    error InvalidReceiver();
    error InvalidInviter();
    error AmountOutOfRange(uint amountUSD);
    error PeriodOutOfRange(uint32 period, uint32 minPeriod, uint32 maxPeriod);
    error InvalidPeriodBounds();
    error TrialTooLong(uint32 trialSeconds, uint32 maxTrialSeconds);
    /// @dev A trial was asked for by an account that has subscribed before. Refused rather
    /// than quietly charged: the caller said "free", so taking money would be a surprise.
    error TrialNotAvailable();

    /// @notice The terms an account committed to. `amountUSD` doubles as the subscribed flag:
    /// zero means no subscription, so a valid amount is never zero.
    struct Terms {
        uint amountUSD;     // USD * 10^USD_DECIMALS per period, before any pay-token discount
        uint32 period;      // seconds
        bytes32 planRef;    // whatever the front end sent; echoed in events, never interpreted
    }

    /// @notice Everything about one account's subscription, for front ends and the backend.
    struct SubscriptionInfo {
        uint amountUSD;
        uint32 period;
        bytes32 planRef;
        uint8 payToken;
        uint nextChargeableAt;
        bool cancelled;
        bool active;            // entitled right now: subscribed, and not cancelled-and-elapsed
        uint trialEndsAt;
        uint pendingAmountUSD;  // a parked downgrade, landing when the paid-up period ends
        uint32 pendingPeriod;
        bytes32 pendingPlanRef;
    }

    /// @dev A paid subscribe. `amountUSD` is what the account committed to per period,
    /// `chargedUSD` that amount after the pay token's discount, `requiredTokenAmount` what was
    /// actually transferred. The backend checks (amountUSD, period, planRef) against its
    /// catalogue; nothing on chain has.
    event Subscribed(
        address indexed account,
        uint8 indexed payToken,
        bytes32 indexed planRef,
        uint amountUSD,
        uint32 period,
        address inviter,
        uint chargedUSD,
        uint requiredTokenAmount,
        uint nextChargeableAt
    );
    /// @dev Emitted instead of Subscribed when a subscribe opens a free trial: nothing is
    /// transferred. The first charge lands at `trialEndsAt` through renew. `trialSeconds` is
    /// the caller's own number; the backend decides whether that trial was on offer.
    event TrialStarted(
        address indexed account,
        uint8 indexed payToken,
        bytes32 indexed planRef,
        uint amountUSD,
        uint32 period,
        uint32 trialSeconds,
        address inviter,
        uint trialEndsAt
    );
    event Renewed(
        address indexed account,
        uint8 indexed payToken,
        bytes32 indexed planRef,
        uint amountUSD,
        uint requiredTokenAmount,
        uint periodsCharged,
        uint chargedAt
    );
    event DebtSettled(
        address indexed account,
        uint8 indexed payToken,
        bytes32 indexed planRef,
        uint amountUSD,
        uint requiredTokenAmount,
        uint periodsCharged,
        uint settledAt
    );
    /// @notice Arrears given up when an account cancelled. Not charged, not recoverable.
    /// Carries periods rather than an amount on purpose: pricing COAI reads the TWAP, and a
    /// revert there would put cancelling back out of reach of the accounts that need it most.
    event DebtWrittenOff(
        address indexed account,
        bytes32 indexed planRef,
        uint8 indexed payToken,
        uint periodsWrittenOff,
        uint writtenOffAt
    );
    event SubscriptionCancelled(address indexed account, bytes32 indexed planRef, uint cancelledAt);
    event SubscriptionRestored(address indexed account, bytes32 indexed planRef, uint restoredAt);
    event SubscriptionTerminated(
        address indexed account,
        bytes32 indexed planRef,
        address indexed terminator,
        uint terminatedAt
    );
    /// @dev A change that cost money and took effect immediately. `chargedUSD` is the pro-rata
    /// top-up, `requiredTokenAmount` what was actually transferred.
    event SubscriptionUpgraded(
        address indexed account,
        bytes32 indexed previous_planRef,
        bytes32 indexed new_planRef,
        uint8 payToken,
        uint newAmountUSD,
        uint32 newPeriod,
        uint chargedUSD,
        uint requiredTokenAmount,
        uint nextChargeableAt
    );
    /// @dev A change worth nothing or less was parked until the paid-up period runs out. No
    /// money moves here; SubscriptionDowngraded fires later when it actually lands.
    event DowngradeScheduled(
        address indexed account,
        bytes32 indexed current_planRef,
        bytes32 indexed new_planRef,
        uint newAmountUSD,
        uint32 newPeriod,
        uint effectiveAt
    );
    event ScheduledChangeCancelled(address indexed account, bytes32 indexed cancelled_planRef);
    event SubscriptionDowngraded(
        address indexed account,
        bytes32 indexed previous_planRef,
        bytes32 indexed new_planRef,
        uint newAmountUSD,
        uint32 newPeriod,
        uint downgradedAt
    );
    /// @dev Terms changed mid-trial. The trial belonged to the terms being left, so it ends
    /// there and then and a full period of the new terms is charged up front.
    event TrialEndedByChange(
        address indexed account,
        bytes32 indexed previous_planRef,
        bytes32 indexed new_planRef,
        uint8 payToken,
        uint newAmountUSD,
        uint32 newPeriod,
        uint chargedUSD,
        uint requiredTokenAmount,
        uint nextChargeableAt
    );
    /// @dev The referrer on record changed. Subscribed and TrialStarted carry the inviter too,
    /// but a re-subscribe that only clears arrears emits neither, so this is the one event that
    /// fires on every path that can change it.
    event InviterChanged(address indexed account, address indexed previous_inviter, address indexed new_inviter);
    /// @dev Emitted by renewBatch only when at least one account failed to be charged. Every
    /// other account in the batch was charged normally. Reasons are not captured; re-run
    /// renew(account) on a single address to surface the exact error.
    event RenewBatchFailed(address indexed caller, uint failedCount, address[] failedAccounts);

    event USDTAddressChanged(address indexed new_usdtAddress, uint8 usdtDecimals);
    event COAIAddressChanged(address indexed new_coaiAddress, uint8 coaiDecimals);
    event USDCAddressChanged(address indexed new_usdcAddress, uint8 usdcDecimals);
    event COAIPriceFeedAddressChanged(address indexed new_coaiPriceFeedAddress);
    event TwapIntervalChanged(uint32 new_twapInterval);
    event SwitchChanged(bool new_switch);
    event ReceiverChanged(address indexed new_receiver);
    event PendingOwnerChanged(address indexed new_pendingOwner);
    event OwnerChanged(address indexed previous_owner, address indexed new_owner);
    event DiscountChanged(uint8 indexed payToken, uint new_discount);
    event FeeCollectorChanged(address indexed new_feeCollector);
    event SubscriptionTerminatorChanged(address indexed new_subscriptionTerminator);
    event PeriodBoundsChanged(uint32 minPeriod, uint32 maxPeriod);
    event MaxTrialPeriodChanged(uint32 maxTrialSeconds);

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
    // payToken => discount numerator over DISCOUNT_BASE. Applies to what is transferred, not
    // to the committed amount: a $20 commitment paid in COAI at 900 moves $18 worth of COAI.
    mapping(uint8 => uint) private _discounts;
    // The only address allowed to call renew / renewBatch. Zero opens both to anyone -- see
    // onlyFeeCollector for why that is safe.
    address private _feeCollector;
    // May force-cancel any subscription, ignoring debt: the escape hatch for accounts that
    // can no longer pay and would otherwise accrue unsettleable debt forever.
    address private _subscriptionTerminator;
    // Sanity bounds on caller-supplied terms. Not business rules -- the backend judges the
    // terms -- just the range outside which nothing sensible can be meant.
    uint32 private _minPeriod;
    uint32 private _maxPeriod;
    uint32 private _maxTrial;
    // user => the terms they hold (amountUSD 0 = no subscription). Lingers after a cancelled
    // period has elapsed; isActive() is what reports real entitlement.
    mapping(address => Terms) private _terms;
    // user => the single parked end-of-period change (amountUSD 0 = none). Mutually exclusive
    // with _cancelled: both mean "something happens when this period ends".
    mapping(address => Terms) private _pending;
    // user => pay token chosen at the last subscribe. Decides the renewal currency.
    mapping(address => uint8) private _activePayToken;
    // user => next chargeable timestamp (0 = never subscribed; advanced by the account's own
    // period on each charge, anchored to the subscribe).
    mapping(address => uint) private _nextChargeableAt;
    // user => cancelled. Cancelling does not tear the subscription down: the account coasts
    // on the period it already paid for while renewals stop; restoreSubscription() clears the
    // flag inside that window, after it only a fresh subscribe brings the account back.
    mapping(address => bool) private _cancelled;
    // user => has ever held a subscription. The free trial is strictly a first-subscription
    // offer, so this one flag is the whole eligibility rule. Never cleared, not even by
    // terminateSubscription.
    mapping(address => bool) private _everSubscribed;
    // user => when their trial ends (0 = never had one). Only answers "mid-trial right now",
    // which decides whether a change of terms is free of pro-rating.
    mapping(address => uint) private _trialEndsAt;
    // user => referrer. Optional: zero records "no referrer". Cannot be the account itself.
    mapping(address => address) private _inviters;

    uint constant DISCOUNT_BASE = UsdPricing.DISCOUNT_BASE;
    uint constant DEFAULT_DISCOUNT_COAI = 900; // 10% off COAI payments by default
    // Caller-supplied amounts are capped well below any overflow: 1e9 USD per period leaves
    // the stablecoin conversion, the COAI conversion and a multi-period charge all far inside
    // uint256, with no reliance on the int256 bound _changeDeltaUSD needs.
    uint constant MAX_AMOUNT_USD = 1_000_000_000 * 10 ** UsdPricing.USD_DECIMALS;
    uint32 constant DEFAULT_MIN_PERIOD = 1 days;
    uint32 constant DEFAULT_MAX_PERIOD = 366 days;
    uint32 constant DEFAULT_MAX_TRIAL = 30 days;
    // PAY_TOKEN_* are stable identifiers; 0 is reserved for "unset / never subscribed".
    uint8 constant PAY_TOKEN_USDT = 1;
    uint8 constant PAY_TOKEN_COAI = 2;
    uint8 constant PAY_TOKEN_USDC = 3;

    uint32 constant TWAP_INTERVAL = 1800; // 30 minutes
    address constant DEFAULT_PANCAKE_COAI_POOL = 0x778121B464151FE5d931587c457E48FcAaA0dc7A;
    address constant DEFAULT_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant DEFAULT_COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant DEFAULT_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    /// @dev The implementation must never be initialized on its own; only the proxy holds
    /// state. Without this anyone could initialize it and drive an upgrade on it.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Runs once, through the proxy, in place of a constructor.
    /// @param feeCollector Who may call renew / renewBatch. Zero opens them to anyone.
    /// @param owner_ Holds every onlyOwner power, including the power to upgrade. Deploy a
    /// TimelockController separately and pass it here.
    function initialize(
        address receiver,
        address feeCollector,
        address subscriptionTerminator,
        address owner_
    ) public initializer {
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        if (receiver == address(0) || subscriptionTerminator == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidReceiver();
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
        _coaiIsToken0 = CoaiTwapPricing.resolveCoaiIsToken0(_coaiPriceFeed, DEFAULT_COAI);
        _receiver = receiver;
        emit ReceiverChanged(receiver);
        _owner = owner_;
        emit OwnerChanged(address(0), owner_);
        _switch = true;
        emit SwitchChanged(true);
        for (uint8 payToken = PAY_TOKEN_USDT; payToken <= PAY_TOKEN_USDC; payToken++) {
            uint discount = payToken == PAY_TOKEN_COAI ? DEFAULT_DISCOUNT_COAI : DISCOUNT_BASE;
            _discounts[payToken] = discount;
            emit DiscountChanged(payToken, discount);
        }
        _minPeriod = DEFAULT_MIN_PERIOD;
        _maxPeriod = DEFAULT_MAX_PERIOD;
        emit PeriodBoundsChanged(DEFAULT_MIN_PERIOD, DEFAULT_MAX_PERIOD);
        _maxTrial = DEFAULT_MAX_TRIAL;
        emit MaxTrialPeriodChanged(DEFAULT_MAX_TRIAL);
    }

    modifier onlyPendingOwner() {
        if (msg.sender != _pendingOwner) revert NotPendingOwner(_pendingOwner, msg.sender);
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner(_owner, msg.sender);
        _;
    }

    /// @dev Open when no collector is named. With _feeCollector at zero anyone may trigger a
    /// renewal, which is safe because the caller decides nothing: what is charged comes from
    /// the account's own terms and anchor, who pays is the account, who receives is _receiver,
    /// and the allowance is the account's own.
    modifier onlyFeeCollector() {
        address collector = _feeCollector;
        if (collector != address(0) && msg.sender != collector) revert NotFeeCollector(collector, msg.sender);
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

    // ---------------- subscriber entry points ----------------

    /// @notice Subscribe on the caller's own terms: `amountUSD` (USD * 10^8) every `period`
    /// seconds, paid in `payToken`. With `trialSeconds` > 0 nothing is charged now and the
    /// first charge lands at now + trialSeconds, provided this is the account's first
    /// subscription ever. `planRef` is passed through to the events untouched.
    /// @dev An account already subscribed may call this again only on the exact terms it
    /// holds, and only once due: that settles its arrears (DebtSettled, no Subscribed) and
    /// lets it switch pay token. A cancelled account whose paid-up period has run out starts
    /// afresh on whatever terms it brings.
    function subscribe(
        uint8 payToken,
        uint amountUSD,
        uint32 period,
        uint32 trialSeconds,
        bytes32 planRef,
        address inviter
    ) switchOn external nonReentrant {
        address sender = msg.sender;
        if (payToken != PAY_TOKEN_USDT && payToken != PAY_TOKEN_COAI && payToken != PAY_TOKEN_USDC) {
            revert UnknownPayToken(payToken);
        }
        _requireTermsInRange(amountUSD, period);
        if (trialSeconds > _maxTrial) revert TrialTooLong(trialSeconds, _maxTrial);
        _requireDue(sender, amountUSD, period, planRef);
        _recordInviter(sender, inviter);
        if (trialSeconds != 0) {
            if (_everSubscribed[sender]) revert TrialNotAvailable();
            // No price is read for a trial: nothing is charged, and a COAI trial must not
            // depend on the TWAP being available.
            _activate(sender, payToken, amountUSD, period, planRef, trialSeconds);
            emit TrialStarted(sender, payToken, planRef, amountUSD, period, trialSeconds, inviter, _nextChargeableAt[sender]);
            return;
        }
        // Arrears clear inside _activate and are charged there; nothing else is owed.
        if (_activate(sender, payToken, amountUSD, period, planRef, 0)) return;
        uint chargedUSD = _chargeOf(amountUSD, payToken);
        uint requiredTokenAmount = _tokenAmountOf(payToken, chargedUSD);
        emit Subscribed(sender, payToken, planRef, amountUSD, period, inviter, chargedUSD, requiredTokenAmount, _nextChargeableAt[sender]);
        _collect(payToken, sender, requiredTokenAmount);
    }

    function renew(address account) onlyFeeCollector external nonReentrant {
        _renew(account);
    }

    /// @notice Charge a batch of accounts, isolating failures instead of reverting the whole
    /// batch. A failed account's state is rolled back with its sub-call and can be retried.
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
        address[] memory failedAccounts = new address[](failedCount);
        for (uint i = 0; i < failedCount; i++) {
            failedAccounts[i] = buffer[i];
        }
        emit RenewBatchFailed(msg.sender, failedCount, failedAccounts);
    }

    /// @notice renewBatch's per-account trampoline. Callable ONLY by this contract, so it
    /// carries renewBatch's authorization and cannot be used to bypass it.
    /// @dev Deliberately NOT nonReentrant: it executes inside renewBatch's guard.
    function renewSelf(address account) external {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        _renew(account);
    }

    /// @notice Force-cancel `account`'s subscription without settling any debt. For accounts
    /// that can no longer pay, so their debt does not grow forever. Works while paused.
    function terminateSubscription(address account) onlySubscriptionTerminator external {
        bytes32 planRef = _terms[account].planRef;
        if (_terms[account].amountUSD == 0) revert NotSubscribed();
        delete _terms[account];
        delete _pending[account];
        delete _nextChargeableAt[account];
        delete _activePayToken[account];
        delete _trialEndsAt[account];
        delete _cancelled[account];
        emit SubscriptionTerminated(account, planRef, msg.sender, block.timestamp);
    }

    /// @notice Cancel the caller's subscription. The paid-up period runs to its end and no
    /// further renewal is charged; inside that window restoreSubscription() puts the same
    /// terms back at no cost. Arrears, if any, are written off rather than charged, so leaving
    /// never depends on balance, allowance or the COAI quote.
    function cancelSubscription() external nonReentrant {
        address sender = msg.sender;
        Terms memory terms = _terms[sender];
        if (terms.amountUSD == 0) revert NotSubscribed();
        if (_cancelled[sender]) revert AlreadyCancelled();
        uint periodsWrittenOff = _unpaidPeriods(sender);
        // Cancelling supersedes a parked downgrade; the event names the terms actually held.
        delete _pending[sender];
        _cancelled[sender] = true;
        emit SubscriptionCancelled(sender, terms.planRef, block.timestamp);
        if (periodsWrittenOff != 0) {
            emit DebtWrittenOff(sender, terms.planRef, _activePayToken[sender], periodsWrittenOff, block.timestamp);
        }
    }

    /// @notice Undo a cancellation while the paid-up period is still running. Free, and it
    /// keeps the terms, pay token and anchor. Reverts with SubscriptionExpired afterwards.
    function restoreSubscription() external nonReentrant {
        address sender = msg.sender;
        Terms memory terms = _terms[sender];
        if (terms.amountUSD == 0) revert NotSubscribed();
        if (!_cancelled[sender]) revert NotCancelled();
        uint next = _nextChargeableAt[sender];
        if (block.timestamp >= next) revert SubscriptionExpired(next);
        delete _cancelled[sender];
        emit SubscriptionRestored(sender, terms.planRef, block.timestamp);
    }

    /// @notice Move to new terms. The caller states them; the contract decides what that costs
    /// and when it happens:
    /// - mid-trial: the trial ends now and a full period of the new terms is charged
    /// - worth money (an upgrade): takes effect now and charges the pro-rata difference in the
    ///   account's pay token. The same period keeps the renewal date; a different one restarts
    ///   the cycle from now
    /// - worth nothing or less (a downgrade): parked until the paid-up period runs out, because
    ///   this contract holds no funds and so can never refund the difference
    /// Passing the terms already held clears a parked downgrade. previewChange() says which.
    function changeSubscription(uint amountUSD, uint32 period, bytes32 planRef) switchOn external nonReentrant {
        address sender = msg.sender;
        Terms memory current = _terms[sender];
        if (current.amountUSD == 0) revert NotSubscribed();
        if (_cancelled[sender]) revert AlreadyCancelled();
        if (_same(current, amountUSD, period, planRef)) {
            Terms memory pending = _pending[sender];
            if (pending.amountUSD == 0) revert NoScheduledChange();
            delete _pending[sender];
            emit ScheduledChangeCancelled(sender, pending.planRef);
            return;
        }
        _requireTermsInRange(amountUSD, period);
        Terms memory next_ = Terms(amountUSD, period, planRef);
        if (block.timestamp < _trialEndsAt[sender]) {
            _endTrialWithChange(sender, current, next_);
            return;
        }
        uint next = _nextChargeableAt[sender];
        // Pro-rating needs a period that is still running; in arrears the remaining time is
        // negative, so the caller squares up first.
        if (block.timestamp >= next) revert SettleDebtFirst(next);
        int delta = _changeDeltaUSD(sender, current, amountUSD, period, next);
        if (delta <= 0) {
            _pending[sender] = next_;
            emit DowngradeScheduled(sender, current.planRef, planRef, amountUSD, period, next);
            return;
        }
        _upgradeNow(sender, current, next_, next, uint(delta));
    }

    /// @notice Call off a parked downgrade and stay on the current terms.
    function cancelScheduledChange() external nonReentrant {
        address sender = msg.sender;
        Terms memory pending = _pending[sender];
        if (pending.amountUSD == 0) revert NoScheduledChange();
        delete _pending[sender];
        emit ScheduledChangeCancelled(sender, pending.planRef);
    }

    /// @notice What changeSubscription(amountUSD, period, planRef) would do for `account` right
    /// now, so a front end can say "pay X now" or "switches at the end of the period" first.
    /// @return immediate Whether it takes effect now or at the end of the paid-up period
    /// @return chargedUSD USD * 10^8 taken now; 0 when the change is parked
    /// @return requiredTokenAmount `chargedUSD` in the account's pay token
    /// @return effectiveAt When the new terms start applying
    function previewChange(address account, uint amountUSD, uint32 period, bytes32 planRef)
        external
        view
        returns (bool immediate, uint chargedUSD, uint requiredTokenAmount, uint effectiveAt)
    {
        Terms memory current = _terms[account];
        if (current.amountUSD == 0) revert NotSubscribed();
        if (_cancelled[account]) revert AlreadyCancelled();
        if (_same(current, amountUSD, period, planRef)) revert SameTerms();
        _requireTermsInRange(amountUSD, period);
        uint8 payToken = _activePayToken[account];
        if (block.timestamp < _trialEndsAt[account]) {
            chargedUSD = _chargeOf(amountUSD, payToken);
            return (true, chargedUSD, _tokenAmountOf(payToken, chargedUSD), block.timestamp);
        }
        uint next = _nextChargeableAt[account];
        if (block.timestamp >= next) revert SettleDebtFirst(next);
        int delta = _changeDeltaUSD(account, current, amountUSD, period, next);
        if (delta <= 0) return (false, 0, 0, next);
        chargedUSD = uint(delta);
        return (true, chargedUSD, _tokenAmountOf(payToken, chargedUSD), block.timestamp);
    }

    /// @notice Pay off the caller's own arrears, every period that has come due.
    function settleDebt() external nonReentrant {
        address sender = msg.sender;
        if (_terms[sender].amountUSD == 0) revert NotSubscribed();
        // A cancelled account is never charged again; its elapsed anchor marks the end of the
        // subscription, not a debt.
        if (_cancelled[sender]) revert AlreadyCancelled();
        uint next = _nextChargeableAt[sender];
        if (next == 0) revert NotSubscribed();
        if (block.timestamp < next) revert NoDebt();
        _settle(sender);
    }

    // ---------------- views ----------------

    function getSubscription(address account) external view returns (SubscriptionInfo memory info) {
        Terms memory terms = _terms[account];
        Terms memory pending = _pending[account];
        info.amountUSD = terms.amountUSD;
        info.period = terms.period;
        info.planRef = terms.planRef;
        info.payToken = _activePayToken[account];
        info.nextChargeableAt = _nextChargeableAt[account];
        info.cancelled = _cancelled[account];
        info.active = _isActive(account);
        info.trialEndsAt = _trialEndsAt[account];
        info.pendingAmountUSD = pending.amountUSD;
        info.pendingPeriod = pending.period;
        info.pendingPlanRef = pending.planRef;
    }

    /// @notice Whether `account` holds terms at all. Stays true after a cancelled period has
    /// elapsed; isActive is what reports entitlement.
    function isSubscribed(address account) external view returns (bool) {
        return _terms[account].amountUSD != 0;
    }

    /// @notice Whether `account` is entitled right now. False once a cancelled subscription's
    /// paid-up period has elapsed. This is what renew batches should be built from.
    function isActive(address account) external view returns (bool) {
        return _isActive(account);
    }

    function nextChargeableAt(address account) external view returns (uint) {
        return _nextChargeableAt[account];
    }

    function getActivePayToken(address account) external view returns (uint8) {
        return _activePayToken[account];
    }

    function isCancelled(address account) external view returns (bool) {
        return _cancelled[account];
    }

    /// @notice Whether restoreSubscription() would succeed for `account` right now.
    function canRestore(address account) external view returns (bool) {
        if (_terms[account].amountUSD == 0) return false;
        if (!_cancelled[account]) return false;
        return block.timestamp < _nextChargeableAt[account];
    }

    function isInTrial(address account) external view returns (bool) {
        return block.timestamp < _trialEndsAt[account];
    }

    function getTrialEndsAt(address account) external view returns (uint) {
        return _trialEndsAt[account];
    }

    /// @notice Whether `account` has ever held a subscription. Once true it can never start a
    /// free trial again, so a subscribe with trialSeconds > 0 would revert.
    function hasEverSubscribed(address account) external view returns (bool) {
        return _everSubscribed[account];
    }

    /// @notice Whether a subscribe by `account` with trialSeconds > 0 would be accepted.
    function startsTrial(address account) external view returns (bool) {
        return !_everSubscribed[account];
    }

    function getInviter(address account) external view returns (address) {
        return _inviters[account];
    }

    /// @notice One period of `account`'s subscription in its pay token, at today's quote.
    function getSubscriptionAmount(address account) external view returns (uint) {
        Terms memory terms = _terms[account];
        if (terms.amountUSD == 0) revert NotSubscribed();
        uint8 payToken = _activePayToken[account];
        return _tokenAmountOf(payToken, _chargeOf(terms.amountUSD, payToken));
    }

    /// @notice What `amountUSD` costs in `payToken` right now, discount applied. For the front
    /// end to show before a subscribe.
    function quoteTokenAmount(uint8 payToken, uint amountUSD) external view returns (uint) {
        return _tokenAmountOf(payToken, _chargeOf(amountUSD, payToken));
    }

    // ---------------- configuration ----------------

    function getFeeCollector() external view returns (address) {
        return _feeCollector;
    }

    /// @notice Name the collector, or pass address(0) to open renew and renewBatch to anyone.
    function setFeeCollector(address new_feeCollector) onlyOwner external {
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

    function getPeriodBounds() external view returns (uint32 minPeriod, uint32 maxPeriod) {
        return (_minPeriod, _maxPeriod);
    }

    /// @notice The range a subscribe or change may name as its period. Affects new terms only;
    /// accounts keep the period they hold.
    function setPeriodBounds(uint32 minPeriod, uint32 maxPeriod) onlyOwner external {
        if (minPeriod == 0 || minPeriod > maxPeriod) revert InvalidPeriodBounds();
        _minPeriod = minPeriod;
        _maxPeriod = maxPeriod;
        emit PeriodBoundsChanged(minPeriod, maxPeriod);
    }

    function getMaxTrialPeriod() external view returns (uint32) {
        return _maxTrial;
    }

    /// @notice The longest trial a subscribe may ask for. Zero switches trials off.
    function setMaxTrialPeriod(uint32 maxTrialSeconds) onlyOwner external {
        _maxTrial = maxTrialSeconds;
        emit MaxTrialPeriodChanged(maxTrialSeconds);
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
        if (new_coaiAddress == address(0) || new_coaiPriceFeedAddress == address(0)) revert ZeroAddress();
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
        _coaiIsToken0 = CoaiTwapPricing.resolveCoaiIsToken0(_coaiPriceFeed, address(_coai));
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

    // ---------------- billing internals ----------------

    /// @dev Zero is the "no subscription" sentinel, and the cap keeps every conversion and
    /// multi-period charge far inside uint256 whatever the caller names.
    function _requireTermsInRange(uint amountUSD, uint32 period) private view {
        if (amountUSD == 0 || amountUSD > MAX_AMOUNT_USD) revert AmountOutOfRange(amountUSD);
        if (period < _minPeriod || period > _maxPeriod) revert PeriodOutOfRange(period, _minPeriod, _maxPeriod);
    }

    function _same(Terms memory current, uint amountUSD, uint32 period, bytes32 planRef) private pure returns (bool) {
        return current.amountUSD == amountUSD && current.period == period && current.planRef == planRef;
    }

    /// @dev Optional referrer. Zero records "none"; the only rule is no self-referral. Every
    /// successful subscribe overwrites the stored value.
    function _recordInviter(address sender, address inviter) private {
        if (inviter == sender) revert InvalidInviter();
        address previous = _inviters[sender];
        if (previous == inviter) return;
        _inviters[sender] = inviter;
        emit InviterChanged(sender, previous, inviter);
    }

    /// @dev Gate for subscribe. An account may re-subscribe only on the terms it holds, and
    /// only once due -- that is how arrears get settled. New terms take changeSubscription, or
    /// cancelling and waiting the paid-up period out.
    function _requireDue(address account, uint amountUSD, uint32 period, bytes32 planRef) private view {
        Terms memory current = _terms[account];
        if (current.amountUSD == 0) return; // never subscribed, or terminated
        uint next = _nextChargeableAt[account];
        if (_cancelled[account]) {
            // The paid-up period must run out before any new subscription; inside the window
            // restoreSubscription is the way back.
            if (block.timestamp < next) revert NotDueYet(next);
            return;
        }
        // A parked downgrade is resolved by changeSubscription or cancelScheduledChange, never
        // by re-subscribing; keeping it out also guarantees _activate never meets one.
        if (_pending[account].amountUSD != 0) revert PendingChangeExists();
        if (!_same(current, amountUSD, period, planRef)) revert MustCancelFirst(current.amountUSD, current.period, current.planRef);
        if (block.timestamp < next) revert NotDueYet(next);
    }

    /// @return chargeHandled True when this call leaves the caller nothing to charge: a trial
    /// opened, or the account was in arrears and clearing them -- charged and reported by
    /// _settle -- was the whole of what it asked for.
    function _activate(
        address account,
        uint8 payToken,
        uint amountUSD,
        uint32 period,
        bytes32 planRef,
        uint32 trialSeconds
    ) private returns (bool chargeHandled) {
        if (_terms[account].amountUSD != 0) {
            if (_cancelled[account]) {
                // _requireDue confirmed the paid-up period ran out. Drop the anchor and the
                // flag so this is a brand-new subscription: the gap is never billed and the
                // new terms start from now.
                delete _nextChargeableAt[account];
                delete _cancelled[account];
                delete _pending[account];
            } else {
                // Active re-subscribe, admitted only once due, so the account is in arrears.
                // Settling them is exactly what was asked; charging a period on top would bill
                // twice. Arrears go out in the pay token held, later charges in the new one.
                if (_settleIfDebt(account)) {
                    _activePayToken[account] = payToken;
                    return true;
                }
                // Unreachable while _requireDue holds. If reached, charge normally below.
            }
        }
        _terms[account] = Terms(amountUSD, period, planRef);
        _activePayToken[account] = payToken;
        // Burns the one-off trial eligibility, whether or not this subscribe used it.
        _everSubscribed[account] = true;
        if (trialSeconds != 0) {
            // Anchoring at the trial's end means renew at that moment takes the first full
            // period and the schedule runs off that anchor; cancelling before it stops it.
            uint trialEndsAt = block.timestamp + trialSeconds;
            _nextChargeableAt[account] = trialEndsAt;
            _trialEndsAt[account] = trialEndsAt;
            return true;
        }
        uint next = _nextChargeableAt[account];
        _nextChargeableAt[account] = next == 0 ? block.timestamp + period : next + period;
        return false;
    }

    function _renew(address account) private {
        Terms memory terms = _terms[account];
        if (terms.amountUSD == 0) revert NotSubscribed();
        // Cancelled accounts coast on their paid-up period and are never charged again. Build
        // batches from isActive rather than rely on this revert.
        if (_cancelled[account]) revert AlreadyCancelled();
        uint next = _nextChargeableAt[account];
        if (next == 0) revert NotSubscribed();
        if (block.timestamp < next) revert NotDueYet(next);
        // The paid-up period is over, so a parked downgrade lands now and everything charged
        // below is already at the new terms.
        terms = _applyPendingChange(account, terms);
        uint8 payToken = _activePayToken[account];
        // Anchor-based: every period elapsed since the anchor is owed.
        uint periodsCharged = (block.timestamp - next) / terms.period + 1;
        _nextChargeableAt[account] = next + periodsCharged * terms.period;
        uint requiredTokenAmount = _tokenAmountOf(payToken, _chargeOf(terms.amountUSD, payToken)) * periodsCharged;
        emit Renewed(account, payToken, terms.planRef, terms.amountUSD, requiredTokenAmount, periodsCharged, block.timestamp);
        _collect(payToken, account, requiredTokenAmount);
    }

    /// @dev Periods that have come due and gone unpaid; 0 when paid up. Reads only, so a
    /// caller giving the debt up cannot fail on the way to reporting it.
    function _unpaidPeriods(address account) private view returns (uint) {
        uint next = _nextChargeableAt[account];
        if (next == 0 || block.timestamp < next) return 0;
        uint32 period = _terms[account].period;
        if (period == 0) return 0;
        return (block.timestamp - next) / period + 1;
    }

    function _settleIfDebt(address account) private returns (bool settled) {
        uint next = _nextChargeableAt[account];
        if (next == 0 || block.timestamp < next) return false;
        _settle(account);
        return true;
    }

    /// @dev Caller has verified the anchor is set and in the past.
    function _settle(address account) private {
        uint next = _nextChargeableAt[account];
        Terms memory terms = _applyPendingChange(account, _terms[account]);
        uint periodsCharged = (block.timestamp - next) / terms.period + 1;
        _nextChargeableAt[account] = next + periodsCharged * terms.period;
        uint8 payToken = _activePayToken[account];
        uint requiredTokenAmount = _tokenAmountOf(payToken, _chargeOf(terms.amountUSD, payToken)) * periodsCharged;
        emit DebtSettled(account, payToken, terms.planRef, terms.amountUSD, requiredTokenAmount, periodsCharged, block.timestamp);
        _collect(payToken, account, requiredTokenAmount);
    }

    /// @dev What moving from `current` to (amountUSD, period) is worth in USD * 10^8, positive
    /// when the caller owes money. Both sides are valued after the pay token's discount.
    ///   same period      -> (newPrice - oldPrice) * remaining / period, renewal date kept
    ///   different period -> newPrice - oldPrice * remaining / period, a whole new cycle is
    ///                       bought and the old one's unused tail credited against it
    function _changeDeltaUSD(address account, Terms memory current, uint amountUSD, uint32 period, uint next)
        private
        view
        returns (int)
    {
        uint8 payToken = _activePayToken[account];
        uint remaining = next - block.timestamp; // caller guarantees next > block.timestamp
        int oldPrice = int(_chargeOf(current.amountUSD, payToken));
        int newPrice = int(_chargeOf(amountUSD, payToken));
        if (period == current.period) {
            return (newPrice - oldPrice) * int(remaining) / int(uint(current.period));
        }
        return newPrice - oldPrice * int(remaining) / int(uint(current.period));
    }

    /// @dev Swap the terms now and collect `chargedUSD`. The same period keeps the renewal
    /// date; a different one restarts the cycle from now.
    function _upgradeNow(address account, Terms memory current, Terms memory next_, uint next, uint chargedUSD) private {
        uint8 payToken = _activePayToken[account];
        uint requiredTokenAmount = _tokenAmountOf(payToken, chargedUSD);
        uint newNext = next_.period == current.period ? next : block.timestamp + next_.period;
        // Paying to move up supersedes any parked downgrade.
        delete _pending[account];
        _terms[account] = next_;
        _nextChargeableAt[account] = newNext;
        emit SubscriptionUpgraded(
            account, current.planRef, next_.planRef, payToken, next_.amountUSD, next_.period, chargedUSD, requiredTokenAmount, newNext
        );
        _collect(payToken, account, requiredTokenAmount);
    }

    /// @dev Leave a running trial for other terms: the trial ends now and a full period of the
    /// new terms is charged, so the cycle restarts from this moment.
    function _endTrialWithChange(address account, Terms memory current, Terms memory next_) private {
        uint8 payToken = _activePayToken[account];
        uint chargedUSD = _chargeOf(next_.amountUSD, payToken);
        uint requiredTokenAmount = _tokenAmountOf(payToken, chargedUSD);
        uint newNext = block.timestamp + next_.period;
        delete _pending[account];
        delete _trialEndsAt[account];
        _terms[account] = next_;
        _nextChargeableAt[account] = newNext;
        emit TrialEndedByChange(
            account, current.planRef, next_.planRef, payToken, next_.amountUSD, next_.period, chargedUSD, requiredTokenAmount, newNext
        );
        _collect(payToken, account, requiredTokenAmount);
    }

    /// @dev Land a parked downgrade. Called once the paid-up period is over, so the charge
    /// that follows is already at the new terms. Arrears are billed wholly at the new terms:
    /// the account asked to move down from the anchor onward, and a late collector should not
    /// make that cost more.
    function _applyPendingChange(address account, Terms memory terms) private returns (Terms memory) {
        Terms memory pending = _pending[account];
        if (pending.amountUSD == 0) return terms;
        delete _pending[account];
        _terms[account] = pending;
        emit SubscriptionDowngraded(account, terms.planRef, pending.planRef, pending.amountUSD, pending.period, block.timestamp);
        return pending;
    }

    function _isActive(address account) private view returns (bool) {
        if (_terms[account].amountUSD == 0) return false;
        if (_cancelled[account] && block.timestamp >= _nextChargeableAt[account]) return false;
        return true;
    }

    function _chargeOf(uint amountUSD, uint8 payToken) private view returns (uint) {
        return UsdPricing.applyDiscount(amountUSD, _discounts[payToken]);
    }

    function _tokenAmountOf(uint8 payToken, uint rawAmount) private view returns (uint) {
        if (payToken == PAY_TOKEN_USDT) return UsdPricing.toStableAmount(rawAmount, _usdtDecimals);
        if (payToken == PAY_TOKEN_COAI) {
            return CoaiTwapPricing.toCoaiAmount(_coaiPriceFeed, _twapInterval, _coaiIsToken0, _coaiDecimals, rawAmount);
        }
        if (payToken == PAY_TOKEN_USDC) return UsdPricing.toStableAmount(rawAmount, _usdcDecimals);
        revert UnknownPayToken(payToken);
    }

    function _collect(uint8 payToken, address from, uint amount) private {
        if (payToken == PAY_TOKEN_USDT) _usdt.safeTransferFrom(from, _receiver, amount);
        else if (payToken == PAY_TOKEN_COAI) _coai.safeTransferFrom(from, _receiver, amount);
        else if (payToken == PAY_TOKEN_USDC) _usdc.safeTransferFrom(from, _receiver, amount);
        else revert UnknownPayToken(payToken);
    }

    // ---------------- upgradeability ----------------

    /// @dev Only the owner may replace the implementation. An upgrade can change ANY logic
    /// here, including where the tokens users have approved end up: strictly more power than
    /// every setter put together.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice The implementation currently behind the proxy.
    function getImplementation() external view returns (address impl) {
        // ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assembly { impl := sload(slot) }
    }

    uint256[40] private __gap;
}

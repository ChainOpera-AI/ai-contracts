// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./lib/IPancakeV3PoolState.sol";
import "./lib/TickMath.sol";

contract Subscription is ReentrancyGuard {
    using SafeERC20 for ERC20;
    error TWAPNotAvailable();
    error SwitchOff();
    error InvalidTwapInterval();
    error UnsupportedDecimals();
    error CoaiNotInPool();
    error InvalidSubscriptionType(uint subscriptionType);
    error InvalidDiscount();
    error NotFeeCollector(address feeCollector, address caller);
    error NotSubscriptionTerminator(address subscriptionTerminator, address caller);
    error NotDueYet(uint nextChargeableAt);
    error NotSubscribed();
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

    event SubscribedUSDT(
        address indexed account,
        uint indexed subscriptionType,
        uint amount,
        uint requiredUSDTAmount
    );
    event SubscribedCOAI(
        address indexed account,
        uint indexed subscriptionType,
        uint amount,
        uint requiredCOAIAmount
    );
    event SubscribedUSDC(
        address indexed account,
        uint indexed subscriptionType,
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
    uint constant DISCOUNT_BASE = 1000;
    uint constant DEFAULT_DISCOUNT_COAI = 700; // 30% off, applied only to COAI payments by default
    uint32 constant PERIOD_MONTH = 30 days;
    uint32 constant PERIOD_YEAR = 365 days;
    // PAY_TOKEN_USDT/COAI/USDC values are stable identifiers; 0 reserved for "unset/never subscribed".
    uint8 constant PAY_TOKEN_USDT = 1;
    uint8 constant PAY_TOKEN_COAI = 2;
    uint8 constant PAY_TOKEN_USDC = 3;

    // rawAmount uses Chainlink-style fixed-point USD: USD * 1e8 (e.g. $19.99 -> 1_999_000_000)
    uint8 constant USD_DECIMALS = 8;
    uint32 constant TWAP_INTERVAL = 1800; // 30 minutes
    address constant DEFAULT_PANCAKE_COAI_POOL = 0x778121B464151FE5d931587c457E48FcAaA0dc7A;
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
        _coaiIsToken0 = _resolveCoaiIsToken0(IPancakeV3PoolState(DEFAULT_PANCAKE_COAI_POOL), DEFAULT_COAI);
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

    function subscriptionUSDT(uint subscriptionType) switchOn external nonReentrant {
        _subscriptionUSDT(subscriptionType);
    }

    function subscriptionCOAI(uint subscriptionType) switchOn external nonReentrant {
        _subscriptionCOAI(subscriptionType);
    }

    function subscriptionUSDC(uint subscriptionType) switchOn external nonReentrant {
        _subscriptionUSDC(subscriptionType);
    }

    function renew(address account) onlyFeeCollector external nonReentrant {
        _renew(account);
    }

    function renewBatch(address[] calldata accounts) onlyFeeCollector external nonReentrant {
        for (uint i = 0; i < accounts.length; i++) {
            _renew(accounts[i]);
        }
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
        emit SubscriptionTerminated(account, subscriptionType, msg.sender, block.timestamp);
    }

    function cancelSubscription() external nonReentrant {
        address sender = msg.sender;
        uint subscriptionType = _activeType[sender];
        if (subscriptionType == 0) revert NotSubscribed();
        // If the caller is in debt, auto-settle so users always exit fully paid up
        // without needing a separate settleDebt tx first.
        _settleIfDebt(sender, subscriptionType);
        delete _nextChargeableAt[sender][subscriptionType];
        delete _activeType[sender];
        delete _activePayToken[sender];
        emit SubscriptionCancelled(sender, subscriptionType, block.timestamp);
    }

    function settleDebt() external nonReentrant {
        address sender = msg.sender;
        uint subscriptionType = _activeType[sender];
        if (subscriptionType == 0) revert NotSubscribed();
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

    function setSubscriptionPeriod(uint subscriptionType, uint32 periodSeconds) onlyOwner external {
        // type 0 is the "unset / never subscribed" sentinel in _activeType.
        // Zero period would brick renew/settle/_requireDue for existing subscribers — use
        // delistSubscription to stop new sign-ups instead.
        if (subscriptionType == 0) revert InvalidSubscriptionType(0);
        if (periodSeconds == 0) revert UnknownPeriod();
        _subscriptionPeriods[subscriptionType] = periodSeconds;
        emit SubscriptionPeriodChanged(subscriptionType, periodSeconds);
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

    function getActiveType(address account) external view returns (uint) {
        return _activeType[account];
    }

    function getActivePayToken(address account) external view returns (uint8) {
        return _activePayToken[account];
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
        return _isCoaiTwapHealthy();
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
        _coaiIsToken0 = _resolveCoaiIsToken0(_coaiPriceFeed, new_coaiAddress);
        emit COAIAddressChanged(new_coaiAddress, dec);
        emit COAIPriceFeedAddressChanged(new_coaiPriceFeedAddress);
    }

    function getCOAIPriceFeedAddress() external view returns (address) {
        return address(_coaiPriceFeed);
    }

    function setCOAIPriceFeedAddress(address new_coaiPriceFeedAddress) onlyOwner external {
        if (new_coaiPriceFeedAddress == address(0)) revert ZeroAddress();
        _coaiPriceFeed = IPancakeV3PoolState(new_coaiPriceFeedAddress);
        _coaiIsToken0 = _resolveCoaiIsToken0(IPancakeV3PoolState(new_coaiPriceFeedAddress), address(_coai));
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

    function _subscriptionUSDT(uint subscriptionType) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        uint price = _priceOf(subscriptionType, PAY_TOKEN_USDT);
        uint requiredUSDTAmount = _calculateAmountUSDT(price);
        _activate(sender, subscriptionType, PAY_TOKEN_USDT);
        emit SubscribedUSDT(sender, subscriptionType, price, requiredUSDTAmount);
        _usdt.safeTransferFrom(sender, _receiver, requiredUSDTAmount);
    }

    function _subscriptionCOAI(uint subscriptionType) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        uint price = _priceOf(subscriptionType, PAY_TOKEN_COAI);
        uint requiredCOAIAmount = _calculateAmountCOAI(price);
        _activate(sender, subscriptionType, PAY_TOKEN_COAI);
        emit SubscribedCOAI(sender, subscriptionType, price, requiredCOAIAmount);
        _coai.safeTransferFrom(sender, _receiver, requiredCOAIAmount);
    }

    function _subscriptionUSDC(uint subscriptionType) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        uint price = _priceOf(subscriptionType, PAY_TOKEN_USDC);
        uint requiredUSDCAmount = _calculateAmountUSDC(price);
        _activate(sender, subscriptionType, PAY_TOKEN_USDC);
        emit SubscribedUSDC(sender, subscriptionType, price, requiredUSDCAmount);
        _usdc.safeTransferFrom(sender, _receiver, requiredUSDCAmount);
    }

    function _renew(address account) private {
        uint subscriptionType = _activeType[account];
        if (subscriptionType == 0) revert NotSubscribed();
        uint next = _nextChargeableAt[account][subscriptionType];
        if (next == 0) revert NotSubscribed();
        uint32 period = _subscriptionPeriods[subscriptionType];
        if (period == 0) revert UnknownPeriod();
        if (block.timestamp < next) revert NotDueYet(next);
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

    function _requireDue(address account, uint subscriptionType) private view {
        // Only block NEW subscriptions for delisted types — existing subscribers can still
        // renew, settle, and cancel even after delist.
        if (!_subscriptionListed[subscriptionType]) revert NotListed(subscriptionType);
        uint32 period = _subscriptionPeriods[subscriptionType];
        if (period == 0) revert UnknownPeriod();
        uint next = _nextChargeableAt[account][subscriptionType];
        if (next != 0 && block.timestamp < next) revert NotDueYet(next);
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
        uint32 period = _subscriptionPeriods[subscriptionType];
        if (period == 0) revert UnknownPeriod();
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

    function _activate(address account, uint subscriptionType, uint8 payToken) private {
        uint previous = _activeType[account];
        if (previous != 0) {
            // Auto-settle any outstanding debt on the previous type so the caller cannot
            // walk away from / switch out of unpaid periods. Charges in the previous
            // pay token; the new type's first period is charged separately by the caller.
            _settleIfDebt(account, previous);
            if (previous != subscriptionType) {
                delete _nextChargeableAt[account][previous];
                emit SubscriptionSwitched(account, previous, subscriptionType);
            }
        }
        _activeType[account] = subscriptionType;
        _activePayToken[account] = payToken;
        uint32 period = _subscriptionPeriods[subscriptionType];
        uint next = _nextChargeableAt[account][subscriptionType];
        // First subscribe (or post-cancel/switch fresh start): anchor at now + period.
        // Existing anchor (same-type resubscribe before fee collector renews): advance by one period.
        _nextChargeableAt[account][subscriptionType] = next == 0 ? block.timestamp + period : next + period;
    }

    function _calculateAmountUSDT(uint rawAmount) private view returns (uint) {
        // rawAmount in USD * 10^USD_DECIMALS -> token amount in USDT wei (USDT pegged 1:1 to USD)
        return rawAmount * (10 ** _usdtDecimals) / (10 ** USD_DECIMALS);
    }

    function _calculateAmountUSDC(uint rawAmount) private view returns (uint) {
        // rawAmount in USD * 10^USD_DECIMALS -> token amount in USDC wei (USDC pegged 1:1 to USD)
        return rawAmount * (10 ** _usdcDecimals) / (10 ** USD_DECIMALS);
    }

    function _calculateAmountCOAI(uint rawAmount) private view returns (uint) {
        // PancakeV3 pool with COAI paired against a USD-stable quote (both 18 decimals; COAI enforced).
        // sqrtPriceX96 = sqrt(token1_wei / token0_wei) * 2^96. We compute the COAI amount in wei
        // using Math.mulDiv (512-bit intermediates) so this works across the full price range
        // without overflow (extreme-price token1 path) or silent truncation-to-zero (very small
        // sqrtPriceX96). Same precision/safety pattern as Uniswap V3 OracleLibrary.getQuoteAtTick.
        uint160 sqrtPriceX96 = _getCoaiTwapSqrtPriceX96();
        if (sqrtPriceX96 == 0) revert TWAPNotAvailable();

        // baseAmount = quote-token wei equivalent of rawAmount USD (assumes 18-dec USD-stable quote).
        uint baseAmount = rawAmount * (10 ** (_coaiDecimals - USD_DECIMALS));

        // COAI is token0  =>  USDT is token1  =>  coaiAmount = baseAmount / (token1/token0)
        // COAI is token1  =>  USDT is token0  =>  coaiAmount = baseAmount * (token1/token0)
        if (sqrtPriceX96 <= type(uint128).max) {
            // Square fits in uint256 directly (Q192 ratio).
            uint ratioX192 = uint(sqrtPriceX96) * sqrtPriceX96;
            return _coaiIsToken0
                ? Math.mulDiv(1 << 192, baseAmount, ratioX192)
                : Math.mulDiv(ratioX192, baseAmount, 1 << 192);
        } else {
            // sqrtPriceX96^2 would overflow uint256; scale down by 2^64 first (Q128 ratio).
            uint ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            return _coaiIsToken0
                ? Math.mulDiv(1 << 128, baseAmount, ratioX128)
                : Math.mulDiv(ratioX128, baseAmount, 1 << 128);
        }
    }

    function _priceOf(uint subscriptionType, uint8 payToken) private view returns (uint) {
        uint price = _subscriptionPrices[subscriptionType];
        if (price == 0) revert InvalidSubscriptionType(subscriptionType);
        return price * _discounts[payToken] / DISCOUNT_BASE;
    }

    function _resolveCoaiIsToken0(IPancakeV3PoolState pool, address coai) private view returns (bool) {
        address t0 = pool.token0();
        if (t0 == coai) return true;
        if (pool.token1() == coai) return false;
        revert CoaiNotInPool();
    }

    function _getCoaiTwapSqrtPriceX96() private view returns (uint160) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _twapInterval;
        secondsAgos[1] = 0;
        try _coaiPriceFeed.observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            // Promote to int256 before subtracting so the diff cannot overflow int56 as
            // pool cumulatives drift toward their bounds over years of accumulation.
            int256 tickDelta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
            int256 interval = int256(uint256(_twapInterval));
            int256 rawAvgTick = tickDelta / interval;
            // First bound to int24 range so the narrowing cast below is lossless.
            if (rawAvgTick < int256(TickMath.MIN_TICK) || rawAvgTick > int256(TickMath.MAX_TICK)) revert TWAPNotAvailable();
            int24 avgTick = int24(rawAvgTick);
            if (tickDelta < 0 && (tickDelta % interval != 0)) avgTick--;
            // Re-check AFTER the floor correction. At the lower boundary the decrement
            // can push avgTick to MIN_TICK-1, which would make getSqrtRatioAtTick revert
            // with TickOutOfRange — and that revert sits inside the try-success block, so
            // it would NOT be caught by `catch` below and would leak out instead of the
            // intended TWAPNotAvailable. Mirrors the final clamp in _isCoaiTwapHealthy.
            if (avgTick < TickMath.MIN_TICK || avgTick > TickMath.MAX_TICK) revert TWAPNotAvailable();
            return TickMath.getSqrtRatioAtTick(avgTick);
        } catch {
            revert TWAPNotAvailable();
        }
    }

    function _isCoaiTwapHealthy() private view returns (bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _twapInterval;
        secondsAgos[1] = 0;
        try _coaiPriceFeed.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int256 tickDelta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
            int256 interval = int256(uint256(_twapInterval));
            int256 rawAvgTick = tickDelta / interval;
            if (rawAvgTick < int256(TickMath.MIN_TICK) || rawAvgTick > int256(TickMath.MAX_TICK)) return false;
            int24 avgTick = int24(rawAvgTick);
            // Same floor correction as _getCoaiTwapSqrtPriceX96; without it the health check
            // can return true while the price path reverts (avgTick falls below MIN_TICK).
            if (tickDelta < 0 && (tickDelta % interval != 0)) avgTick--;
            return avgTick >= TickMath.MIN_TICK && avgTick <= TickMath.MAX_TICK;
        } catch {
            return false;
        }
    }
}

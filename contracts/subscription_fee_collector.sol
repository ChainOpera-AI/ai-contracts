// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
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
    error NotDueYet(uint nextChargeableAt);
    error NotSubscribed();
    error UnknownPeriod();
    error UnknownPayToken(uint8 payToken);
    error UnsettledDebt(uint nextChargeableAt);
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
    event USDTAddressChanged(
        address indexed new_usdtAddress,
        uint8 usdtDecimals
    );
    event COAIAddressChanged(
        address indexed new_coaiAddress,
        uint8 coaiDecimals
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
        uint new_discount
    );
    event FeeCollectorChanged(
        address indexed new_feeCollector
    );
    event SubscriptionPeriodChanged(
        uint indexed subscriptionType,
        uint32 new_periodSeconds
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
        uint8 indexed payToken, // 1 = USDT, 2 = COAI
        uint price,
        uint requiredTokenAmount,
        uint periodsCharged,
        uint chargedAt
    );

    ERC20 private _usdt;
    uint8 private _usdtDecimals;
    ERC20 private _coai;
    uint8 private _coaiDecimals;
    IPancakeV3PoolState private _coaiPriceFeed;
    bool private _coaiIsToken0;
    uint32 private _twapInterval;
    address private _owner;
    address private _pendingOwner;
    address private _receiver;
    bool private _switch;
    // subscriptionType => price in USD * 10^USD_DECIMALS (0 = inactive/undefined)
    mapping(uint => uint) private _subscriptionPrices;
    // discount numerator, denominator = DISCOUNT_BASE. e.g. 700 / 1000 = 30% off
    uint private _discount;
    address private _feeCollector;
    // subscriptionType => recurring period in seconds (0 = non-recurring/undefined)
    mapping(uint => uint32) private _subscriptionPeriods;
    // user => subscriptionType => next chargeable timestamp (0 = never subscribed; advanced by period on each charge, anchored to initial subscribe)
    mapping(address => mapping(uint => uint)) private _nextChargeableAt;
    // user => currently active subscriptionType (0 = none). Only one active subscription per user.
    mapping(address => uint) private _activeType;
    // user => payToken used at last subscribe (PAY_TOKEN_USDT / _COAI). Determines renew currency.
    mapping(address => uint8) private _activePayToken;

    // subscriptionType id constants
    uint constant SUB_TYPE_PLUS_MONTH = 1;
    uint constant SUB_TYPE_PRO_MONTH  = 2;
    uint constant SUB_TYPE_PLUS_YEAR  = 3;
    uint constant SUB_TYPE_PRO_YEAR   = 4;

    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_MONTH = 1999000000;
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PRO_MONTH  = 19999000000;
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_YEAR  = 19188000000;
    uint constant DEFAULT_SUBSCRIPTION_AMOUNT_PRO_YEAR   = 191988000000;
    uint constant DISCOUNT_BASE = 1000;
    uint constant DEFAULT_DISCOUNT = 700; // 30% off
    uint32 constant PERIOD_MONTH = 30 days;
    uint32 constant PERIOD_YEAR = 365 days;
    // PAY_TOKEN_USDT/COAI values are stable identifiers; 0 reserved for "unset/never subscribed".
    uint8 constant PAY_TOKEN_USDT = 1;
    uint8 constant PAY_TOKEN_COAI = 2;

    uint constant RATE = 2**96;
    // rawAmount uses Chainlink-style fixed-point USD: USD * 1e8 (e.g. $19.99 -> 1_999_000_000)
    uint8 constant USD_DECIMALS = 8;
    // sqrt(10**18); used to downscale sqrtPriceX96 before squaring to avoid uint256 overflow.
    // Tied to COAI/quote both having 18 decimals — enforced in constructor and setCOAIAddress.
    uint constant SQRT_PRICE_SCALE = 1e9;
    uint32 constant TWAP_INTERVAL = 1800; // 30 minutes
    address constant DEFAULT_PANCAKE_COAI_POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;
    address constant DEFAULT_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant DEFAULT_COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;

    constructor(address receiver, address feeCollector, uint minDelay, address[] memory proposers, address[] memory executors, address admin) {
        if (receiver == address(0) || feeCollector == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidReceiver();
        _feeCollector = feeCollector;
        emit FeeCollectorChanged(feeCollector);
        _twapInterval = TWAP_INTERVAL;
        _usdt = ERC20(DEFAULT_USDT);
        _usdtDecimals = ERC20(DEFAULT_USDT).decimals();
        _coai = ERC20(DEFAULT_COAI);
        _coaiDecimals = ERC20(DEFAULT_COAI).decimals();
        if (_coaiDecimals != 18) revert UnsupportedDecimals();
        _coaiPriceFeed = IPancakeV3PoolState(DEFAULT_PANCAKE_COAI_POOL);
        _coaiIsToken0 = _resolveCoaiIsToken0(IPancakeV3PoolState(DEFAULT_PANCAKE_COAI_POOL), DEFAULT_COAI);
        _receiver = receiver;
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, admin);
        _owner = address(timelock);
        _switch = true;
        _subscriptionPrices[SUB_TYPE_PLUS_MONTH] = DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_MONTH;
        _subscriptionPrices[SUB_TYPE_PRO_MONTH]  = DEFAULT_SUBSCRIPTION_AMOUNT_PRO_MONTH;
        _subscriptionPrices[SUB_TYPE_PLUS_YEAR]  = DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_YEAR;
        _subscriptionPrices[SUB_TYPE_PRO_YEAR]   = DEFAULT_SUBSCRIPTION_AMOUNT_PRO_YEAR;
        emit SubscriptionPriceChanged(SUB_TYPE_PLUS_MONTH, DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_MONTH);
        emit SubscriptionPriceChanged(SUB_TYPE_PRO_MONTH,  DEFAULT_SUBSCRIPTION_AMOUNT_PRO_MONTH);
        emit SubscriptionPriceChanged(SUB_TYPE_PLUS_YEAR,  DEFAULT_SUBSCRIPTION_AMOUNT_PLUS_YEAR);
        emit SubscriptionPriceChanged(SUB_TYPE_PRO_YEAR,   DEFAULT_SUBSCRIPTION_AMOUNT_PRO_YEAR);
        _discount = DEFAULT_DISCOUNT;
        emit DiscountChanged(DEFAULT_DISCOUNT);
        _subscriptionPeriods[SUB_TYPE_PLUS_MONTH] = PERIOD_MONTH;
        _subscriptionPeriods[SUB_TYPE_PRO_MONTH]  = PERIOD_MONTH;
        _subscriptionPeriods[SUB_TYPE_PLUS_YEAR]  = PERIOD_YEAR;
        _subscriptionPeriods[SUB_TYPE_PRO_YEAR]   = PERIOD_YEAR;
        emit SubscriptionPeriodChanged(SUB_TYPE_PLUS_MONTH, PERIOD_MONTH);
        emit SubscriptionPeriodChanged(SUB_TYPE_PRO_MONTH,  PERIOD_MONTH);
        emit SubscriptionPeriodChanged(SUB_TYPE_PLUS_YEAR,  PERIOD_YEAR);
        emit SubscriptionPeriodChanged(SUB_TYPE_PRO_YEAR,   PERIOD_YEAR);
    }

    function subscriptionUSDT(uint subscriptionType) switchOn external nonReentrant {
        _subscriptionUSDT(subscriptionType);
    }

    function subscriptionCOAI(uint subscriptionType) switchOn external nonReentrant {
        _subscriptionCOAI(subscriptionType);
    }

    function renew(address account) switchOn onlyFeeCollector external nonReentrant {
        _renew(account);
    }

    function cancelSubscription() switchOn external {
        address sender = msg.sender;
        uint subscriptionType = _activeType[sender];
        if (subscriptionType == 0) revert NotSubscribed();
        _requireSettled(sender, subscriptionType);
        delete _nextChargeableAt[sender][subscriptionType];
        delete _activeType[sender];
        delete _activePayToken[sender];
        emit SubscriptionCancelled(sender, subscriptionType, block.timestamp);
    }

    function settleDebt() switchOn external nonReentrant {
        address sender = msg.sender;
        uint subscriptionType = _activeType[sender];
        if (subscriptionType == 0) revert NotSubscribed();
        uint next = _nextChargeableAt[sender][subscriptionType];
        if (next == 0) revert NotSubscribed();
        uint32 period = _subscriptionPeriods[subscriptionType];
        if (period == 0) revert UnknownPeriod();
        if (block.timestamp < next) revert NoDebt();
        uint periodsCharged = (block.timestamp - next) / period + 1;
        _nextChargeableAt[sender][subscriptionType] = next + periodsCharged * period;
        uint price = _priceOf(subscriptionType);
        uint8 payToken = _activePayToken[sender];
        uint requiredTokenAmount;
        if (payToken == PAY_TOKEN_USDT) {
            requiredTokenAmount = _calculateAmountUSDT(price) * periodsCharged;
            emit DebtSettled(sender, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _usdt.safeTransferFrom(sender, _receiver, requiredTokenAmount);
        } else if (payToken == PAY_TOKEN_COAI) {
            requiredTokenAmount = _calculateAmountCOAI(price) * periodsCharged;
            emit DebtSettled(sender, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _coai.safeTransferFrom(sender, _receiver, requiredTokenAmount);
        } else {
            revert UnknownPayToken(payToken);
        }
    }

    function getFeeCollector() external view returns (address) {
        return _feeCollector;
    }

    function setFeeCollector(address new_feeCollector) onlyOwner external {
        if (new_feeCollector == address(0)) revert ZeroAddress();
        _feeCollector = new_feeCollector;
        emit FeeCollectorChanged(new_feeCollector);
    }

    function getSubscriptionPeriod(uint subscriptionType) external view returns (uint32) {
        return _subscriptionPeriods[subscriptionType];
    }

    function setSubscriptionPeriod(uint subscriptionType, uint32 periodSeconds) onlyOwner external {
        _subscriptionPeriods[subscriptionType] = periodSeconds;
        emit SubscriptionPeriodChanged(subscriptionType, periodSeconds);
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
        return _calculateAmountUSDT(_priceOf(subscriptionType));
    }

    function getSubscriptionAmountCOAI(uint subscriptionType) external view returns (uint) {
        return _calculateAmountCOAI(_priceOf(subscriptionType));
    }

    function getSubscriptionPrice(uint subscriptionType) external view returns (uint) {
        return _subscriptionPrices[subscriptionType];
    }

    function setSubscriptionPrice(uint subscriptionType, uint price) onlyOwner external {
        _subscriptionPrices[subscriptionType] = price;
        emit SubscriptionPriceChanged(subscriptionType, price);
    }

    function getDiscount() external view returns (uint) {
        return _discount;
    }

    function setDiscount(uint new_discount) onlyOwner external {
        if (new_discount == 0 || new_discount > DISCOUNT_BASE) revert InvalidDiscount();
        _discount = new_discount;
        emit DiscountChanged(new_discount);
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
        if (new_owner == address(0)) revert ZeroAddress();
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

    modifier switchOn() {
        if (!_switch) revert SwitchOff();
        _;
    }

    function _subscriptionUSDT(uint subscriptionType) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        uint price = _priceOf(subscriptionType);
        uint requiredUSDTAmount = _calculateAmountUSDT(price);
        _activate(sender, subscriptionType, PAY_TOKEN_USDT);
        emit SubscribedUSDT(sender, subscriptionType, price, requiredUSDTAmount);
        _usdt.safeTransferFrom(sender, _receiver, requiredUSDTAmount);
    }

    function _subscriptionCOAI(uint subscriptionType) private {
        address sender = msg.sender;
        _requireDue(sender, subscriptionType);
        uint price = _priceOf(subscriptionType);
        uint requiredCOAIAmount = _calculateAmountCOAI(price);
        _activate(sender, subscriptionType, PAY_TOKEN_COAI);
        emit SubscribedCOAI(sender, subscriptionType, price, requiredCOAIAmount);
        _coai.safeTransferFrom(sender, _receiver, requiredCOAIAmount);
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
        uint price = _priceOf(subscriptionType);
        uint requiredTokenAmount;
        if (payToken == PAY_TOKEN_USDT) {
            requiredTokenAmount = _calculateAmountUSDT(price) * periodsCharged;
            emit Renewed(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _usdt.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else if (payToken == PAY_TOKEN_COAI) {
            requiredTokenAmount = _calculateAmountCOAI(price) * periodsCharged;
            emit Renewed(account, subscriptionType, payToken, price, requiredTokenAmount, periodsCharged, block.timestamp);
            _coai.safeTransferFrom(account, _receiver, requiredTokenAmount);
        } else {
            revert UnknownPayToken(payToken);
        }
    }

    function _requireDue(address account, uint subscriptionType) private view {
        uint32 period = _subscriptionPeriods[subscriptionType];
        if (period == 0) revert UnknownPeriod();
        uint next = _nextChargeableAt[account][subscriptionType];
        if (next != 0 && block.timestamp < next) revert NotDueYet(next);
    }

    function _requireSettled(address account, uint subscriptionType) private view {
        uint next = _nextChargeableAt[account][subscriptionType];
        if (next != 0 && block.timestamp >= next) revert UnsettledDebt(next);
    }

    function _activate(address account, uint subscriptionType, uint8 payToken) private {
        uint previous = _activeType[account];
        if (previous != 0) {
            _requireSettled(account, previous);
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
        // rawAmount in USD * 10^USD_DECIMALS -> token amount in USDT wei
        return rawAmount * (10 ** _usdtDecimals) / (10 ** USD_DECIMALS);
    }

    function _calculateAmountCOAI(uint rawAmount) private view returns (uint) {
        // PancakeV3 pool with COAI paired against a USD-stable quote (both 18 decimals; COAI enforced).
        // sqrtPriceX96 is sqrt(token1 / token0) * 2^96.
        // If COAI is token0: price = sqrtPriceX96^2 / 2^192 = quote-per-COAI.
        // If COAI is token1: price = 2^192 / sqrtPriceX96^2 = quote-per-COAI (inverted).
        // Downscale sqrtPriceX96 by sqrt(10^coaiDec) / 2^96 = SQRT_PRICE_SCALE/RATE to avoid overflow on squaring.
        uint160 sqrtPriceX96 = _getCoaiTwapSqrtPriceX96();
        uint sqrtPrice = uint(sqrtPriceX96) * SQRT_PRICE_SCALE / RATE;
        uint numerator = rawAmount * (10 ** _coaiDecimals) * (10 ** (_coaiDecimals - USD_DECIMALS));
        if (_coaiIsToken0) {
            // coaiAmount = numerator / sqrtPrice^2
            return numerator / sqrtPrice / sqrtPrice;
        } else {
            // coaiAmount = numerator * sqrtPrice^2 / 10^(2*coaiDec)
            // (sqrtPrice^2 has implicit 10^coaiDec scaling factor; divide it out twice via 10^coaiDec each)
            return numerator * sqrtPrice / (10 ** _coaiDecimals) * sqrtPrice / (10 ** _coaiDecimals);
        }
    }

    function _priceOf(uint subscriptionType) private view returns (uint) {
        uint price = _subscriptionPrices[subscriptionType];
        if (price == 0) revert InvalidSubscriptionType(subscriptionType);
        return price * _discount / DISCOUNT_BASE;
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
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int56 rawAvgTick = tickDelta / int56(uint56(_twapInterval));
            if (rawAvgTick < int56(TickMath.MIN_TICK) || rawAvgTick > int56(TickMath.MAX_TICK)) revert TWAPNotAvailable();
            int24 avgTick = int24(rawAvgTick);
            if (tickDelta < 0 && (tickDelta % int56(uint56(_twapInterval)) != 0)) avgTick--;
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
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int56 rawAvgTick = tickDelta / int56(uint56(_twapInterval));
            if (rawAvgTick < int56(TickMath.MIN_TICK) || rawAvgTick > int56(TickMath.MAX_TICK)) return false;
            int24 avgTick = int24(rawAvgTick);
            // Same floor correction as _getCoaiTwapSqrtPriceX96; without it the health check
            // can return true while the price path reverts (avgTick falls below MIN_TICK).
            if (tickDelta < 0 && (tickDelta % int56(uint56(_twapInterval)) != 0)) avgTick--;
            return avgTick >= TickMath.MIN_TICK && avgTick <= TickMath.MAX_TICK;
        } catch {
            return false;
        }
    }
}

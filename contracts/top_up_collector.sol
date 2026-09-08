// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "./lib/IPancakeV3PoolState.sol";
import "./lib/CoaiTwapPricing.sol";
import "./lib/UsdPricing.sol";

/// @title One-way account top-ups, priced in USD and paid in USDT / COAI / USDC.
/// @notice Each call buys one fixed-size credit (default $10) and forwards the tokens straight
/// to `_receiver`. The contract never holds funds and has no withdraw or refund path — top-ups
/// are deliberately one-way. Users top up as many times as they like; the credit itself is
/// tracked off-chain from the ToppedUpXXX events, with a running per-account total kept here so
/// it stays verifiable on-chain.
contract TopUp is ReentrancyGuard {
    using SafeERC20 for ERC20;
    error SwitchOff();
    error InvalidTwapInterval();
    error UnsupportedDecimals();
    error InvalidDiscount();
    error InvalidTopUpAmount();
    error UnknownPayToken(uint8 payToken);
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

    event ToppedUpUSDT(
        address indexed account,
        uint creditAmount,
        uint chargedAmount,
        uint requiredUSDTAmount
    );
    event ToppedUpCOAI(
        address indexed account,
        uint creditAmount,
        uint chargedAmount,
        uint requiredCOAIAmount
    );
    event ToppedUpUSDC(
        address indexed account,
        uint creditAmount,
        uint chargedAmount,
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
    event TopUpAmountChanged(
        uint new_topUpAmount
    );
    event DiscountChanged(
        uint8 indexed payToken,
        uint new_discount
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
    // Face value of one top-up in USD * 10^USD_DECIMALS. This is the credit the user buys;
    // what they actually pay is this times the pay token's discount.
    uint private _topUpAmount;
    // payToken => discount numerator, denominator = DISCOUNT_BASE. e.g. 700 / 1000 = 30% off
    mapping(uint8 => uint) private _discounts;
    // user => lifetime credit bought, in USD * 10^USD_DECIMALS. Accumulates face value, not the
    // discounted amount paid, so it reads as "how much credit this account has ever purchased".
    mapping(address => uint) private _totalToppedUp;

    uint constant DEFAULT_TOP_UP_AMOUNT = 1000000000; // $10
    // Defined by UsdPricing; aliased so the many call sites below stay readable.
    uint constant DISCOUNT_BASE = UsdPricing.DISCOUNT_BASE;
    uint constant DEFAULT_DISCOUNT_COAI = 900; // 10% off, applied only to COAI payments by default
    // PAY_TOKEN_USDT/COAI/USDC values are stable identifiers; 0 is reserved for "unset".
    uint8 constant PAY_TOKEN_USDT = 1;
    uint8 constant PAY_TOKEN_COAI = 2;
    uint8 constant PAY_TOKEN_USDC = 3;
    uint32 constant TWAP_INTERVAL = 1800; // 30 minutes
    address constant DEFAULT_PANCAKE_COAI_POOL = 0xbc0E5A205D729299D93973d634E2507CD8b625A3;
    address constant DEFAULT_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant DEFAULT_COAI = 0x0A8D6C86e1bcE73fE4D0bD531e1a567306836EA5;
    address constant DEFAULT_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    constructor(address receiver, uint minDelay, address[] memory proposers, address[] memory executors, address admin) {
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidReceiver();
        // admin holds TIMELOCK_ADMIN_ROLE and can grant/revoke proposer/executor roles
        // without the delay, defeating the timelock — must be zero, the timelock self-administers.
        if (admin != address(0)) revert InvalidTimelockConfig();
        // Empty proposers/executors would deadlock the timelock and leave the contract
        // unable to ever execute onlyOwner mutations.
        if (proposers.length == 0 || executors.length == 0) revert InvalidTimelockConfig();
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
        emit ReceiverChanged(receiver);
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, admin);
        _owner = address(timelock);
        emit OwnerChanged(address(0), _owner);
        _switch = true;
        _topUpAmount = DEFAULT_TOP_UP_AMOUNT;
        emit TopUpAmountChanged(DEFAULT_TOP_UP_AMOUNT);
        _discounts[PAY_TOKEN_USDT] = DISCOUNT_BASE; // no discount for USDT
        _discounts[PAY_TOKEN_COAI] = DEFAULT_DISCOUNT_COAI;
        _discounts[PAY_TOKEN_USDC] = DISCOUNT_BASE; // no discount for USDC
        emit DiscountChanged(PAY_TOKEN_USDT, DISCOUNT_BASE);
        emit DiscountChanged(PAY_TOKEN_COAI, DEFAULT_DISCOUNT_COAI);
        emit DiscountChanged(PAY_TOKEN_USDC, DISCOUNT_BASE);
    }

    function topUpUSDT() switchOn external nonReentrant {
        _topUpUSDT();
    }

    function topUpCOAI() switchOn external nonReentrant {
        _topUpCOAI();
    }

    function topUpUSDC() switchOn external nonReentrant {
        _topUpUSDC();
    }

    function getTopUpAmount() external view returns (uint) {
        return _topUpAmount;
    }

    /// @notice Set the face value of one top-up, in USD * 10^USD_DECIMALS ($10 -> 1_000_000_000).
    function setTopUpAmount(uint new_topUpAmount) onlyOwner external {
        // A zero amount would hand out free credit.
        if (new_topUpAmount == 0) revert InvalidTopUpAmount();
        _topUpAmount = new_topUpAmount;
        emit TopUpAmountChanged(new_topUpAmount);
    }

    /// @notice Token amount one top-up currently costs. Quote these right before sending the
    /// transaction: the COAI figure moves with the pool's TWAP.
    function getTopUpAmountUSDT() external view returns (uint) {
        return _calculateAmountUSDT(_priceOf(PAY_TOKEN_USDT));
    }

    function getTopUpAmountCOAI() external view returns (uint) {
        return _calculateAmountCOAI(_priceOf(PAY_TOKEN_COAI));
    }

    function getTopUpAmountUSDC() external view returns (uint) {
        return _calculateAmountUSDC(_priceOf(PAY_TOKEN_USDC));
    }

    /// @notice Lifetime credit `account` has bought, in USD * 10^USD_DECIMALS.
    function getTotalToppedUp(address account) external view returns (uint) {
        return _totalToppedUp[account];
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
        // Funds are forwarded straight through; this contract must never be the destination
        // because it has no way to move tokens back out.
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

    modifier switchOn() {
        if (!_switch) revert SwitchOff();
        _;
    }

    function _topUpUSDT() private {
        address sender = msg.sender;
        uint creditAmount = _topUpAmount;
        uint chargedAmount = _priceOf(PAY_TOKEN_USDT);
        uint requiredUSDTAmount = _calculateAmountUSDT(chargedAmount);
        _totalToppedUp[sender] += creditAmount;
        emit ToppedUpUSDT(sender, creditAmount, chargedAmount, requiredUSDTAmount);
        _usdt.safeTransferFrom(sender, _receiver, requiredUSDTAmount);
    }

    function _topUpCOAI() private {
        address sender = msg.sender;
        uint creditAmount = _topUpAmount;
        uint chargedAmount = _priceOf(PAY_TOKEN_COAI);
        uint requiredCOAIAmount = _calculateAmountCOAI(chargedAmount);
        _totalToppedUp[sender] += creditAmount;
        emit ToppedUpCOAI(sender, creditAmount, chargedAmount, requiredCOAIAmount);
        _coai.safeTransferFrom(sender, _receiver, requiredCOAIAmount);
    }

    function _topUpUSDC() private {
        address sender = msg.sender;
        uint creditAmount = _topUpAmount;
        uint chargedAmount = _priceOf(PAY_TOKEN_USDC);
        uint requiredUSDCAmount = _calculateAmountUSDC(chargedAmount);
        _totalToppedUp[sender] += creditAmount;
        emit ToppedUpUSDC(sender, creditAmount, chargedAmount, requiredUSDCAmount);
        _usdc.safeTransferFrom(sender, _receiver, requiredUSDCAmount);
    }

    function _priceOf(uint8 payToken) private view returns (uint) {
        return UsdPricing.applyDiscount(_topUpAmount, _discounts[payToken]);
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

}

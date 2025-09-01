// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract CheckIn is ReentrancyGuard {
    using Address for address payable;
    error SwitchOff();
    error NotOwner(
        address owner,
        address caller
    );
    error NotPendingOwner(
        address pendingOwner,
        address caller
    );
    error ZeroAddress();
    error InvalidValue(
        uint required,
        uint actual
    );
    error InvalidPrice(
        int price,
        uint updatedAt
    );

    event CheckedIn(
        address indexed account,
        uint amount,
        uint remains
    );
    event CheckedInUSDT(
        address indexed account,
        uint amount
    );
    event USDTAddressChanged(
        address indexed new_usdtAddress
    );
    event PriceFeedAddressChanged(
        address indexed new_priceFeedAddress
    );
    event ActionValuesChanged(
        uint new_checkInAmount,
        uint new_feederHealthLimit
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
        address indexed new_owner
    );

    ERC20 private _usdt;
    AggregatorV3Interface private _priceFeed;
    uint private _checkInAmount;
    uint private _feederHealthLimit;
    address private _owner;
    address private _pendingOwner;
    address payable private _receiver;
    bool private _switch;

    uint constant DEFAULT_CHECKIN_AMOUNT = 3333333;
    uint constant DEFAULT_CHAINLINK_FEEDER_HEALTH_LIMIT = 1 days;
    address constant DEFAULT_CHAINLINK_FEEDER = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address constant DEFAULT_USDT = 0x55d398326f99059fF775485246999027B3197955;

    constructor(address receiver, uint minDelay, address[] memory proposers, address[] memory executors, address admin) {
        if (receiver == address(0)) revert ZeroAddress();
        _checkInAmount = DEFAULT_CHECKIN_AMOUNT;
        _feederHealthLimit = DEFAULT_CHAINLINK_FEEDER_HEALTH_LIMIT;
        _usdt = ERC20(DEFAULT_USDT);
        _priceFeed = AggregatorV3Interface(DEFAULT_CHAINLINK_FEEDER);
        _receiver = payable(receiver);
        TimelockController timelock = new TimelockController(minDelay, proposers, executors, admin);
        _owner = address(timelock);
        _switch = true;
    }

    function checkIn() switchOn payable external nonReentrant {
        address sender = msg.sender;
        uint value = msg.value;
        uint requiredAmount = getCheckInAmount();
        if (value < requiredAmount) revert InvalidValue(requiredAmount, value);
        uint remains = value - requiredAmount;
        emit CheckedIn(sender, requiredAmount, remains);
        _receiver.sendValue(requiredAmount);
        if (remains > 0) payable(sender).sendValue(remains);
    }

    function checkInUSDT() switchOn external nonReentrant {
        address sender = msg.sender;
        uint amount = getCheckInAmountUSDT();
        emit CheckedInUSDT(sender, amount);
        _usdt.transferFrom(sender, _receiver, amount);
    }

    function getCheckInAmount() public view returns (uint) {
        return _calculateAmount(_checkInAmount);
    }

    function getCheckInAmountUSDT() public view returns (uint) {
        return _calculateAmountUSDT(_checkInAmount);
    }

    function getPriceFeedHealth() external view returns (bool) {
        (, int price, , uint updatedAt, ) = _priceFeed.latestRoundData();
        return _isPriceFeedHealthy(price, updatedAt);
    }

    function getUSDTAddress() external view returns (address) {
        return address(_usdt);
    }

    function setUSDTAddress(address new_usdtAddress) onlyOwner external {
        if (new_usdtAddress == address(0)) revert ZeroAddress();
        _usdt = ERC20(new_usdtAddress);
        emit USDTAddressChanged(new_usdtAddress);
    }

    function getPriceFeedAddress() external view returns (address) {
        return address(_priceFeed);
    }

    function setPriceFeedAddress(address new_priceFeedAddress) onlyOwner external {
        if (new_priceFeedAddress == address(0)) revert ZeroAddress();
        _priceFeed = AggregatorV3Interface(new_priceFeedAddress);
        emit PriceFeedAddressChanged(new_priceFeedAddress);
    }

    function getActionValues() external view returns (uint[2] memory) {
        return [_checkInAmount, _feederHealthLimit];
    }

    function setActionValues(uint[2] calldata new_actionValues) onlyOwner external {
        _checkInAmount = new_actionValues[0];
        _feederHealthLimit = new_actionValues[1];
        emit ActionValuesChanged(new_actionValues[0], new_actionValues[1]);
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
        _receiver = payable(new_receiver);
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
        _owner = _pendingOwner;
        _pendingOwner = address(0);
        emit OwnerChanged(_owner);
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

    function _calculateAmount(uint rawAmount) private view returns (uint) {
        (, int price, , uint updatedAt, ) = _priceFeed.latestRoundData();
        if (!_isPriceFeedHealthy(price, updatedAt)) revert InvalidPrice(price, updatedAt);
        uint8 decimals = _priceFeed.decimals();
        return rawAmount * 10**(10+decimals) / uint(price);
    }

    function _calculateAmountUSDT(uint rawAmount) private view returns (uint) {
        return rawAmount * (10 ** _usdt.decimals()) / 1e8;
    }

    function _isPriceFeedHealthy(int price, uint updatedAt) private view returns (bool) {
        return price > 0 && updatedAt >= block.timestamp - _feederHealthLimit;
    }
}
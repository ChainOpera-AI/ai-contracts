// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./lib/IPancakeV3PoolState.sol";

contract CheckIn {
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
        uint new_checkIn_amount
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
    IPancakeV3PoolState private _priceFeed;
    uint private _checkIn_amount;
    address private _owner;
    address private _pendingOwner;
    address payable private _receiver;
    bool private _switch;

    uint constant DEFAULT_CHECKIN_AMOUNT = 3333333;
    uint constant RATE = 2**96;
    address constant DEFAULT_PANCAKE_POOL = 0xc4f981189558682F15F60513158B699354B30204;
    address constant DEFAULT_USDT = 0x9e5AAC1Ba1a2e6aEd6b32689DFcF62A509Ca96f3;

    constructor(address owner, address receiver) {
        if (owner == address(0) || receiver == address(0)) revert ZeroAddress();
        _checkIn_amount = DEFAULT_CHECKIN_AMOUNT;
        _usdt = ERC20(DEFAULT_USDT);
        _priceFeed = IPancakeV3PoolState(DEFAULT_PANCAKE_POOL);
        _receiver = payable(receiver);
        _owner = owner;
        _switch = true;
    }

    function checkIn() switchOn payable external {
        address sender = msg.sender;
        uint value = msg.value;
        uint requiredAmount = getCheckInAmount();
        if (value < requiredAmount) revert InvalidValue(requiredAmount, value);
        uint remains = value - requiredAmount;
        emit CheckedIn(sender, requiredAmount, remains);
        _receiver.transfer(requiredAmount);
        if (remains > 0) payable(sender).transfer(remains);
    }

    function checkInUSDT() switchOn external {
        address sender = msg.sender;
        uint amount = getCheckInAmountUSDT();
        emit CheckedInUSDT(sender, amount);
        _usdt.transferFrom(sender, _receiver, amount);
    }

    function getCheckInAmount() public view returns (uint) {
        return _calculateAmount(_checkIn_amount);
    }

    function getCheckInAmountUSDT() public view returns (uint) {
        return _calculateAmountUSDT(_checkIn_amount);
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
        _priceFeed = IPancakeV3PoolState(new_priceFeedAddress);
        emit PriceFeedAddressChanged(new_priceFeedAddress);
    }

    function getActionValues() external view returns (uint[1] memory) {
        return [_checkIn_amount];
    }

    function setActionValues(uint[1] calldata new_actionValues) onlyOwner external {
        _checkIn_amount = new_actionValues[0];
        emit ActionValuesChanged(new_actionValues[0]);
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
        if(!_switch) revert SwitchOff();
        _;
    }

    function _calculateAmount(uint rawAmount) private view returns (uint) {
        (uint160 sqrtPriceX96, , , , , , ) = _priceFeed.slot0();
        uint256 sqrtPrice = uint256(sqrtPriceX96) * 1e4 / RATE;
        return rawAmount * 1e18 / sqrtPrice / sqrtPrice;
    }

    function _calculateAmountUSDT(uint rawAmount) private view returns (uint) {
        return rawAmount * (10 ** _usdt.decimals()) / 1e8;
    }
}
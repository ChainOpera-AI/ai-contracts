// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

contract PromptRecord {
    error NotOwner(
        address owner,
        address caller
    );
    error NotPendingOwner(
        address pendingOwner,
        address caller
    );
    error ZeroAddress();
    error InvalidIndex(
        uint length,
        uint index
    );
    error ArrayLengthNotEqual(
        uint accounts,
        uint timestamps,
        uint promptSizes
    );

    struct Prompt{
        address account;
        uint timestamp;
        uint promptSize;
    }

    event PromptRecorded(
        address indexed account,
        uint indexed timestamp,
        uint promptSize
    );
    event PendingOwnerChanged(
        address indexed new_pendingOwner
    );
    event OwnerChanged(
        address indexed new_owner
    );

    mapping(address=>mapping(uint => uint[])) private _prompts;
    address private _owner;
    address private _pendingOwner;

    constructor(address owner) {
        if (owner == address(0)) revert ZeroAddress();
        _owner = owner;
    }

    function recordBatch(address[] calldata accounts, uint[] calldata timestamps, uint[] calldata promptSizes) onlyOwner external {
        if (accounts.length != timestamps.length || accounts.length != promptSizes.length) {
            revert ArrayLengthNotEqual(accounts.length, timestamps.length, promptSizes.length);
        }
        for (uint i = 0; i < accounts.length; i++) {
            _record(accounts[i], timestamps[i], promptSizes[i]);
        }
    }

    function record(address account, uint timestamp, uint promptSize) onlyOwner external {
        _record(account, timestamp, promptSize);
    }

    function havePrompts(address account, uint timestamp) external view returns (bool) {
        return _prompts[account][timestamp].length > 0;
    }

    function getPrompts(address account, uint timestamp) external view returns (Prompt[] memory) {
        uint[] storage data = _prompts[account][timestamp];
        Prompt[] memory result = new Prompt[](data.length);
        for (uint i = 0; i < data.length; i++) {
            result[i] = Prompt(account, timestamp, data[i]);
        }
        return result;
    }

    function getPromptNum(address account, uint timestamp) external view returns (uint) {
        return _prompts[account][timestamp].length;
    }

    function getPrompt(address account, uint timestamp, uint index) external view returns (Prompt memory) {
        uint[] storage data = _prompts[account][timestamp];
        if (index >= data.length) revert InvalidIndex(data.length, index);
        return Prompt(account, timestamp, data[index]);
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

    function _record(address account, uint timestamp, uint promptSize) private {
        _prompts[account][timestamp].push(promptSize);
        emit PromptRecorded(account, timestamp, promptSize);
    }
}
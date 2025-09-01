// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

contract AgentRecord {
    error NotOwner(
        address owner,
        address caller
    );
    error NotPendingOwner(
        address pendingOwner,
        address caller
    );
    error ZeroAddress();
    error ZeroNameLength();
    error AgentAlreadyExists(
        uint id
    );
    error ArrayLengthNotEqual(
        uint ids,
        uint creators,
        uint names,
        uint datas
    );

    struct Agent{
        uint id;
        address creator;
        uint height;
        uint timestamp;
        string name;
        bytes[] data;
    }

    event AgentRecorded(
        uint indexed id,
        address indexed creator,
        uint indexed height,
        uint timestamp,
        string name,
        bytes[] data
    );
    event PendingOwnerChanged(
        address indexed new_pendingOwner
    );
    event OwnerChanged(
        address indexed new_owner
    );

    mapping(uint => Agent) private _agents;
    address private _owner;
    address private _pendingOwner;

    constructor(address owner) {
        if (owner == address(0)) revert ZeroAddress();
        _owner = owner;
    }

    function recordBatch(uint[] calldata ids, address[] calldata creators, string[] calldata names, bytes[][] calldata datas) onlyOwner external {
        if (ids.length != creators.length || ids.length != names.length || ids.length != datas.length) {
            revert ArrayLengthNotEqual(ids.length, creators.length, names.length, datas.length);
        }
        for (uint i = 0; i < ids.length; i++) {
            _record(ids[i], creators[i], names[i], datas[i]);
        }
    }

    function record(uint id, string calldata name, bytes[] calldata data) external {
        _record(id, msg.sender, name, data);
    }

    function agentExist(uint id) external view returns (bool) {
        return _agents[id].creator != address(0);
    }

    function getAgent(uint id) external view returns (Agent memory) {
        return _agents[id];
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

    function _record(
        uint id,
        address creator,
        string calldata name,
        bytes[] calldata data
    ) private {
        if (creator == address(0)) revert ZeroAddress();
        if (bytes(name).length == 0) revert ZeroNameLength();
        if (_agents[id].creator != address(0)) revert AgentAlreadyExists(id);
        uint height = block.number;
        uint timestamp = block.timestamp;
        _agents[id] = Agent(id, creator, height, timestamp, name, data);
        emit AgentRecorded(id, creator, height, timestamp, name, data);
    }
}
// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

contract SwitchRecord {
    error InvalidAddress();
    error Propose2Self(
        address from
    );
    error InvalidConfirmer(
        address confirmer,
        address sender
    );
    error AlreadySwitched(
        address from
    );

    event Proposed(
        address indexed from,
        address indexed to
    );
    event Confirmed(
        address indexed from,
        address indexed to
    );

    mapping(address => address) private _pendingRecord;
    mapping(address => address) private _switchedRecord;
    mapping(address => bool) private _haveSwitched;

    function propose(address to) notSwitched(msg.sender) external {
        if (to == address(0)) revert InvalidAddress();
        address sender = msg.sender;
        if (to == msg.sender) revert Propose2Self(sender);
        _pendingRecord[sender] = to;
        emit Proposed(sender, to);
    }

    function confirm(address from) onlyConfirmer(from) external {
        address sender = msg.sender;
        delete _pendingRecord[from];
        _switchedRecord[from] = sender;
        _haveSwitched[from] = true;
        emit Confirmed(from, sender);
    }

    function pendingRecord(address from) external view returns (address) {
        return _pendingRecord[from];
    }

    function switchedRecord(address from) external view returns (address) {
        return _switchedRecord[from];
    }

    function haveSwitched(address from) external view returns (bool) {
        return _haveSwitched[from];
    }

    modifier onlyConfirmer(address from) {
        address sender = msg.sender;
        address confirmer = _pendingRecord[from];
        if (sender != confirmer) revert InvalidConfirmer(confirmer, sender);
        _;
    }

    modifier notSwitched(address from) {
        if (_haveSwitched[from]) revert AlreadySwitched(from);
        _;
    }
}
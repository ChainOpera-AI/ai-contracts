// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract AgentMemberRecord is ReentrancyGuard {
    using Address for address payable;
    error SwitchOff();
    error NotSameLength();
    error ZeroGrade();
    error InvalidGrade();
    error GradeNotAvailable();
    error AlreadyMember();
    error NotMember();
    error InvalidGradeMemberLimit();
    error ZeroGradeAmount();
    error NotOwner(
        address owner,
        address caller
    );
    error NotRecorder(
        address recorder,
        address caller
    );
    error NotPendingOwner(
        address pendingOwner,
        address caller
    );
    error ZeroAddress();
    error InvalidInput();
    error InvalidValue(
        uint required,
        uint actual
    );
    error InvalidPrice(
        int price,
        uint updatedAt
    );

    struct AgentMembership{
        uint grade;
        uint startTimestamp;
        uint endTimestamp;
    }

    event AgentMembershipBought(
        address indexed account,
        uint indexed grade,
        uint requiredAmount,
        uint remains
    );
    event AgentMembershipBoughtUSDT(
        address indexed account,
        uint indexed grade,
        uint amount
    );
    event AgentMembershipAddedByRecorder(
        address[] accounts,
        uint[] grades,
        uint[] startTimestamps,
        uint[] endTimestamps
    );
    event AgentMembershipRemovedByRecorder(
        address[] accounts
    );
    event USDTAddressChanged(
        address indexed new_usdtAddress
    );
    event PriceFeedAddressChanged(
        address indexed new_priceFeedAddress
    );
    event GradeAmountChanged(
        uint indexed grade,
        uint indexed oldAmount,
        uint indexed newAmount
    );
    event GradeMemberLimitChanged(
        uint indexed grade,
        uint indexed oldLimit,
        uint indexed newLimit
    );
    event GradeDurationChanged(
        uint indexed grade,
        uint indexed oldDuration,
        uint indexed newDuration
    );
    event ActionValuesChanged(
        uint new_feederHealthLimit
    );
    event SwitchChanged(
        bool new_switch
    );
    event ReceiverChanged(
        address indexed new_receiver
    );
    event RecorderChanged(
        address indexed new_recorder
    );
    event PendingOwnerChanged(
        address indexed new_pendingOwner
    );
    event OwnerChanged(
        address indexed new_owner
    );

    mapping(address=>AgentMembership) private _agentMemberships;
    mapping(uint=>uint) private _gradeAmounts;
    mapping(uint=>uint) private _gradeMemberLimits;
    mapping(uint=>uint) private _gradeDurations;
    mapping(uint=>uint) private _gradeMemberCounts;
    ERC20 private _usdt;
    AggregatorV3Interface private _priceFeed;
    uint private _feederHealthLimit;
    address private _owner;
    address private _pendingOwner;
    address payable private _receiver;
    address private _recorder;
    bool private _switch;

    //PROD START
    uint constant GRADE_1_AMOUNT = 9900000000;
    uint constant GRADE_2_AMOUNT = 99900000000;
    uint constant GRADE_3_AMOUNT = 499900000000;
    uint constant GRADE_4_AMOUNT = 1499900000000;

    uint constant GRADE_1_DURATION = 365 days;
    uint constant GRADE_2_DURATION = 365 days;
    uint constant GRADE_3_DURATION = 365 days;
    uint constant GRADE_4_DURATION = 365 days;
    //PROD END

    //DEBUG START
    //uint constant GRADE_1_AMOUNT = 99;
    //uint constant GRADE_2_AMOUNT = 999;
    //uint constant GRADE_3_AMOUNT = 4999;
    //uint constant GRADE_4_AMOUNT = 14999;

    //uint constant GRADE_1_DURATION = 1 hours;
    //uint constant GRADE_2_DURATION = 1 hours;
    //uint constant GRADE_3_DURATION = 1 hours;
    //uint constant GRADE_4_DURATION = 1 hours;
    //DEBUG END

    uint constant GRADE_1_LIMIT = 10000;
    uint constant GRADE_2_LIMIT = 1000;
    uint constant GRADE_3_LIMIT = 100;
    uint constant GRADE_4_LIMIT = 10;
    uint constant DEFAULT_CHAINLINK_FEEDER_HEALTH_LIMIT = 1 days;
    address constant DEFAULT_CHAINLINK_FEEDER = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address constant DEFAULT_USDT = 0x55d398326f99059fF775485246999027B3197955;

    constructor(address payable receiver, address owner, address recorder) {
        if (receiver == address(0) || owner == address(0) || recorder == address(0)) revert ZeroAddress();
        _gradeAmounts[1] = GRADE_1_AMOUNT;
        _gradeAmounts[2] = GRADE_2_AMOUNT;
        _gradeAmounts[3] = GRADE_3_AMOUNT;
        _gradeAmounts[4] = GRADE_4_AMOUNT;
        _gradeMemberLimits[1] = GRADE_1_LIMIT;
        _gradeMemberLimits[2] = GRADE_2_LIMIT;
        _gradeMemberLimits[3] = GRADE_3_LIMIT;
        _gradeMemberLimits[4] = GRADE_4_LIMIT;
        _gradeDurations[1] = GRADE_1_DURATION;
        _gradeDurations[2] = GRADE_2_DURATION;
        _gradeDurations[3] = GRADE_3_DURATION;
        _gradeDurations[4] = GRADE_4_DURATION;
        _feederHealthLimit = DEFAULT_CHAINLINK_FEEDER_HEALTH_LIMIT;
        _usdt = ERC20(DEFAULT_USDT);
        _priceFeed = AggregatorV3Interface(DEFAULT_CHAINLINK_FEEDER);
        _receiver = receiver;
        _owner = owner;
        _recorder = recorder;
        _switch = true;
    }

    function buyMembership(uint grade) nonReentrant switchOn payable external {
        address sender = msg.sender;
        uint value = msg.value;
        _addMember(sender, grade, block.timestamp, block.timestamp + _gradeDurations[grade]);
        uint requiredAmount = getAmount(grade);
        if (value < requiredAmount) revert InvalidValue(requiredAmount, value);
        uint remains = value - requiredAmount;
        emit AgentMembershipBought(sender, grade, requiredAmount, remains);
        _receiver.sendValue(requiredAmount);
        if (remains > 0) payable(sender).sendValue(remains);
    }

    function buyMembershipUSDT(uint grade) nonReentrant switchOn external {
        address sender = msg.sender;
        _addMember(sender, grade, block.timestamp, block.timestamp + _gradeDurations[grade]);
        uint amount = getAmountUSDT(grade);
        emit AgentMembershipBoughtUSDT(sender, grade, amount);
        _usdt.transferFrom(sender, _receiver, amount);
    }

    function validGrade(uint grade) public view returns (bool) {
        return _gradeMemberLimits[grade] != 0;
    }

    function stillAvailable(uint grade) public view returns (bool) {
        return _gradeMemberLimits[grade] > _gradeMemberCounts[grade];
    }

    function isActiveMember(address account) public view returns (bool) {
        AgentMembership storage agent = _agentMemberships[account];
        return agent.grade != 0 && block.timestamp >= agent.startTimestamp && block.timestamp < agent.endTimestamp;
    }

    function getAgentMembership(address account) external view returns (AgentMembership memory) {
        return _agentMemberships[account];
    }

    function addAgentGradesByRecorder(
        address[] calldata accounts,
        uint[] calldata grades,
        uint[] calldata startTimestamps,
        uint[] calldata endTimestamps
    ) onlyRecorder external {
        if (accounts.length != grades.length ||
            accounts.length != startTimestamps.length ||
            accounts.length != endTimestamps.length) revert NotSameLength();
        for (uint i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            if (startTimestamps[i] > endTimestamps[i]) revert InvalidInput();
            _addMember(accounts[i], grades[i], startTimestamps[i], endTimestamps[i]);
        }
        emit AgentMembershipAddedByRecorder(accounts, grades, startTimestamps, endTimestamps);
    }

    function removeAgentGradesByRecorder(address[] calldata accounts) onlyRecorder external {
        for (uint i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            _removeMember(accounts[i]);
        }
        emit AgentMembershipRemovedByRecorder(accounts);
    }

    function getGradeAmount(uint grade) external view returns (uint) {
        return _gradeAmounts[grade];
    }

    function setGradeAmount(uint grade, uint amount) onlyOwner notZeroGrade(grade) external{
        uint oldAmount = _gradeAmounts[grade];
        _gradeAmounts[grade] = amount;
        emit GradeAmountChanged(grade, oldAmount, amount);
    }

    function getGradeMemberLimits(uint grade) external view returns (uint) {
        return _gradeMemberLimits[grade];
    }

    function setGradeMemberLimits(uint grade, uint limit) onlyOwner notZeroGrade(grade) external{
        uint oldLimit = _gradeMemberLimits[grade];
        if (_gradeAmounts[grade] == 0) revert ZeroGradeAmount();
        if (limit < _gradeMemberCounts[grade]) revert InvalidGradeMemberLimit();
        _gradeMemberLimits[grade] = limit;
        emit GradeMemberLimitChanged(grade, oldLimit, limit);
    }

    function getGradeDurations(uint grade) external view returns (uint) {
        return _gradeDurations[grade];
    }

    function setGradeDurations(uint grade, uint duration) onlyOwner notZeroGrade(grade) external{
        uint oldDuration = _gradeDurations[grade];
        if (_gradeAmounts[grade] == 0) revert ZeroGradeAmount();
        _gradeDurations[grade] = duration;
        emit GradeDurationChanged(grade, oldDuration, duration);
    }

    function getGradeMemberCounts(uint grade) external view returns (uint) {
        return _gradeMemberCounts[grade];
    }

    function getAmount(uint grade) public view returns (uint) {
        return _calculateAmount(_gradeAmounts[grade]);
    }

    function getAmountUSDT(uint grade) public view returns (uint) {
        return _calculateAmountUSDT(_gradeAmounts[grade]);
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

    function getActionValues() external view returns (uint[1] memory) {
        return [_feederHealthLimit];
    }

    function setActionValues(uint[1] calldata new_actionValues) onlyOwner external {
        _feederHealthLimit = new_actionValues[0];
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

    function getRecorder() external view returns (address) {
        return _recorder;
    }

    function setRecorder(address new_recorder) onlyOwner external {
        if (new_recorder == address(0)) revert ZeroAddress();
        _recorder = new_recorder;
        emit RecorderChanged(new_recorder);
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

    modifier onlyRecorder() {
        address caller = msg.sender;
        if (caller != _recorder) revert NotRecorder(_recorder, caller);
        _;
    }

    modifier switchOn() {
        if (!_switch) revert SwitchOff();
        _;
    }

    modifier notZeroGrade(uint grade) {
        if (grade == 0) revert ZeroGrade();
        _;
    }

    modifier isValidGrade(uint grade) {
        if (!validGrade(grade)) revert InvalidGrade();
        _;
    }

    modifier isStillAvailable(uint grade) {
        if (!stillAvailable(grade)) revert GradeNotAvailable();
        _;
    }

    modifier notActiveMember(address account) {
        if (isActiveMember(account)) revert AlreadyMember();
        _;
    }

    function _addMember(address account, uint grade, uint startTimestamp, uint endTimestamp) notZeroGrade(grade) isValidGrade(grade) isStillAvailable(grade) notActiveMember(account) private {
        _gradeMemberCounts[grade]++;
        _agentMemberships[account] = AgentMembership(grade, startTimestamp, endTimestamp);
    }

    function _removeMember(address account) private {
        uint grade = _agentMemberships[account].grade;
        if (grade == 0) revert NotMember();
        _gradeMemberCounts[grade]--;
        delete _agentMemberships[account];
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
// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IUserBalance.sol";
import "./Delegatable.sol";
import "../interfaces/IWETH.sol";
import "../libraries/TransferHelper.sol";
import "../libraries/SubstancePausable.sol";

error UserBalance__ValidTokenNotSet();
error UserBalance__CallerIsNotWithdrawManager();
error UserBalance__CallerIsNotProductManager();
error UserBalance__InsufficientLockedTokenAmount();
error UserBalance__InvalidSetTokenData();
error UserBalance__AddValidTokenDecimalError();
error UserBalance__InvalidEthSender();
error UserBalance__Blacklisted();
error UserBalance__InvalidSettings();
error UserBalance__WithdrawLessThanMinAmount();
error UserBalance__InvalidWithdrawRequest();

contract UserBalance is UUPSUpgradeable, SubstancePausable, Delegatable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    mapping(address => bool) public isValidToken;
    mapping(address token => mapping(address user => uint256)) public userBalance;

    mapping(address => bool) public isBlacklist;

    mapping(address => bool) managers;

    address private _placeholderForTestnetWeth;

    struct TokenWithdrawConfig {
        uint256 minAmount;
        uint256 fee;
    }
    mapping(address => bool) public withdrawAdmin;
    mapping(address token => TokenWithdrawConfig) public withdrawConfig;

    uint256 public constant REQUEST_STATUS_NONE = 0;
    uint256 public constant REQUEST_STATUS_VALID = 1;
    uint256 public constant REQUEST_STATUS_CANCELLED = 2;
    uint256 public constant REQUEST_STATUS_EXECUTED = 3;
    uint256 public constant REQUEST_STATUS_REJECTED = 4;
    struct TokenWithdrawSubrequest {
        address token;
        uint256 amount;
        uint256 fee;
    }
    struct WithdrawRequest {
        uint256 status;
        TokenWithdrawSubrequest[] reqs;
    }
    mapping(address user => mapping(uint256 nonce => WithdrawRequest)) withdrawRequests;
    mapping(address user => uint256) public withdrawRequestNonce;
    mapping(address token => mapping(address user => uint256)) public frozenBalance;

    event SetToken(address indexed token, bool status);

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __SubstancePausable_init();
    }

    modifier isManager() {
        if (!managers[msg.sender]) {
            revert UserBalance__CallerIsNotProductManager();
        }
        _;
    }

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event UserBalanceUpdate(address indexed user, address indexed token, uint256 totalAmount);

    event MakeWithdrawRequest(address indexed user, uint256 indexed nonce, address[] tokens, uint256[] amounts, uint256[] fees);
    event CancelWithdrawRequest(address indexed user, uint256 indexed nonce);
    event ExecuteWithdrawRequest(address indexed user, uint256 indexed nonce);
    event RejectWithdrawRequest(address indexed user, uint256 indexed nonce);

    function _checkWithdrawAdmin() internal view {
        if (!(withdrawAdmin[msg.sender] || (msg.sender == address(hub) && withdrawAdmin[hub.msgSender()]))) {
            revert UserBalance__CallerIsNotWithdrawManager();
        }
    }

    modifier onlyWithdrawAdmin() {
        _checkWithdrawAdmin();
        _;
    }

    function setHub(address hub) external onlyOwner {
        _setHub(hub);
    }

    function getWithdrawRequest(address user, uint256 nonce) external view returns (WithdrawRequest memory) {
        return withdrawRequests[user][nonce];
    }

    function setBlacklist(address[] calldata _users, bool[] calldata _status) external onlyOwner {
        require(_users.length == _status.length);
        unchecked {
            for (uint256 i; i < _users.length; ++i) {
                isBlacklist[_users[i]] = _status[i];
            }
        }
    }

    function setManager(address[] calldata _manager, bool[] calldata _status) external onlyOwner {
        if (_manager.length != _status.length) revert UserBalance__InvalidSettings();
        unchecked {
            for (uint256 i; i < _manager.length; ++i) {
                managers[_manager[i]] = _status[i];
            }
        }
    }

    function setWithdrawAdmin(address[] calldata _manager, bool[] calldata _status) external onlyOwner {
        if (_manager.length != _status.length) revert UserBalance__InvalidSettings();
        unchecked {
            for (uint256 i; i < _manager.length; ++i) {
                withdrawAdmin[_manager[i]] = _status[i];
            }
        }
    }

    function setWithdrawConfig(address[] calldata tokens, TokenWithdrawConfig[] calldata configs) external onlyOwner {
        if (tokens.length != configs.length) revert UserBalance__InvalidSettings();
        unchecked {
            for (uint256 i; i < tokens.length; ++i) {
                TokenWithdrawConfig memory config = configs[i];
                if (config.minAmount <= config.fee) revert UserBalance__InvalidSettings();
                withdrawConfig[tokens[i]] = configs[i];
            }
        }
    }

    function _checkBlacklist(address user) internal view {
        if (isBlacklist[user]) revert UserBalance__Blacklisted();
    }

    function setToken(address[] calldata _token, bool[] calldata _status) external onlyOwner {
        if (_token.length != _status.length) {
            revert UserBalance__InvalidSetTokenData();
        }
        unchecked {
            for (uint256 i; i < _token.length; ++i) {
                isValidToken[_token[i]] = _status[i];
                emit SetToken(_token[i], _status[i]);
            }
        }
    }

    function userDeposit(address _token, uint256 _amount) external {
        _validTokenAddress(_token);
        address user = msgSender();
        IERC20Upgradeable(_token).safeTransferFrom(user, address(this), _amount);
        userBalance[_token][user] += _amount;
        emit Deposit(user, _token, _amount);
        _emitUserBalanceUpdate(user, _token);
    }

    function userDepositFor(address _token, uint256 _amount, address _beneficiary) external {
        _validTokenAddress(_token);
        address user = msgSender();
        IERC20Upgradeable(_token).safeTransferFrom(user, address(this), _amount);
        userBalance[_token][_beneficiary] += _amount;
        emit Deposit(_beneficiary, _token, _amount);
        _emitUserBalanceUpdate(_beneficiary, _token);
    }

    function makeWithdrawRequest(address[] calldata _tokens, uint256[] calldata _amounts) external whenNotPaused {
        if (_tokens.length != _amounts.length) revert UserBalance__InvalidWithdrawRequest();
        address user = msgSender();
        _checkBlacklist(user);
        uint256 nonce = withdrawRequestNonce[user];
        if (nonce > 0 && withdrawRequests[user][nonce - 1].status == REQUEST_STATUS_VALID) revert UserBalance__InvalidWithdrawRequest();
        ++withdrawRequestNonce[user];
        WithdrawRequest storage request = withdrawRequests[user][nonce];
        request.status = REQUEST_STATUS_VALID;
        uint256[] memory fees = new uint256[](_tokens.length);
        for (uint256 i; i < _tokens.length; ++i) {
            _validTokenAddress(_tokens[i]);
            TokenWithdrawConfig memory config = withdrawConfig[_tokens[i]];
            if (config.fee >= config.minAmount) revert UserBalance__InvalidSettings();
            if (_amounts[i] < config.minAmount) revert UserBalance__WithdrawLessThanMinAmount();
            userBalance[_tokens[i]][user] -= _amounts[i];
            frozenBalance[_tokens[i]][user] += _amounts[i];
            request.reqs.push(TokenWithdrawSubrequest({token: _tokens[i], amount: _amounts[i], fee: config.fee}));
            fees[i] = config.fee;
            _emitUserBalanceUpdate(user, _tokens[i]);
        }
        emit MakeWithdrawRequest(user, nonce, _tokens, _amounts, fees);
    }

    function cancelWithdrawRequest(uint256 _nonce) external whenNotPaused {
        address user = msgSender();
        WithdrawRequest storage request = withdrawRequests[user][_nonce];
        if (request.status != REQUEST_STATUS_VALID) revert UserBalance__InvalidWithdrawRequest();
        request.status = REQUEST_STATUS_CANCELLED;
        for (uint256 i; i < request.reqs.length; ++i) {
            TokenWithdrawSubrequest storage subrequest = request.reqs[i];
            frozenBalance[subrequest.token][user] -= subrequest.amount;
            userBalance[subrequest.token][user] += subrequest.amount;
            _emitUserBalanceUpdate(user, subrequest.token);
        }
        emit CancelWithdrawRequest(user, _nonce);
    }

    function rejectWithdrawRequest(address _user, uint256 _nonce, address feeReceiver) external onlyWithdrawAdmin {
        WithdrawRequest storage request = withdrawRequests[_user][_nonce];
        if (request.status != REQUEST_STATUS_VALID) revert UserBalance__InvalidWithdrawRequest();
        request.status = REQUEST_STATUS_REJECTED;
        for (uint256 i; i < request.reqs.length; ++i) {
            TokenWithdrawSubrequest storage subrequest = request.reqs[i];
            IERC20Upgradeable(subrequest.token).safeTransfer(feeReceiver, subrequest.amount);
        }
        emit RejectWithdrawRequest(_user, _nonce);
    }

    function executeWithdrawRequest(address _user, uint256 _nonce, address feeReceiver) external onlyWithdrawAdmin {
        WithdrawRequest storage request = withdrawRequests[_user][_nonce];
        if (request.status != REQUEST_STATUS_VALID) revert UserBalance__InvalidWithdrawRequest();
        request.status = REQUEST_STATUS_EXECUTED;
        for (uint256 i; i < request.reqs.length; ++i) {
            TokenWithdrawSubrequest storage subrequest = request.reqs[i];
            IERC20Upgradeable token = IERC20Upgradeable(subrequest.token);
            uint256 fee = subrequest.fee;
            uint256 amountAfterFee = subrequest.amount - fee;
            frozenBalance[address(token)][_user] -= subrequest.amount;
            if (fee > 0) {
                token.safeTransfer(feeReceiver, fee);
            }
            token.safeTransfer(_user, amountAfterFee);
            emit Withdraw(_user, address(token), amountAfterFee);
            _emitUserBalanceUpdate(_user, address(token));
        }
        emit ExecuteWithdrawRequest(_user, _nonce);
    }

    function transfer(address _token, address _user, address _to, uint256 _amount) external isManager {
        _validTokenAddress(_token);
        userBalance[_token][_user] -= _amount;
        IERC20Upgradeable(_token).safeTransfer(_to, _amount);
        _emitUserBalanceUpdate(_user, _token);
    }

    function increaseBalance(address _token, address _user, uint256 _amount) external isManager {
        _validTokenAddress(_token);
        userBalance[_token][_user] += _amount;
        _emitUserBalanceUpdate(_user, _token);
    }

    function _validTokenAddress(address _token) public view {
        if (!isValidToken[_token]) {
            revert UserBalance__ValidTokenNotSet();
        }
    }

    function _emitUserBalanceUpdate(address _user, address _token) internal {
        emit UserBalanceUpdate(_user, _token, userBalance[_token][_user]);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

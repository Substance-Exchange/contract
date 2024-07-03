// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "./Order.sol";
import "../../../interfaces/IFuture.sol";
import "../../../libraries/TransferHelper.sol";
import "../../../libraries/Struct.sol";
import "../../../libraries/ConfigConstants.sol";

error MarketOrder__InvalidExecuteTime();
error MarketOrder__InvalidDeadline();

contract MarketOrder is Order {
    mapping(address => mapping(uint256 => Struct.FutureIncreaseMarketOrder)) public increaseMarketOrder;
    mapping(address => mapping(uint256 => Struct.FutureDecreaseMarketOrder)) public decreaseMarketOrder;
    mapping(address => uint256) public increaseMarketOrderNonce;
    mapping(address => uint256) public decreaseMarketOrderNonce;

    event CreateIncreaseMarketOrder(
        address indexed user,
        uint256 indexed nonce,
        address future,
        uint256 futureId,
        uint256 increaseTokenSize,
        uint256 increaseCollateral,
        uint256 executePrice,
        uint256 executionFee,
        uint256 deadline
    );
    event CancelIncreaseMarketOrder(address indexed user, uint256 indexed nonce, uint256 reason);
    event CreateDecreaseMarketOrder(
        address indexed user,
        uint256 indexed nonce,
        address future,
        uint256 futureId,
        uint256 decreaseTokenSize,
        uint256 executePrice,
        uint256 executionFee,
        uint256 deadline
    );
    event CancelDecreaseMarketOrder(address indexed user, uint256 indexed nonce, uint256 reason);
    event ExecuteIncreaseMarketOrder(address indexed user, uint256 indexed nonce, bool cancelled, uint256 currentPrice, bool success);
    event ExecuteDecreaseMarketOrder(address indexed user, uint256 indexed nonce, bool cancelled, uint256 currentPrice, bool success);

    function initialize(IFutureManager _manager, IPriceOracle _oracle) external initializer {
        __Order_init(_manager, _oracle);
    }

    function _executeIncreaseMarketOrder(address _user, uint256 _nonce, uint256 _currentPrice, address _feeReceiver) internal returns (bool cancelled) {
        Struct.FutureIncreaseMarketOrder storage order = increaseMarketOrder[_user][_nonce];
        if (block.timestamp > order.deadline) revert MarketOrder__InvalidExecuteTime();
        order.valid = false;
        if (order.future == manager.futureLong()) {
            if (_currentPrice > order.executePrice) {
                cancelled = true;
            }
        } else {
            if (_currentPrice < order.executePrice) {
                cancelled = true;
            }
        }
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
    }

    function _executeDecreaseMarketOrder(address _user, uint256 _nonce, uint256 _currentPrice, address _feeReceiver) internal returns (bool cancelled) {
        Struct.FutureDecreaseMarketOrder storage order = decreaseMarketOrder[_user][_nonce];
        if (block.timestamp > order.deadline) revert MarketOrder__InvalidExecuteTime();
        order.valid = false;
        if (order.future == manager.futureLong()) {
            if (_currentPrice < order.executePrice) {
                cancelled = true;
            }
        } else {
            if (_currentPrice > order.executePrice) {
                cancelled = true;
            }
        }
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
    }

    function _cancelDecreaseMarketOrder(address _user, uint256 _nonce, uint256 reason, address _feeReceiver) internal {
        if (_nonce >= decreaseMarketOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureDecreaseMarketOrder storage order = decreaseMarketOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        emit CancelDecreaseMarketOrder(_user, _nonce, reason);
    }

    function makeIncreaseMarketOrder(
        uint256 _futureId,
        uint256 _executePrice,
        uint256 _increaseTokenSize,
        uint256 _increaseCollateral,
        uint256 _deadline,
        Struct.FutureType _futureType
    ) external payable checkFee {
        if (_deadline < block.timestamp + _getConfig(ConfigConstants.ORDER_MIN_DEADLINE, _futureId)) revert MarketOrder__InvalidDeadline();
        address _future = manager.getFutureByType(_futureType);
        _checkPositive(_increaseTokenSize);
        _checkPositive(_increaseCollateral);
        address _user = msgSender();
        manager.takeUserFund(_user, _future, _increaseCollateral);

        IFuture(_future).checkFutureId(_futureId);
        uint256 nonce = increaseMarketOrderNonce[_user]++;
        increaseMarketOrder[_user][nonce] = Struct.FutureIncreaseMarketOrder({
            future: _future,
            futureId: _futureId,
            increaseTokenSize: _increaseTokenSize,
            increaseCollateral: _increaseCollateral,
            executePrice: _executePrice,
            executionFee: msg.value,
            deadline: _deadline,
            valid: true
        });
        emit CreateIncreaseMarketOrder(_user, nonce, _future, _futureId, _increaseTokenSize, _increaseCollateral, _executePrice, msg.value, _deadline);
    }

    function executeIncreaseMarketOrder(address _user, uint256 _nonce, uint256 _curPrice, Struct.OrderFeeInfo calldata _feeInfo) external onlyOperator {
        if (_nonce >= increaseMarketOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureIncreaseMarketOrder storage order = increaseMarketOrder[_user][_nonce];
        // check order validation first
        if (!order.valid) revert Order__ExecutedOrder();
        address future = order.future; // gas savings
        uint256 futureId = order.futureId; // gas savings
        oracle.validatePrice(future, futureId, _curPrice);
        uint256 increaseTokenSize = order.increaseTokenSize; // gas savings
        uint256 increaseCollateral = order.increaseCollateral; // gas savings
        {
            uint256 usdValue = IFuture(future).getUSDValue(futureId, increaseTokenSize, _curPrice);
            if (usdValue < _getConfig(ConfigConstants.ORDER_MIN_USD_VALUE, futureId)) {
                _cancelIncreaseMarketOrder(_user, _nonce, Struct.CancelReason.LessThanMinUSDValue, _feeInfo.feeReceiver);
                return;
            }
            if (usdValue < (_getConfig(ConfigConstants.ORDER_MIN_LEVERAGE, futureId) * increaseCollateral) / ConfigConstants.LEVERAGE_PRECISION) {
                _cancelIncreaseMarketOrder(_user, _nonce, Struct.CancelReason.LessThanMinLeverage, _feeInfo.feeReceiver);
                return;
            }
            if (usdValue > (_getConfig(ConfigConstants.ORDER_MAX_LEVERAGE, futureId) * increaseCollateral) / ConfigConstants.LEVERAGE_PRECISION) {
                _cancelIncreaseMarketOrder(_user, _nonce, Struct.CancelReason.MoreThanMaxLeverage, _feeInfo.feeReceiver);
                return;
            }
        }
        if (!manager.checkFutureLockedSizeEnough(future, futureId, _user, increaseCollateral)) {
            _cancelIncreaseMarketOrder(_user, _nonce, Struct.CancelReason.NotEnoughLP, _feeInfo.feeReceiver);
            return;
        }
        bool cancelled = _executeIncreaseMarketOrder(_user, _nonce, _curPrice, _feeInfo.feeReceiver);
        if (!cancelled) {
            Struct.FutureFeeInfo memory info = manager.getFeeInfoWithAvailableToken(_user, true, _feeInfo);
            Struct.UpdatePositionResult memory result;
            {
                bytes32 label = _getLabel(_nonce, SUBTYPE_INCREASE);
                result = IFuture(future).increasePosition(_user, futureId, _curPrice, increaseTokenSize, increaseCollateral, info, label);
            }
            manager.updateExchangeByUpdatePositionResult(future, futureId, _user, result);
            if (!result.success) {
                manager.giveUserFund(_user, future, increaseCollateral);
            }
            emit ExecuteIncreaseMarketOrder(_user, _nonce, cancelled, _curPrice, result.success);
        } else {
            manager.giveUserFund(_user, future, increaseCollateral);
            emit ExecuteIncreaseMarketOrder(_user, _nonce, cancelled, _curPrice, false);
        }
    }

    function cancelIncreaseMarketOrder(uint256 _nonce) external {
        address user = msgSender();
        _cancelIncreaseMarketOrder(user, _nonce, Struct.CancelReason.UserCanceled, user);
    }

    function _cancelIncreaseMarketOrder(address _user, uint256 _nonce, Struct.CancelReason _reason, address _feeReceiver) internal {
        if (_nonce >= increaseMarketOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureIncreaseMarketOrder storage order = increaseMarketOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        emit CancelIncreaseMarketOrder(_user, _nonce, uint256(_reason));
        manager.giveUserFund(_user, order.future, order.increaseCollateral);
    }

    // decrease position market order
    function makeDecreaseMarketOrder(
        uint256 _futureId,
        uint256 _executePrice,
        uint256 _decreaseTokenSize,
        uint256 _deadline,
        Struct.FutureType _futureType
    ) external payable checkFee {
        if (_deadline < block.timestamp + _getConfig(ConfigConstants.ORDER_MIN_DEADLINE, _futureId)) revert MarketOrder__InvalidDeadline();
        _checkPositive(_decreaseTokenSize);
        address _user = msgSender();
        address _future = manager.getFutureByType(_futureType);
        IFuture(_future).checkFutureId(_futureId);
        uint256 nonce = decreaseMarketOrderNonce[_user]++;
        decreaseMarketOrder[_user][nonce] = Struct.FutureDecreaseMarketOrder({
            future: _future,
            futureId: _futureId,
            decreaseTokenSize: _decreaseTokenSize,
            executePrice: _executePrice,
            executionFee: msg.value,
            deadline: _deadline,
            valid: true
        });
        emit CreateDecreaseMarketOrder(_user, nonce, _future, _futureId, _decreaseTokenSize, _executePrice, msg.value, _deadline);
    }

    function executeDecreaseMarketOrder(address _user, uint256 _nonce, uint256 _curPrice, Struct.OrderFeeInfo calldata _feeInfo) external onlyOperator {
        if (_nonce >= decreaseMarketOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureDecreaseMarketOrder storage order = decreaseMarketOrder[_user][_nonce];
        // check order validation first
        if (!order.valid) revert Order__ExecutedOrder();
        address future = order.future; // gas savings
        uint256 futureId = order.futureId; // gas savings
        oracle.validatePrice(future, futureId, _curPrice);
        uint256 decreaseTokenSize = order.decreaseTokenSize; // gas savings
        if (!IFuture(order.future).checkEnoughDecreaseTokenSize(_user, futureId, decreaseTokenSize)) {
            _cancelDecreaseMarketOrder(_user, _nonce, uint256(Struct.CancelReason.NotEnoughTokenSize), _feeInfo.feeReceiver);
            return;
        }
        if (
            !IFuture(order.future).checkEnoughRemainingUSDValue(
                _user,
                futureId,
                decreaseTokenSize,
                _curPrice,
                _getConfig(ConfigConstants.ORDER_MIN_USD_VALUE_AFTER_DECREASE, futureId)
            )
        ) {
            _cancelDecreaseMarketOrder(_user, _nonce, uint256(Struct.CancelReason.checkEnoughRemainingUSDValue), _feeInfo.feeReceiver);
            return;
        }
        bool cancelled = _executeDecreaseMarketOrder(_user, _nonce, _curPrice, _feeInfo.feeReceiver);
        if (!cancelled) {
            Struct.FutureFeeInfo memory info = manager.getFeeInfoWithAvailableToken(_user, false, _feeInfo);
            bytes32 label = _getLabel(_nonce, SUBTYPE_DECREASE);
            Struct.UpdatePositionResult memory result = IFuture(future).decreasePosition(_user, futureId, _curPrice, decreaseTokenSize, info, label);
            manager.updateExchangeByUpdatePositionResult(future, futureId, _user, result);
            emit ExecuteDecreaseMarketOrder(_user, _nonce, cancelled, _curPrice, result.success);
        } else {
            emit ExecuteDecreaseMarketOrder(_user, _nonce, cancelled, _curPrice, false);
        }
    }

    function cancelDecreaseMarketOrder(uint256 _nonce) external {
        address user = msgSender();
        _cancelDecreaseMarketOrder(user, _nonce, uint256(Struct.CancelReason.UserCanceled), user);
    }
}

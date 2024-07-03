// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "./Order.sol";
import "../../../interfaces/IFuture.sol";
import "../../../interfaces/IFutureManager.sol";
import "../../../libraries/TransferHelper.sol";
import "../../../libraries/Struct.sol";
import "../../../libraries/ConfigConstants.sol";

error LimitOrder__InvalidExecutionPrice();
error LimitOrder__LessThanMinUSDValue();
error LimitOrder__MoreThanMaxLeverage();
error LimitOrder__LessThanMinLeverage();

contract LimitOrder is Order {
    mapping(address => mapping(uint256 => Struct.FutureIncreaseLimitOrder)) public increaseLimitOrder;
    mapping(address => mapping(uint256 => Struct.FutureDecreaseLimitOrder)) public decreaseLimitOrder;
    mapping(address => uint256) public increaseLimitOrderNonce;
    mapping(address => uint256) public decreaseLimitOrderNonce;

    event CreateIncreaseLimitOrder(
        address indexed user,
        uint256 indexed nonce,
        address future,
        uint256 futureId,
        uint256 increaseCollateral,
        uint256 increaseTokenSize,
        uint256 price,
        uint256 executionFee
    );
    event CancelIncreaseLimitOrder(address indexed user, uint256 indexed nonce, uint256 reason);
    event CreateDecreaseLimitOrder(
        address indexed user,
        uint256 indexed nonce,
        uint256 indexed offset,
        address future,
        uint256 futureId,
        uint256 decreaseTokenSize,
        uint256 price,
        uint256 executionFee
    );
    event CancelDecreaseLimitOrder(address indexed user, uint256 indexed nonce, uint256 reason);
    event ExecuteIncreaseLimitOrder(address indexed user, uint256 indexed nonce, uint256 price, bool success);
    event ExecuteDecreaseLimitOrder(address indexed user, uint256 indexed nonce, uint256 price, bool success);

    function initialize(IFutureManager _manager, IPriceOracle _oracle) external initializer {
        __Order_init(_manager, _oracle);
    }

    function makeIncreaseLimitOrder(
        uint256 _futureId,
        uint256 _price,
        uint256 _increaseTokenSize,
        uint256 _increaseCollateral,
        Struct.FutureType _futureType
    ) external payable checkFee {
        address _future = manager.getFutureByType(_futureType);
        IFuture(_future).checkFutureId(_futureId);
        _checkPositive(_increaseTokenSize);
        _checkPositive(_increaseCollateral);
        uint256 usdValue = IFuture(_future).getUSDValue(_futureId, _increaseTokenSize, _price);
        if (usdValue < _getConfig(ConfigConstants.ORDER_MIN_USD_VALUE, _futureId)) revert LimitOrder__LessThanMinUSDValue();
        if (usdValue < (_getConfig(ConfigConstants.ORDER_MIN_LEVERAGE, _futureId) * _increaseCollateral) / ConfigConstants.LEVERAGE_PRECISION)
            revert LimitOrder__LessThanMinLeverage();
        if (usdValue > (_getConfig(ConfigConstants.ORDER_MAX_LEVERAGE, _futureId) * _increaseCollateral) / ConfigConstants.LEVERAGE_PRECISION)
            revert LimitOrder__MoreThanMaxLeverage();
        address _user = msgSender();
        manager.takeUserFund(_user, _future, _increaseCollateral);

        uint256 nonce = increaseLimitOrderNonce[_user]++;
        increaseLimitOrder[_user][nonce] = Struct.FutureIncreaseLimitOrder({
            future: _future,
            futureId: _futureId,
            increaseTokenSize: _increaseTokenSize,
            increaseCollateral: _increaseCollateral,
            price: _price,
            executionFee: msg.value,
            valid: true
        });
        emit CreateIncreaseLimitOrder(_user, nonce, _future, _futureId, _increaseCollateral, _increaseTokenSize, _price, msg.value);
    }

    function executeIncreaseLimitOrder(address _user, uint256 _nonce, uint256 _curPrice, Struct.OrderFeeInfo calldata _feeInfo) external onlyOperator {
        if (_nonce >= increaseLimitOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureIncreaseLimitOrder storage order = increaseLimitOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();

        if (!_checkLimitOrderLockedSizeEnough(_user, _nonce)) {
            _cancelIncreaseLimitOrderWithFund(_user, _nonce, Struct.CancelReason.NotEnoughLP, _feeInfo.feeReceiver);
            return;
        }
        address future = order.future; // gas saving
        uint256 futureId = order.futureId; // gas saving
        oracle.validatePrice(future, futureId, _curPrice);

        if (future == manager.futureLong()) {
            if (_curPrice > order.price) revert LimitOrder__InvalidExecutionPrice();
        } else {
            if (_curPrice < order.price) revert LimitOrder__InvalidExecutionPrice();
        }
        {
            uint256 increaseTokenSize = order.increaseTokenSize; // gas savings
            uint256 increaseCollateral = order.increaseCollateral; // gas savings
            uint256 usdValue = IFuture(future).getUSDValue(futureId, increaseTokenSize, _curPrice);
            if (usdValue < _getConfig(ConfigConstants.ORDER_MIN_USD_VALUE, futureId)) {
                _cancelIncreaseLimitOrderWithFund(_user, _nonce, Struct.CancelReason.LessThanMinUSDValue, _feeInfo.feeReceiver);
                return;
            }
            if (usdValue < (_getConfig(ConfigConstants.ORDER_MIN_LEVERAGE, futureId) * increaseCollateral) / ConfigConstants.LEVERAGE_PRECISION) {
                _cancelIncreaseLimitOrderWithFund(_user, _nonce, Struct.CancelReason.LessThanMinLeverage, _feeInfo.feeReceiver);
                return;
            }
            if (usdValue > (_getConfig(ConfigConstants.ORDER_MAX_LEVERAGE, futureId) * increaseCollateral) / ConfigConstants.LEVERAGE_PRECISION) {
                _cancelIncreaseLimitOrderWithFund(_user, _nonce, Struct.CancelReason.MoreThanMaxLeverage, _feeInfo.feeReceiver);
                return;
            }
        }
        order.valid = false;
        TransferHelper.safeTransferETH(_feeInfo.feeReceiver, order.executionFee);

        Struct.FutureFeeInfo memory fee = manager.getFeeInfoWithAvailableToken(_user, true, _feeInfo);
        bytes32 label = _getLabel(_nonce, SUBTYPE_INCREASE);
        Struct.UpdatePositionResult memory result = IFuture(future).increasePosition(
            _user,
            futureId,
            _curPrice,
            order.increaseTokenSize,
            order.increaseCollateral,
            fee,
            label
        );
        manager.updateExchangeByUpdatePositionResult(future, futureId, _user, result);
        if (!result.success) {
            manager.giveUserFund(_user, future, order.increaseCollateral);
        }
        emit ExecuteIncreaseLimitOrder(_user, _nonce, _curPrice, result.success);
    }

    function _checkLimitOrderLockedSizeEnough(address _user, uint256 _nonce) internal view returns (bool) {
        Struct.FutureIncreaseLimitOrder storage order = increaseLimitOrder[_user][_nonce];
        return manager.checkFutureLockedSizeEnough(order.future, order.futureId, _user, order.increaseCollateral);
    }

    function cancelIncreaseLimitOrder(uint256 _nonce) external {
        address user = msgSender();
        _cancelIncreaseLimitOrderWithFund(user, _nonce, Struct.CancelReason.UserCanceled, user);
    }

    function _cancelIncreaseLimitOrderWithFund(address _user, uint256 _nonce, Struct.CancelReason _reason, address _feeReceiver) internal {
        if (_nonce >= increaseLimitOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureIncreaseLimitOrder storage order = increaseLimitOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        manager.giveUserFund(_user, order.future, order.increaseCollateral);
        emit CancelIncreaseLimitOrder(_user, _nonce, uint256(_reason));
    }

    // decrease position limit order
    function makeDecreaseLimitOrder(uint256 _futureId, uint256 _price, uint256 _decreaseTokenSize, Struct.FutureType _futureType) external payable checkFee {
        _checkPositive(_decreaseTokenSize);
        address _user = msgSender();
        address _future = manager.getFutureByType(_futureType);

        IFuture(_future).checkFutureId(_futureId);
        uint256 nonce = decreaseLimitOrderNonce[_user]++;
        uint256 offset = IFuture(_future).positionOffset(_futureId, _user);
        decreaseLimitOrder[_user][nonce] = Struct.FutureDecreaseLimitOrder({
            future: _future,
            futureId: _futureId,
            decreaseTokenSize: _decreaseTokenSize,
            price: _price,
            executionFee: msg.value,
            offset: offset,
            valid: true
        });

        emit CreateDecreaseLimitOrder(_user, nonce, offset, _future, _futureId, _decreaseTokenSize, _price, msg.value);
    }

    function executeDecreaseLimitOrder(address _user, uint256 _nonce, uint256 _curPrice, Struct.OrderFeeInfo calldata _feeInfo) external onlyOperator {
        if (_nonce >= decreaseLimitOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureDecreaseLimitOrder storage order = decreaseLimitOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        address future = order.future; // gas savings
        uint256 futureId = order.futureId; // gas savings
        oracle.validatePrice(future, futureId, _curPrice);
        uint256 decreaseTokenSize = order.decreaseTokenSize; // gas savings
        if (order.offset != IFuture(future).positionOffset(futureId, _user)) revert Order__InvalidOffset();
        if (future == manager.futureLong()) {
            if (_curPrice < order.price) revert LimitOrder__InvalidExecutionPrice();
        } else {
            if (_curPrice > order.price) revert LimitOrder__InvalidExecutionPrice();
        }
        if (!IFuture(future).checkEnoughDecreaseTokenSize(_user, futureId, decreaseTokenSize)) {
            _cancelDecreaseLimitOrder(_user, _nonce, uint256(Struct.CancelReason.NotEnoughTokenSize), _feeInfo.feeReceiver);
            return;
        }
        if (
            !IFuture(future).checkEnoughRemainingUSDValue(
                _user,
                futureId,
                decreaseTokenSize,
                _curPrice,
                _getConfig(ConfigConstants.ORDER_MIN_USD_VALUE_AFTER_DECREASE, futureId)
            )
        ) {
            _cancelDecreaseLimitOrder(_user, _nonce, uint256(Struct.CancelReason.checkEnoughRemainingUSDValue), _feeInfo.feeReceiver);
            return;
        }
        order.valid = false;
        TransferHelper.safeTransferETH(_feeInfo.feeReceiver, order.executionFee);

        Struct.FutureFeeInfo memory fee = manager.getFeeInfoWithAvailableToken(_user, false, _feeInfo);
        bytes32 label = _getLabel(_nonce, SUBTYPE_DECREASE);
        Struct.UpdatePositionResult memory result = IFuture(future).decreasePosition(_user, futureId, _curPrice, decreaseTokenSize, fee, label);
        manager.updateExchangeByUpdatePositionResult(future, futureId, _user, result);
        emit ExecuteDecreaseLimitOrder(_user, _nonce, _curPrice, result.success);
    }

    function cancelDecreaseLimitOrder(uint256 _nonce) external {
        address user = msgSender();
        _cancelDecreaseLimitOrder(user, _nonce, uint256(Struct.CancelReason.UserCanceled), user);
    }

    function _cancelDecreaseLimitOrder(address _user, uint256 _nonce, uint256 reason, address _feeReceiver) internal {
        if (_nonce >= decreaseLimitOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureDecreaseLimitOrder storage order = decreaseLimitOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        emit CancelDecreaseLimitOrder(_user, _nonce, reason);
    }
}

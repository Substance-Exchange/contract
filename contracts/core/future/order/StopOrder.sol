// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./Order.sol";
import "../../../interfaces/IFuture.sol";
import "../../../libraries/TransferHelper.sol";
import "../../../libraries/Struct.sol";
import "../../../libraries/ConfigConstants.sol";

error StopOrder__InvalidOffset();
error StopOrder__InvalidExecutionPrice();

contract StopOrder is Order {
    mapping(address => mapping(uint256 => Struct.FutureStopOrder)) public futureStopOrder;
    mapping(address => uint256) public futureStopOrderNonce;

    event CreateFutureStopOrder(
        address indexed user,
        uint256 indexed nonce,
        uint256 indexed offset,
        address future,
        uint256 futureId,
        uint256 decreaseTokenSize,
        uint256 triggerPrice,
        bool isStopLoss,
        uint256 executionFee
    );
    event CancelFutureStopOrder(address indexed user, uint256 indexed nonce, uint256 reason);
    event ExecuteFutureStopOrder(address indexed user, uint256 indexed nonce, uint256 executePrice, bool success);

    function initialize(IFutureManager _manager, IPriceOracle _oracle) external initializer {
        __Order_init(_manager, _oracle);
    }

    function _cancelStopOrder(address _user, uint256 _nonce, uint256 _reason, address _feeReceiver) internal {
        if (_nonce >= futureStopOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.FutureStopOrder storage order = futureStopOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        emit CancelFutureStopOrder(_user, _nonce, _reason);
    }

    function _executeStopOrder(
        address _user,
        uint256 _nonce,
        uint256 _curPrice,
        address _feeReceiver
    ) internal returns (uint256 decreaseSize, uint256 executePrice) {
        Struct.FutureStopOrder storage order = futureStopOrder[_user][_nonce];
        address future = order.future; // gas savings
        uint256 futureId = order.futureId; // gas saving
        if (order.offset != IFuture(future).positionOffset(futureId, _user)) revert Order__InvalidOffset();
        decreaseSize = order.decreaseTokenSize;
        if (future == manager.futureLong()) {
            // for future long,
            if (order.isStopLoss) {
                if (_curPrice > order.triggerPrice) revert StopOrder__InvalidExecutionPrice();
                executePrice = _curPrice;
            } else {
                if (_curPrice < order.triggerPrice) revert StopOrder__InvalidExecutionPrice();
                executePrice = order.triggerPrice;
            }
        } else {
            if (order.isStopLoss) {
                if (_curPrice < order.triggerPrice) revert StopOrder__InvalidExecutionPrice();
                executePrice = _curPrice;
            } else {
                if (_curPrice > order.triggerPrice) revert StopOrder__InvalidExecutionPrice();
                executePrice = order.triggerPrice;
            }
        }
        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
    }

    function makeFutureStopOrder(
        uint256 _futureId,
        uint256 _decreaseTokenSize,
        uint256 _triggerPrice,
        bool _isStopLoss,
        Struct.FutureType _futureType
    ) external payable checkFee {
        _checkPositive(_decreaseTokenSize);
        address _user = msgSender();
        address _future = manager.getFutureByType(_futureType);

        IFuture(_future).checkFutureId(_futureId);
        uint256 nonce = futureStopOrderNonce[_user]++;
        uint256 offset = IFuture(_future).positionOffset(_futureId, _user);
        futureStopOrder[_user][nonce] = Struct.FutureStopOrder({
            future: _future,
            futureId: _futureId,
            decreaseTokenSize: _decreaseTokenSize,
            triggerPrice: _triggerPrice,
            executionFee: msg.value,
            isStopLoss: _isStopLoss,
            offset: offset,
            valid: true
        });

        emit CreateFutureStopOrder(_user, nonce, offset, _future, _futureId, _decreaseTokenSize, _triggerPrice, _isStopLoss, msg.value);
    }

    function executeFutureStopOrder(address _user, uint256 _nonce, uint256 _curPrice, Struct.OrderFeeInfo calldata _feeInfo) external onlyOperator {
        Struct.FutureStopOrder storage order = futureStopOrder[_user][_nonce];
        if (_nonce >= futureStopOrderNonce[_user]) revert Order__InvalidNonce();
        if (!order.valid) revert Order__ExecutedOrder();
        address future = order.future;
        uint256 futureId = order.futureId;
        oracle.validatePrice(future, futureId, _curPrice);
        if (!IFuture(order.future).checkEnoughDecreaseTokenSize(_user, futureId, order.decreaseTokenSize)) {
            _cancelStopOrder(_user, _nonce, uint256(Struct.CancelReason.NotEnoughTokenSize), _feeInfo.feeReceiver);
            return;
        }
        if (
            !IFuture(order.future).checkEnoughRemainingUSDValue(
                _user,
                futureId,
                order.decreaseTokenSize,
                _curPrice,
                _getConfig(ConfigConstants.ORDER_MIN_USD_VALUE_AFTER_DECREASE, futureId)
            )
        ) {
            _cancelStopOrder(_user, _nonce, uint256(Struct.CancelReason.checkEnoughRemainingUSDValue), _feeInfo.feeReceiver);
            return;
        }

        (uint256 decreaseTokenSize, uint256 executePrice) = _executeStopOrder(_user, _nonce, _curPrice, _feeInfo.feeReceiver);
        Struct.FutureFeeInfo memory fee = manager.getFeeInfoWithAvailableToken(_user, false, _feeInfo);
        bytes32 label = _getLabel(_nonce, SUBTYPE_NONE);
        Struct.UpdatePositionResult memory result = IFuture(order.future).decreasePosition(_user, futureId, executePrice, decreaseTokenSize, fee, label);
        manager.updateExchangeByUpdatePositionResult(future, futureId, _user, result);
        emit ExecuteFutureStopOrder(_user, _nonce, executePrice, result.success);
    }

    function cancelFutureStopOrder(uint256 _nonce) external {
        address user = msgSender();
        _cancelStopOrder(user, _nonce, uint256(Struct.CancelReason.UserCanceled), user);
    }
}

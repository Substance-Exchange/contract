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

contract UpdateCollateralOrder is Order {
    mapping(address => mapping(uint256 => Struct.UpdateCollateralOrder)) public updateCollateralOrder;
    mapping(address => uint256) public updateCollateralOrderNonce;

    event CreateUpdateCollateralOrder(
        address indexed user,
        uint256 indexed nonce,
        uint256 indexed offset,
        address future,
        uint256 futureId,
        uint256 deltaAmount,
        bool increase,
        uint256 executionFee
    );
    event CancelUpdateCollateralOrder(address indexed user, uint256 indexed nonce, uint256 reason);
    event ExecuteUpdateCollateralOrder(address indexed user, uint256 indexed nonce, bool success);

    function initialize(IFutureManager _manager, IPriceOracle _oracle) external initializer {
        __Order_init(_manager, _oracle);
    }

    function createUpdateCollateralOrder(uint256 _futureId, uint256 _deltaAmount, bool _increase, Struct.FutureType _futureType) external payable checkFee {
        _checkPositive(_deltaAmount);
        if (_deltaAmount < _getConfig(ConfigConstants.ORDER_MIN_DELTA_AMOUNT, _futureId)) {
            revert Order__InvalidDeltaAmount();
        }
        address _user = msgSender();
        address _future = manager.getFutureByType(_futureType);
        if (_increase) {
            manager.takeUserFund(_user, _future, _deltaAmount);
        }
        IFuture(_future).checkFutureId(_futureId);
        uint256 nonce = updateCollateralOrderNonce[_user]++;
        uint256 offset = IFuture(_future).positionOffset(_futureId, _user);
        updateCollateralOrder[_user][nonce] = Struct.UpdateCollateralOrder({
            future: _future,
            futureId: _futureId,
            deltaAmount: _deltaAmount,
            executionFee: msg.value,
            offset: offset,
            increase: _increase,
            valid: true
        });
        emit CreateUpdateCollateralOrder(_user, nonce, offset, _future, _futureId, _deltaAmount, _increase, msg.value);
    }

    function executeUpdateCollateralOrder(
        address _user,
        uint256 _nonce,
        uint256 _price,
        uint256 _predictedLiquidateFeeRatio,
        address _feeReceiver
    ) external onlyOperator {
        if (_nonce >= updateCollateralOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.UpdateCollateralOrder storage order = updateCollateralOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        address future = order.future; // gas savings
        uint256 futureId = order.futureId; // gas savings
        oracle.validatePrice(future, futureId, _price);
        if (order.offset != IFuture(future).positionOffset(futureId, _user)) revert Order__InvalidOffset();
        uint256 deltaAmount = order.deltaAmount; // gas savings
        {
            (, uint256 tokenSize, uint256 collateral, , , , , , ) = IFuture(future).s_position(futureId, _user);
            if (tokenSize == 0) {
                _cancelUpdateCollateralOrder(_user, _nonce, Struct.CancelReason.NoExistingPosition, _feeReceiver);
                return;
            }
            uint256 usdValue = IFuture(future).getUSDValue(futureId, tokenSize, _price);
            if (order.increase) {
                if (!manager.checkFutureLockedSizeEnough(future, futureId, _user, deltaAmount)) {
                    _cancelUpdateCollateralOrder(_user, _nonce, Struct.CancelReason.NotEnoughLP, _feeReceiver);
                    return;
                }
                if (usdValue < (_getConfig(ConfigConstants.ORDER_MIN_LEVERAGE, futureId) * (collateral + deltaAmount)) / ConfigConstants.LEVERAGE_PRECISION) {
                    _cancelUpdateCollateralOrder(_user, _nonce, Struct.CancelReason.LessThanMinLeverage, _feeReceiver);
                    return;
                }
            }
        }

        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        Struct.FutureFeeInfo memory fee = Struct.FutureFeeInfo(0, 0, 0, 0, _predictedLiquidateFeeRatio);
        Struct.UpdatePositionResult memory result;
        if (order.increase) {
            bytes32 label = _getLabel(_nonce, SUBTYPE_INCREASE);
            result = IFuture(future).increaseCollateral(_user, futureId, _price, fee, deltaAmount, label);
        } else {
            bytes32 label = _getLabel(_nonce, SUBTYPE_DECREASE);
            result = IFuture(future).decreaseCollateral(_user, futureId, _price, fee, deltaAmount, label);
        }
        manager.updateExchangeByUpdatePositionResult(future, futureId, _user, result);
        if (order.increase && !result.success) {
            manager.giveUserFund(_user, future, deltaAmount);
        }
        emit ExecuteUpdateCollateralOrder(_user, _nonce, result.success);
    }

    function cancelUpdateCollateralOrder(uint256 _nonce) external {
        address user = msgSender();
        _cancelUpdateCollateralOrder(user, _nonce, Struct.CancelReason.UserCanceled, user);
    }

    function _cancelUpdateCollateralOrder(address _user, uint256 _nonce, Struct.CancelReason _reason, address _feeReceiver) internal {
        if (_nonce >= updateCollateralOrderNonce[_user]) revert Order__InvalidNonce();
        Struct.UpdateCollateralOrder storage order = updateCollateralOrder[_user][_nonce];
        if (!order.valid) revert Order__ExecutedOrder();
        order.valid = false;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        emit CancelUpdateCollateralOrder(_user, _nonce, uint256(_reason));
        if (order.increase) {
            manager.giveUserFund(_user, order.future, order.deltaAmount);
        }
    }
}

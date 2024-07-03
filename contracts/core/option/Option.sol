// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../../interfaces/IOptionManager.sol";

import "../../libraries/SubproductPausable.sol";
import "../../libraries/Struct.sol";
import "../../libraries/TransferHelper.sol";
import "hardhat/console.sol";

error Option__InvalidOption();
error Option__InvalidEpoch();
error Option__InvalidBatch();
error Option__InvalidProductId();
error Option__InvalidSettlementState();
error Option__InvalidDeadline();
error Option__InvalidClaimTime();
error Option__DuplicateSettlement();
error Option__AccessError();
error Option__InsufficientExecutionFee();
error Option__InvalidOrder();
error Option__ExecutedOrCancelledOrder();
error Option__InvalidExecutionPrice();
error Option__InvalidSettlePrice();

contract Option is UUPSUpgradeable, SubproductPausable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public globalCurrentEpoch;
    uint256 public globalCurrentEpochEndTime;
    uint256 public minExecutionFee;
    address public manager;

    uint256 public nextOptionId;

    struct OptionInfo {
        string name;
    }

    struct OptionClaimInfo {
        uint256 option;
        uint256 epoch;
        uint256 batch;
        uint256 product;
    }

    mapping(uint256 => OptionInfo) public optionInfo;
    mapping(string => uint256) public optionLookup;

    mapping(uint256 => uint256) public currentEpochNumber;
    mapping(uint256 => uint256) public currentEpochEndTime;

    /*
        @dev optionProduct[epoch][batch]: list of option products
    */
    mapping(uint256 => mapping(uint256 => mapping(uint256 => Struct.OptionProduct[]))) public optionProduct;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public strikeTimeRecord;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(address => mapping(uint256 => Struct.OptionPosInfo))))) public traderPosInfo;

    mapping(uint256 => mapping(uint256 => uint256)) public epochBatch;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public settlePriceRecord;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public isSettled;
    mapping(uint256 => mapping(uint256 => uint256)) unsettledBatchNumber;

    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public globalSettleSize;

    mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(uint256 => Struct.OptionPosInfo)))) public gloablPosInfo;
    mapping(address => mapping(uint256 => Struct.OptionOrder)) public traderOrder;
    mapping(address => uint256) public traderNonce;

    event CreateOption(uint256 indexed optionId, string name);

    event AddOptionProduct(
        uint256 indexed optionId,
        uint256 indexed epochId,
        uint256 indexed batch,
        uint256 productId,
        bool isCall,
        uint256 strikePrice,
        uint256 strikeTime
    );
    event MakeOptionOrder(
        address indexed user,
        uint256 indexed nonce,
        uint256 optionId,
        uint256 epochId,
        uint256 batch,
        uint256 productId,
        uint256 maxPrice,
        uint256 size,
        uint256 deadline,
        uint256 executionFee
    );
    event CancelOptionOrder(address indexed user, uint256 indexed nonce, uint256 reason);
    event FulfillOptionOrder(address indexed user, uint256 indexed nonce, uint256 optionId, uint256 price, uint256 size, bool cancelled, uint256 reason);
    event ClaimProfit(address indexed user, uint256 optionId, uint256 epochId, uint256 batch, uint256 productId, uint256 settleSize);
    event SettleOption(uint256 indexed optionId, uint256 indexed epochId, uint256 indexed batchId, uint256 settlePrice);

    modifier onlyManager() {
        _checkOptionManager();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 _minExecutionFee) external initializer {
        __SubproductPausable_init();

        minExecutionFee = _minExecutionFee;
        nextOptionId = 1;
    }

    function setManager(address _manager) external onlyOwner {
        manager = _manager;
    }

    function setMinExecutionFee(uint256 _minExecutionFee) external onlyOwner {
        minExecutionFee = _minExecutionFee;
    }

    function incEpoch(uint256 _currentEpochEndTime) external onlyManager {
        ++globalCurrentEpoch;
        globalCurrentEpochEndTime = _currentEpochEndTime;
    }

    function createOption(string calldata _tokenName) external onlyOwner {
        if (optionLookup[_tokenName] > 0) {
            revert Option__InvalidOption();
        }
        uint256 optionId = nextOptionId;
        currentEpochNumber[optionId] = globalCurrentEpoch;
        optionInfo[optionId] = OptionInfo(_tokenName);
        optionLookup[_tokenName] = optionId;

        emit CreateOption(optionId, _tokenName);

        ++nextOptionId;
    }

    function _checkOptionManager() internal view {
        if (msg.sender != manager) {
            revert Option__AccessError();
        }
    }

    /*
        @dev This function allows OptionManager to add option products.
    */
    function batchAddOptionProduct(
        uint256 _optionId,
        Struct.OptionProduct[] calldata _optionProduct,
        uint256 _epoch,
        uint256 _strikeTime
    ) external whenSubproductNotPaused(_optionId) onlyManager {
        if (_optionId >= nextOptionId) {
            revert Option__InvalidOption();
        }
        // Using a 1 index here
        // last batch is currentBatch
        uint256 batch = ++epochBatch[_optionId][_epoch];
        for (uint256 i; i < _optionProduct.length; i++) {
            optionProduct[_optionId][_epoch][batch].push(_optionProduct[i]);
            emit AddOptionProduct(_optionId, _epoch, batch, i, _optionProduct[i].isCall, _optionProduct[i].strikePrice, _strikeTime);
        }
        strikeTimeRecord[_optionId][_epoch][batch] = _strikeTime;
        ++unsettledBatchNumber[_optionId][_epoch];
    }

    /* 
        @dev This function allows OptionManager to claim settlement prices in last epoch.
    */
    function claimOptionSettlePrice(
        uint256 _optionId,
        uint256 _epoch,
        uint256 _batch,
        uint256 _settlePrice
    ) external whenSubproductNotPaused(_optionId) onlyManager {
        if (_optionId >= nextOptionId) {
            revert Option__InvalidOption();
        }
        if (_epoch != currentEpochNumber[_optionId]) {
            revert Option__InvalidEpoch();
        }
        if (_batch > epochBatch[_optionId][_epoch]) {
            revert Option__InvalidBatch();
        }
        if (block.timestamp <= strikeTimeRecord[_optionId][_epoch][_batch]) {
            revert Option__InvalidClaimTime();
        }
        if (_settlePrice < 10**4) {
            revert Option__InvalidSettlePrice();
        }
        settlementCheck(_optionId, _epoch, _batch);
        settlePriceRecord[_optionId][_epoch][_batch] = _settlePrice;
        uint256 traderProfit;
        for (uint256 i; i < optionProduct[_optionId][_epoch][_batch].length; ++i) {
            Struct.OptionPosInfo storage pos = gloablPosInfo[_optionId][_epoch][_batch][i];
            Struct.OptionProduct memory opt = optionProduct[_optionId][_epoch][_batch][i];
            if (opt.isCall && _settlePrice > opt.strikePrice) {
                traderProfit += pos.totalSize;
            } else if (!opt.isCall && _settlePrice < opt.strikePrice) {
                traderProfit += pos.totalSize;
            }
            emit SettleOption(_optionId, _epoch, _batch, _settlePrice);
        }
        globalSettleSize[_optionId][_epoch][_batch] = traderProfit;
        --unsettledBatchNumber[_optionId][_epoch];
    }

    /*
        @dev This function allows OptionManager to claim settlement prices in last epoch.
        @returns
    */
    function claimOptionSettlement(
        uint256 _option,
        uint256 _epoch,
        uint256 _batch
    ) external onlyManager returns (uint256, uint256) {
        if (_option >= nextOptionId) {
            revert Option__InvalidOption();
        }
        settlementCheck(_option, _epoch, _batch);
        isSettled[_option][_epoch][_batch] = true;
        uint256 traderTotalSize;
        for (uint256 i; i < optionProduct[_option][_epoch][_batch].length; ++i) {
            Struct.OptionPosInfo storage pos = gloablPosInfo[_option][_epoch][_batch][i];
            traderTotalSize += pos.totalSize;
        }
        return (traderTotalSize, globalSettleSize[_option][_epoch][_batch]);
    }

    function makeOrder(
        address _user,
        uint256 _option,
        uint256 _epoch,
        uint256 _batch,
        uint256 _productId,
        uint256 _maxPrice,
        uint256 _size,
        uint256 _deadline
    ) external payable onlyManager returns (uint256 cost) {
        if (_option >= nextOptionId) {
            revert Option__InvalidOption();
        }
        if (msg.value < minExecutionFee) {
            revert Option__InsufficientExecutionFee();
        }
        if (epochBatch[_option][_epoch] < _batch) {
            revert Option__InvalidBatch();
        }
        if (_productId >= optionProduct[_option][_epoch][_batch].length) {
            revert Option__InvalidProductId();
        }
        if (_deadline > strikeTimeRecord[_option][_epoch][_batch]) {
            revert Option__InvalidDeadline();
        }
        cost = _maxPrice * _size;
        // nonce starts from 0.
        uint256 nonce = traderNonce[_user]++;
        traderOrder[_user][nonce] = Struct.OptionOrder({
            optionId: _option,
            epochId: _epoch,
            batch: _batch,
            productId: _productId,
            maxPrice: _maxPrice,
            size: _size,
            deadline: _deadline,
            executionFee: msg.value,
            valid: true
        });
        emit MakeOptionOrder(_user, nonce, _option, _epoch, _batch, _productId, _maxPrice, _size, _deadline, msg.value);
    }

    function cancelOrder(
        address _user,
        uint256 _nonce,
        uint256 reason
    ) external onlyManager returns (uint256 maxCost) {
        Struct.OptionOrder storage order = traderOrder[_user][_nonce];
        if (traderNonce[_user] <= _nonce) {
            revert Option__InvalidOrder();
        }
        if (!order.valid) {
            revert Option__ExecutedOrCancelledOrder();
        }
        maxCost = order.size * order.maxPrice;
        order.valid = false;
        TransferHelper.safeTransferETH(_user, order.executionFee);
        emit CancelOptionOrder(_user, _nonce, reason);
    }

    function fulfillOrder(
        address _user,
        uint256 _nonce,
        uint256 _price,
        address _feeReceiver,
        uint256 _availableUSD,
        uint256 _settlePrice
    )
        external
        onlyManager
        returns (
            uint256 cost,
            uint256 maxCost,
            uint256 size,
            bool canceled,
            uint256 optionId
        )
    {
        Struct.OptionOrder storage order = traderOrder[_user][_nonce];
        optionId = order.optionId;
        _checkPaused(optionId);
        uint256 reason;
        if (traderNonce[_user] <= _nonce) {
            revert Option__InvalidOrder();
        }
        if (!order.valid) {
            revert Option__ExecutedOrCancelledOrder();
        }
        if (_price > order.maxPrice) {
            revert Option__InvalidExecutionPrice();
        }
        // @dev
        // This line is useless now, it's not necessary to assert isSettled[epoch][batch] = false.
        // Because deadline <= strike_time[epoch][batch] && claim_time > strike_time[epoch][batch], if this option product is settled, block.timestamp must be greater than order.deadline
        // But I still add this line to adapt upgrade in the future.
        if (block.timestamp >= order.deadline || isSettled[order.optionId][order.epochId][order.batch]) {
            canceled = true;
            reason = 1;
        } else if (_availableUSD < _settlePrice * order.size) {
            canceled = true;
            reason = 2;
        } else {
            size = order.size;
            cost = _price * size;
            Struct.OptionPosInfo storage position = traderPosInfo[optionId][order.epochId][order.batch][_user][order.productId];
            position.totalCost += cost;
            position.totalSize += size;

            Struct.OptionPosInfo storage globalPosition = gloablPosInfo[optionId][order.epochId][order.batch][order.productId];
            globalPosition.totalCost += cost;
            globalPosition.totalSize += size;
        }

        maxCost = order.maxPrice * size;
        TransferHelper.safeTransferETH(_feeReceiver, order.executionFee);
        order.valid = false;

        // if cancel = false, reason has to be 0.
        emit FulfillOptionOrder(_user, _nonce, optionId, _price, order.size, canceled, reason);
    }

    /* 
        @dev This function allows OptionManager to start a new epoch, the process requires all of settlement prices of last epoch are claimed.
    */
    function moveToNextEpoch(uint256 _option, uint256 _currentEpochEndTime) external onlyManager {
        if (unsettledBatchNumber[_option][currentEpochNumber[_option]] == 0) {
            ++currentEpochNumber[_option];
            currentEpochEndTime[_option] = _currentEpochEndTime;
        } else {
            revert Option__InvalidSettlementState();
        }
    }

    function settlementCheck(
        uint256 _optionId,
        uint256 _epoch,
        uint256 _batch
    ) private view {
        if (isSettled[_optionId][_epoch][_batch]) {
            revert Option__DuplicateSettlement();
        }
    }

    function transfer(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyManager {
        IERC20Upgradeable(_token).safeTransfer(_to, _amount);
    }

    /*
        TODO 
        @dev users claim their profit to their user balances, require Option[epoch][batch] is settled. 
    */
    function userClaimProfit(address _user, OptionClaimInfo[] calldata _data) external onlyManager returns (uint256 settleSize) {
        for (uint256 i; i < _data.length; ++i) {
            OptionClaimInfo memory info = _data[i];
            _checkPaused(info.option);
            Struct.OptionPosInfo storage pos = traderPosInfo[info.option][info.epoch][info.batch][_user][info.product];
            if (pos.isSettle == 0 && isSettled[info.option][info.epoch][info.batch]) {
                Struct.OptionProduct memory opt = optionProduct[info.option][info.epoch][info.batch][info.product];
                uint256 settlePrice = settlePriceRecord[info.option][info.epoch][info.batch];
                if ((opt.isCall && settlePrice > opt.strikePrice) || (!opt.isCall && settlePrice < opt.strikePrice)) {
                    uint256 size = pos.totalSize;
                    settleSize += size;
                    emit ClaimProfit(_user, info.option, info.epoch, info.batch, info.product, size);
                } else {
                    emit ClaimProfit(_user, info.option, info.epoch, info.batch, info.product, 0);
                }
                pos.isSettle = 1;
            }
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

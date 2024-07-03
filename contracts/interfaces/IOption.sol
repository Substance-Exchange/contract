// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "../libraries/Struct.sol";

interface IOption {
    struct OptionClaimInfo {
        uint256 option;
        uint256 epoch;
        uint256 batch;
        uint256 product;
    }

    function nextOptionId() external returns (uint256);

    function globalCurrentEpoch() external returns (uint256);

    function globalCurrentEpochEndTime() external returns (uint256);

    function moveToNextEpoch(uint256 _option, uint256 _currentEpochEndTime) external;

    function incEpoch(uint256 _currentEpochEndTime) external;

    function batchAddOptionProduct(uint256 _optionId, Struct.OptionProduct[] calldata _optionProduct, uint256 _epoch, uint256 _strikeTime) external;

    function makeOrder(
        address _user,
        uint256 _option,
        uint256 _epoch,
        uint256 _batch,
        uint256 _productId,
        uint256 _maxPrice,
        uint256 _size,
        uint256 _deadline
    ) external payable returns (uint256 cost);

    function cancelOrder(address _user, uint256 _nonce, uint256 reason) external returns (uint256 maxCost);

    function fulfillOrder(
        address _user,
        uint256 _nonce,
        uint256 _price,
        address _feeReceiver,
        uint256 _availableUSD,
        uint256 _settlePrice
    ) external returns (uint256 cost, uint256 maxCost, uint256 size, bool canceled, uint256 optionId);

    function claimOptionSettlePrice(uint256 _optionId, uint256 _epoch, uint256 _batch, uint256 _settlePrice) external;

    function claimOptionSettlement(uint256 _option, uint256 _epoch, uint256 _batch) external returns (uint256, uint256);

    function userClaimProfit(address _user, OptionClaimInfo[] calldata _data) external returns (uint256 settleSize);

    function transfer(address _token, address _to, uint256 _amount) external;
}

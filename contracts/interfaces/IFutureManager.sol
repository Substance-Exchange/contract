// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "../libraries/Struct.sol";

interface IFutureManager {
    function futureLong() external view returns (address);

    function futureShort() external view returns (address);

    function minExecutionFee() external view returns (uint256);

    function futureConfig() external view returns (address);

    function getFutureByType(Struct.FutureType _futureType) external view returns (address);

    function takeUserFund(
        address user,
        address future,
        uint256 amount
    ) external;

    function giveUserFund(
        address user,
        address future,
        uint256 amount
    ) external;

    function checkFutureLockedSizeEnough(
        address _future,
        uint256 _futureId,
        address _user,
        uint256 increaseCollateral
    ) external view returns (bool);

    function updateExchangeByUpdatePositionResult(
        address _future,
        uint256 _futureId,
        address _user,
        Struct.UpdatePositionResult memory _result
    ) external;

    function getPositionUpdateHooks() external view returns (address[] memory);

    function orderImpl(address) external view returns (bool);

    function getFeeInfoWithAvailableToken(
        address user,
        bool includeUserBalance,
        Struct.OrderFeeInfo memory info
    ) external view returns (Struct.FutureFeeInfo memory fee);

    function getAllFuturesUnrealizedProfit(uint256[] calldata _futureLongPrices, uint256[] calldata _futureShortPrices) external view returns (int256);

    function getCheckedAllUpl(
        uint256 startFutureLongId,
        uint256 startFutureShortId,
        uint256[] calldata _futureLongPrices,
        uint256[] calldata _futureShortPrices
    ) external view returns (int256, bool);
}

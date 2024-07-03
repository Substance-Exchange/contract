// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "../libraries/Struct.sol";

interface IFuture {
    function nextFutureId() external view returns (uint256);

    function priceDecimal(uint256 futureId) external view returns (int8);

    function contractValueDecimal(uint256 futureId) external view returns (int8);

    function sizeGlobal(uint256 futureId) external view returns (uint256);

    function fundingFeeUpdateInterval() external view returns (uint256);

    function updateBorrowingFeePerToken(uint256 futureId, uint256 rate, uint256 _price) external;

    function updateFundingFees(uint256 _futureId, int256 _totalFundingFees, uint256 _price) external;

    function maxProfitRatio(uint256) external view returns (uint256);

    function positionOffset(uint256, address) external view returns (uint256);

    function getLockedTokenSize(uint256 futureId, address user, uint256 increaseCollateral) external view returns (uint256);

    // internal functions
    function increasePosition(
        address _user,
        uint256 _futureId,
        uint256 _price,
        uint256 _increaseTokenSize,
        uint256 _increaseCollateral,
        Struct.FutureFeeInfo calldata _feeInfo,
        bytes32 label
    ) external returns (Struct.UpdatePositionResult memory result);

    function decreasePosition(
        address _user,
        uint256 _futureId,
        uint256 _price,
        uint256 _decreaseTokenSize,
        Struct.FutureFeeInfo calldata _feeInfo,
        bytes32 label
    ) external returns (Struct.UpdatePositionResult memory result);

    function liquidatePosition(
        address _user,
        uint256 _futureId,
        uint256 _price,
        Struct.FutureFeeInfo calldata _feeInfo
    ) external returns (Struct.UpdatePositionResult memory result);

    function increaseCollateral(
        address _user,
        uint256 _futureId,
        uint256 _price,
        Struct.FutureFeeInfo memory _feeInfo,
        uint256 _increaseCollateral,
        bytes32 label
    ) external returns (Struct.UpdatePositionResult memory result);

    function decreaseCollateral(
        address _user,
        uint256 _futureId,
        uint256 _price,
        Struct.FutureFeeInfo memory _feeInfo,
        uint256 _decreaseCollateral,
        bytes32 label
    ) external returns (Struct.UpdatePositionResult memory result);

    function transfer(address _token, address _dist, uint256 _tokenAmount) external;

    function getUnrealizedPnlInUSD(uint256 _futureId, uint256 _price) external view returns (int256);

    function getAllUnrealizedPnlInUSD(uint256[] calldata price) external view returns (int256 pnl);

    function checkEnoughDecreaseTokenSize(address _user, uint256 futureId, uint256 deceraseTokenSize) external view returns (bool);

    function checkEnoughRemainingUSDValue(
        address _user,
        uint256 _futureId,
        uint256 _decreaseTokenSize,
        uint256 _price,
        uint256 _minUSDValue
    ) external view returns (bool);

    function checkFutureId(uint256 _futureId) external view;

    function s_position(
        uint256 _futureId,
        address _user
    )
        external
        view
        returns (
            uint256 openCost,
            uint256 tokenSize,
            uint256 collateral,
            int256 entryFundingFeePerToken,
            int256 cumulativeFundingFee,
            uint256 entryBorrowingFeePerToken,
            uint256 cumulativeBorrowingFee,
            uint256 maxProfitRatio,
            uint256 cumulativeTeamFee
        );

    function futureLookup(string calldata _name) external view returns (uint256);

    function getGlobalUSDValue(uint256 _futureId, uint256 _price) external view returns (uint256);

    function calcBorrowingFee(
        uint256 _futureId,
        uint256 _tokenSize,
        uint256 _entryBorrowingFeePerToken,
        uint256 _cumulativeBorrowingFee
    ) external view returns (uint256);

    function calcFundingFee(
        uint256 _futureId,
        uint256 _tokenSize,
        int256 _entryFundingFeePerToken,
        int256 _cumulativeFundingFee
    ) external view returns (int256);

    function getUSDValue(uint256 _futureId, uint256 _tokenSize, uint256 _price) external view returns (uint256);
}

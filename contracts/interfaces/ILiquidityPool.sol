// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

interface ILiquidityPool {
    function usd() external view returns (address);

    function lockLiquidity(uint256 _amount, address _product, uint256 _productId) external;

    function unlockLiquidity(uint256 _amount, address _product, uint256 _productId) external;

    function increaseLiquidity(uint256 _amount) external;

    function transferUSD(address _to, uint256 _amount) external;

    function getTotalAvailableToken() external view returns (uint256);

    function getAvailableToken(address product) external view returns (uint256);

    function getAvailableTokenForFuture(address _future, uint256 _futureId) external view returns (uint256);

    function moveToNextEpoch(uint256 _nextEpochEndTime, int256 _futureUnrealizedUPL) external;

    function lpProvideLiquidity(address _user, uint256 _amount) external;

    function withdrawUserSLPClaim(uint256 epoch, address _user) external returns (uint256 userClaim);

    function lpWithdrawSLP(address _user, uint256 _amount) external;

    function withdrawUsersLiquidity(uint256 epoch, address _user) external returns (uint256[] memory userInfo);

    function maxLockedRatio(address product, uint256 productId) external view returns (uint256);

    function poolAmount() external view returns (uint256);
}

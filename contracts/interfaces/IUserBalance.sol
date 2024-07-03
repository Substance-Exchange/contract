// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

interface IUserBalance {
    function setOptionManager(address _optionManager) external;

    function setFutureManager(address _futureManager) external;

    function userDeposit(address _token, uint256 _amount) external;

    function userWithdraw(address _token, uint256 _amount) external;

    function userDepositETH() external payable;

    function userWithdrawETH(uint256 _amount) external;

    function transferToLiquidityPool(address _token, address _user, uint256 _amount, address _liquidityPool) external;

    function transfer(address _token, address _user, address _to, uint256 _amount) external;

    function increaseBalance(address _token, address _user, uint256 _amount) external;

    function userBalance(address _token, address _user) external view returns (uint256);

    function userDepositFor(
        address _token,
        uint256 _amount,
        address _beneficiary
    ) external;
}

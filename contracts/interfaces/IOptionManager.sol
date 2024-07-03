// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

interface IOptionManager {
    function baseTokenAddress() external returns (address);

    function moveToNextEpoch(uint256 _currentEpochEndTime) external;
}
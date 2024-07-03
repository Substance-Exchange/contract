// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

interface IFutureConfig {
    function getConfig(bytes32 key, uint256 futureId) external view returns (uint256);
}
// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

interface IPriceOracle {
    function validatePrice(address product, uint256 subproduct, uint256 price) external view;
}
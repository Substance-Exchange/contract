// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

library ConfigConstants {
    uint256 public constant LEVERAGE_PRECISION = 100;

    bytes32 public constant ORDER_MIN_USD_VALUE = 0x79ce2f39c098bf20028efb4c6bce006c7e7920c851e9c9418408e3b5c65668a9;
    bytes32 public constant ORDER_MIN_LEVERAGE = 0xd9c79e12ae566854d4f688cfac061b808bd70383fcf3430dbb6342ff2f0c75da;
    bytes32 public constant ORDER_MAX_LEVERAGE = 0x0d30e285e1e70dbf007c6ebb071dc9d2069c7c9786d7b1b7432e94b7f1dbf436;
    bytes32 public constant ORDER_MIN_USD_VALUE_AFTER_DECREASE = 0x39ba6649a409ec9b2ae8eb7278d42d0639081fcbb1d1957fdf0dc0d9309578b6;
    bytes32 public constant ORDER_MIN_DEADLINE = 0xf56e6873956fbd96e9ed163cc20883b8a3dc22e1aede188d9575579e80998ea3;
    bytes32 public constant ORDER_MIN_DELTA_AMOUNT = 0xfd69d0afb048a65176328ada4133770bce0164bfc0fcf4e1569d97a9f9e910f2;
}
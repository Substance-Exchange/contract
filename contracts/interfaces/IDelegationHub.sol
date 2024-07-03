// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

interface IDelegationHub {
    struct Call {
        address target;
        bool allowFailure;
        uint256 value;
        bytes payload;
    }
    
    struct Result {
        bool success;
        bytes returnData;
    }

    function msgSender() external view returns (address);

    function isOperator(address) external view returns (bool);

    function setDelegate(address _delegatee) external;

    function operatorSetDelegate(address _delegator, address _delegatee) external;

    function traderDelegate(address trader, Call[] calldata calls) external payable returns (Result[] memory returnData);
}

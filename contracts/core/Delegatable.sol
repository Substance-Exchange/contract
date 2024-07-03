// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "../interfaces/IDelegationHub.sol";

error Delegatable__CallerIsNotOperator();

abstract contract Delegatable {
    IDelegationHub public hub;

    function _setHub(address _hub) internal {
        hub = IDelegationHub(_hub);
    }

    function msgSender() internal view returns (address) {
        if (msg.sender == address(hub)) {
            return hub.msgSender();
        }
        return msg.sender;
    }

    function _checkOperator() internal view {
        if (!(hub.isOperator(msg.sender) || (msg.sender == address(hub) && hub.isOperator(hub.msgSender())))) {
            revert Delegatable__CallerIsNotOperator();
        }
    }

    modifier onlyOperator() {
        _checkOperator();
        _;
    }

    uint256[50] private __gap;
}

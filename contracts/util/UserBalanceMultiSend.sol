// SPDX-License-Identifier: BUSL-1.1

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUserBalance.sol";

contract UserBalanceMultiSend {
    using SafeERC20 for IERC20;

    IUserBalance public userBalance;

    constructor(IUserBalance ub) {
        userBalance = ub;
    }

    function send(address token, uint256 totalAmount, address[] calldata users, uint256[] calldata values) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        IERC20(token).approve(address(userBalance), totalAmount);
        require(users.length == values.length);
        unchecked {
            for (uint256 i; i < users.length; ++i) {
                userBalance.userDepositFor(token, values[i], users[i]);
            }
        }
    }
}
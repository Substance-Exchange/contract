// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "./Delegatable.sol";
import "../interfaces/ILiquidityPool.sol";
import "../interfaces/IUserBalance.sol";
import "../interfaces/IFutureManager.sol";
import "../interfaces/IOptionManager.sol";

import "hardhat/console.sol";

contract ExchangeManager is UUPSUpgradeable, OwnableUpgradeable, Delegatable {
    IUserBalance public userBalance;
    ILiquidityPool public liquidityPool;
    IOptionManager public optionManager;
    IFutureManager public futureManager;

    uint256 public epochNumber;
    uint256 public epochEndTime;
    address public usd;

    uint256 public settledFutureLongId;
    uint256 public settledFutureShortId;
    int256 public epochFutureUPL;

    event ExchangeStartNewEpoch(uint256 epochNumer, uint256 epochEndTime);
    event UserProvideLiquidity(address indexed _user, uint256 indexed _epoch, uint256 _amount);
    event UserClaimSLP(address indexed _user, uint256 indexed _epoch, uint256 _amount);
    event UserWithdrawLiquidity(address indexed _user, uint256 indexed _epoch, uint256 _amount);
    event UserClaimWithdrawLiquidity(address indexed _user, uint256 indexed _epoch, uint256 _amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IUserBalance _userBalance,
        ILiquidityPool _liquidityPool,
        IOptionManager _optionManager,
        IFutureManager _futureManager
    ) external initializer {
        __Ownable_init();
        userBalance = _userBalance;
        liquidityPool = _liquidityPool;
        optionManager = _optionManager;
        futureManager = _futureManager;
        usd = _liquidityPool.usd();
        settledFutureLongId = 1;
        settledFutureShortId = 1;
    }

    function setHub(address hub) external onlyOwner {
        _setHub(hub);
    }

    function moveToNextEpoch(
        uint256 _nextEpochEndTime,
        uint256 startFutureLongId,
        uint256 startFutureShortId,
        uint256[] calldata _futureLongPrices,
        uint256[] calldata _futureShortPrices
    ) public onlyOperator {
        require(block.timestamp > epochEndTime, "Previous epochEndTime has not yet passed");
        require(epochEndTime < _nextEpochEndTime, "nextEpochEndTime must be after previous epochEndTime");
        require(startFutureLongId == settledFutureLongId, "startFutureLongId does not match");
        require(startFutureShortId == settledFutureShortId, "startFutureShortId does not match");
        (int256 futureUPL, bool settledAll) = futureManager.getCheckedAllUpl(settledFutureLongId, settledFutureShortId, _futureLongPrices, _futureShortPrices);
        settledFutureLongId += _futureLongPrices.length;
        settledFutureShortId += _futureShortPrices.length;
        epochFutureUPL += futureUPL;
        if (settledAll) {
            ++epochNumber;
            epochEndTime = _nextEpochEndTime;
            liquidityPool.moveToNextEpoch(_nextEpochEndTime, epochFutureUPL);
            optionManager.moveToNextEpoch(_nextEpochEndTime);
            settledFutureLongId = 1;
            settledFutureShortId = 1;
            epochFutureUPL = 0;
            emit ExchangeStartNewEpoch(epochNumber, epochEndTime);
        }
    }

    // @dev: user transfer USDX from user balance to liqudity pool to get SLP (submit a mint SLP request)
    function userProvideLiquidity(uint256 _amount) public {
        address user = msgSender();
        userBalance.transfer(usd, user, address(liquidityPool), _amount);
        liquidityPool.lpProvideLiquidity(user, _amount);
        emit UserProvideLiquidity(user, epochNumber, _amount);
    }

    // @dev: user claim SLP from liquidity pool to user balance (submit a withdraw SLP request)
    function userClaimSLP(uint256 _epoch) public {
        address user = msgSender();
        uint256 userClaim = liquidityPool.withdrawUserSLPClaim(_epoch, user);
        userBalance.increaseBalance(address(liquidityPool), user, userClaim);
        emit UserClaimSLP(user, _epoch, userClaim);
    }

    // @dev: user burn SLP to get USDX (submit a burn SLP request)
    function userWithdrawLiquidity(uint256 _amount) public {
        address user = msgSender();
        userBalance.transfer(address(liquidityPool), user, address(liquidityPool), _amount);
        liquidityPool.lpWithdrawSLP(user, _amount);
        emit UserWithdrawLiquidity(user, epochNumber, _amount);
    }

    // @dev: user claim (USDX / unburned SLP) from liquidity pool to user balance after SLP burned.
    // trasnfer in ERC20 is implemented in liquidityPool.withdrawUsersLiquidity
    function userClaimWithdrawLiquidity(uint256 _epoch) public {
        address user = msgSender();
        uint256[] memory amounts = liquidityPool.withdrawUsersLiquidity(_epoch, user);
        if (amounts[0] > 0) {
            userBalance.increaseBalance(address(usd), user, amounts[0]);
        }
        if (amounts[1] > 0) {
            userBalance.increaseBalance((address(liquidityPool)), user, amounts[1]);
        }
        emit UserClaimWithdrawLiquidity(user, _epoch, amounts[0]);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

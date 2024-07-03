// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "../Delegatable.sol";

import "../../interfaces/IUserBalance.sol";
import "../../interfaces/ILiquidityPool.sol";
import "../../interfaces/IOption.sol";
import "../../libraries/Struct.sol";

error OptionManager__AddTokenError();
error OptionManager__InvalidEpochNumber();
error OptionManager__InvalidStrikeTime();

contract OptionManager is UUPSUpgradeable, OwnableUpgradeable, Delegatable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    ILiquidityPool public liquidityPool;
    IUserBalance public userBalance;
    IOption public option;

    address public baseTokenAddress;
    address public teamWalletAddress;
    address public exchangeManager;

    uint256 constant SETTLEPRICE = 100 * 10**4;
    uint256 public settleFee;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IUserBalance _userBalance,
        ILiquidityPool _liquidityPool,
        IOption _option
    ) external initializer {
        __Ownable_init();

        settleFee = 2 * 10**4;
        userBalance = _userBalance;
        liquidityPool = _liquidityPool;
        option = _option;
        baseTokenAddress = _liquidityPool.usd();
        teamWalletAddress = msg.sender;
    }

    event BatchAddOptionProduct(uint256 indexed option, uint256 epochNumber, uint256 strikeTime, uint256 productLength);
    event SettleOption(uint256 indexed option, uint256 epochNumber, uint256 batchNumber, uint256 settlePrice);
    event UserClaimProfit(address indexed user, uint256 settleSize, uint256 profit, uint256 settleFee);

    function setHub(address hub) external onlyOwner {
        _setHub(hub);
    }

    function setSettleFee(uint256 _settleFee) external onlyOwner {
        require(_settleFee % (10**4) == 0);
        settleFee = _settleFee;
    }

    function setTeamWalletAddress(address _teamWalletAddress) external onlyOwner {
        teamWalletAddress = _teamWalletAddress;
    }

    function setExchangeManager(address _manager) external onlyOwner {
        exchangeManager = _manager;
    }

    function moveToNextEpoch(uint256 _currentEpochEndTime) external {
        require(msg.sender == exchangeManager);
        for (uint256 i = 1; i < option.nextOptionId(); ++i) {
            option.moveToNextEpoch(i, _currentEpochEndTime);
        }
        option.incEpoch(_currentEpochEndTime);
    }

    function batchAddOptionProduct(
        uint256 _option,
        Struct.OptionProduct[] memory _optionProduct,
        uint256 _epochNumber,
        uint256 _strikeTime
    ) external onlyOperator {
        if (_epochNumber != option.globalCurrentEpoch()) {
            revert OptionManager__InvalidEpochNumber();
        }
        if (_strikeTime <= block.timestamp || _strikeTime > option.globalCurrentEpochEndTime()) {
            revert OptionManager__InvalidStrikeTime();
        }
        option.batchAddOptionProduct(_option, _optionProduct, _epochNumber, _strikeTime);
        emit BatchAddOptionProduct(_option, _epochNumber, _strikeTime, _optionProduct.length);
    }

    /* 
        @dev trader by option product
    */
    function makeOrder(
        uint256 _option,
        uint256 _epochNumber,
        uint256 _batchNumber,
        uint256 _productId,
        uint256 _maxPrice,
        uint256 _size,
        uint256 _deadline
    ) external payable {
        address _user = msgSender();
        if (_epochNumber != option.globalCurrentEpoch()) {
            revert OptionManager__InvalidEpochNumber();
        }
        uint256 maxCost = option.makeOrder{value: msg.value}(_user, _option, _epochNumber, _batchNumber, _productId, _maxPrice, _size, _deadline);
        userBalance.transfer(baseTokenAddress, _user, address(this), maxCost);
    }

    function cancelOrder(uint256 _nonce) external {
        address _user = msgSender();
        _cancelOrder(_user, _nonce, Struct.CancelReason.UserCanceled);
    }

    function _cancelOrder(
        address _user,
        uint256 _nonce,
        Struct.CancelReason reason
    ) internal {
        uint256 maxCost = option.cancelOrder(_user, _nonce, uint256(reason));
        _transferBaseToken(_user, maxCost);
    }

    function _transferBaseToken(address recipient, uint256 amount) internal {
        IERC20Upgradeable(baseTokenAddress).safeTransfer(recipient, amount);
        userBalance.increaseBalance(baseTokenAddress, recipient, amount);
    }

    /*
        @dev
        Admin fulfill orders, cost: real cost, maxCost: locked max cost, size: option size.
    */
    function fulfillOrder(
        address _user,
        uint256 _nonce,
        uint256 _price,
        address _feeReceiver
    ) external onlyOperator {
        (uint256 cost, uint256 maxCost, uint256 size, bool cancelled, uint256 optionId) = option.fulfillOrder(
            _user,
            _nonce,
            _price,
            _feeReceiver,
            liquidityPool.getAvailableToken(address(option)),
            SETTLEPRICE
        );
        if (cancelled) {
            _transferBaseToken(_user, maxCost);
        } else {
            _transferBaseToken(address(liquidityPool), cost);
            liquidityPool.increaseLiquidity(cost);
            liquidityPool.lockLiquidity(SETTLEPRICE * size, address(option), optionId);
            if (maxCost > cost) {
                _transferBaseToken(_user, maxCost - cost);
            }
        }
    }

    /* 
        @dev 
        Admin settle options, trasnfer 1 USDX * settleSize to Option Contracts.
    */
    function settleOption(
        uint256 _optionId,
        uint256 _epochNumber,
        uint256 _batchNumber,
        uint256 _settlePrice
    ) external onlyOperator {
        option.claimOptionSettlePrice(_optionId, _epochNumber, _batchNumber, _settlePrice);
        (uint256 traderTotalSize, uint256 traderSettleSize) = option.claimOptionSettlement(_optionId, _epochNumber, _batchNumber);
        liquidityPool.unlockLiquidity(traderTotalSize * SETTLEPRICE, address(option), _optionId);
        liquidityPool.transferUSD(address(option), traderSettleSize * SETTLEPRICE);
        emit SettleOption(_optionId, _epochNumber, _batchNumber, _settlePrice);
    }

    function userClaimOptionProfit(address _user, IOption.OptionClaimInfo[] calldata _data) public {
        uint256 settleSize = option.userClaimProfit(_user, _data);
        uint256 profit = settleSize * (SETTLEPRICE - settleFee);
        option.transfer(baseTokenAddress, address(userBalance), profit);
        userBalance.increaseBalance(baseTokenAddress, _user, profit);
        uint256 fee = settleSize * settleFee;
        option.transfer(baseTokenAddress, teamWalletAddress, fee);
        emit UserClaimProfit(_user, settleSize, profit, fee);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

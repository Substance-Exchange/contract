// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../../libraries/SubproductPausable.sol";
import "../../libraries/Struct.sol";
import "../../libraries/TransferHelper.sol";
import "../../interfaces/IFuture.sol";
import "../../interfaces/IFutureManager.sol";
import "../../interfaces/IFutureConfig.sol";
import "../../libraries/ConfigConstants.sol";

import "hardhat/console.sol";

error BaseFuture__PositionShouleNotBeLiquidited();
error BaseFuture__InvalidMaxProfitRatio();
error BaseFuture__GreaterThanMaxFee();
error BaseFuture__PositionInvalid();

abstract contract BaseFuture is UUPSUpgradeable, SubproductPausable {
    using SafeERC20 for IERC20;

    uint256 public nextFutureId;
    mapping(uint256 => string) public futureInfo;
    mapping(string => uint256) public futureLookup;

    mapping(uint256 => uint256) public sizeGlobal;
    mapping(uint256 => uint256) public costGlobal;
    mapping(uint256 => uint256) public borrowingFeeGlobal;
    mapping(uint256 => int256) public fundingFeeGlobal;

    mapping(uint256 => uint256) public currentEpoch;
    mapping(uint256 => uint256) public currentEpochEndTime;

    // Borrowing Fees
    mapping(uint256 => uint256) public borrowingFeePerToken;
    mapping(uint256 => uint256) public borrowingUpdateLastTime;

    // Funding Fees
    mapping(uint256 => uint256) public fundingUpdateLastTime;
    mapping(uint256 => int256) public fundingFeePerToken;

    mapping(uint256 => uint256) public reaminCollateralRatio;

    mapping(uint256 => mapping(address => Struct.Position)) public s_position;
    mapping(uint256 => mapping(address => uint256)) public positionOffset;

    /* 
        contract settings.
        if price decimal = 4, price = 12345, then the real price is price / 10 ** (priceDecimal)
        if contract value decimal = 3, 1 contract = 1000 token  
        if contract value decimal = -3, 1 contract = 0.001 token 
        1 contract value = 10 ** contractValueDecimal token = (10 ** contractValueDecimal) * price / (10 ** priceDecimal)

    */

    mapping(uint256 => uint8) public priceDecimal;
    mapping(uint256 => int8) public contractValueDecimal;
    mapping(uint256 => uint256) public maxProfitRatio;

    uint8 public feeDecimal;
    uint256 public fundingFeeUpdateInterval;
    uint256 public borrowingFeeUpdateInterval;
    uint256 public minimumCollateralUSD;
    address public futureManager;

    uint64 public maxTxFee;
    uint64 public maxPriceImpactFee;
    uint64 public constant MAX_FEE_PER_TOKEN_PRECISION = 10 ** 12;
    uint64 public maxFundingFee; // per second
    uint64 public maxBorrowingFee; // per second

    enum ForceClosePositionReason {
        Liquidation,
        MaxProfit
    }

    enum ChargeFeeReason {
        IncreasePosition,
        DecreasePosition,
        MaxProfitClosePosition,
        LiquidatePosition
    }

    event UpdatePosition(
        address indexed user,
        uint256 indexed futureId,
        uint256 price,
        bytes32 label,
        Struct.Position position,
        Struct.UpdatePositionResult result
    );
    event ForceClosePosition(address indexed user, uint256 indexed futureId, ForceClosePositionReason indexed reason, uint256 price);
    event ChargeFees(address indexed user, uint256 indexed futureId, ChargeFeeReason indexed reason, uint256 txFee, uint256 piFee, uint256 remianCollateral);

    event UpdateTradingVolume(uint256 indexed futureId, uint256 volume, bool increase);
    event UpdateCollateral(address indexed user, uint256 indexed futureId, bool increase, uint256 amount);

    event UpdateBorrowingFeePerToken(uint256 indexed futureId, uint256 rate);
    event UpdateFundingFeePerToken(uint256 indexed futureId, int256 rate);

    event UpdateOffset(address indexed user, uint256 indexed futureId, uint256 offset);

    event CreateFuture(uint256 indexed futureId, string name, uint8 priceDecimal, int8 contractValueDecimal);

    constructor() {
        _disableInitializers();
    }

    function createFuture(string calldata name, uint8 _priceDecimal, int8 _contractValueDecimal) external onlyOwner {
        maxProfitRatio[_createFuture(name, _priceDecimal, _contractValueDecimal)] = 10;
    }

    function initialize(uint8 _feeDecimal) external initializer {
        __SubproductPausable_init();
        nextFutureId = 1;
        feeDecimal = _feeDecimal;
        borrowingFeeUpdateInterval = 8 hours;
        fundingFeeUpdateInterval = 1 hours;
        minimumCollateralUSD = 10 ** 5;
        maxTxFee = uint64(10 ** _feeDecimal) / 1000;
        maxPriceImpactFee = (50 * uint64(10 ** _feeDecimal)) / 100;
        maxFundingFee = 69444; // 219%/Year
        maxBorrowingFee = 16688; // 52.63%/Year
    }

    function setMaxTxFee(uint64 _maxFee) external onlyOwner {
        maxTxFee = _maxFee;
    }

    function setMaxPriceImpactFee(uint64 _maxFee) external onlyOwner {
        maxPriceImpactFee = _maxFee;
    }

    function setMaxFundingFee(uint64 _maxFee) external onlyOwner {
        maxFundingFee = _maxFee;
    }

    function setMaxBorrowingFee(uint64 _maxFee) external onlyOwner {
        maxBorrowingFee = _maxFee;
    }

    function setMaxProfitRatio(uint256 _futureId, uint256 _maxProfitRatio) external onlyOwner {
        if (_maxProfitRatio == 0) {
            revert BaseFuture__InvalidMaxProfitRatio();
        }
        maxProfitRatio[_futureId] = _maxProfitRatio;
    }

    function setFeeDecimal(uint8 _decimal) external onlyOwner {
        feeDecimal = _decimal;
    }

    function setBorrowingFeeUpdateInterval(uint256 _interval) external onlyOwner {
        borrowingFeeUpdateInterval = _interval;
    }

    function setFundingFeeUpdateInterval(uint256 _interval) external onlyOwner {
        fundingFeeUpdateInterval = _interval;
    }

    function setMinimumCollateralUSD(uint256 _collateral) external onlyOwner {
        minimumCollateralUSD = _collateral;
    }

    function setFutureManager(address _manager) external onlyOwner {
        futureManager = _manager;
    }

    function _createFuture(string calldata name, uint8 _priceDecimal, int8 _contractValueDecimal) internal returns (uint256 futureId) {
        require(futureLookup[name] == 0, "BaseFuture: Future Already Existed");
        priceDecimal[nextFutureId] = _priceDecimal;
        contractValueDecimal[nextFutureId] = _contractValueDecimal;
        reaminCollateralRatio[nextFutureId] = 50;
        futureInfo[nextFutureId] = name;
        futureLookup[name] = nextFutureId;
        futureId = nextFutureId;
        emit CreateFuture(nextFutureId, name, _priceDecimal, _contractValueDecimal);
        ++nextFutureId;
    }

    function setRemainCollateralRatio(uint256 futureId, uint256 _reaminCollateralRatio) external onlyOwner {
        reaminCollateralRatio[futureId] = _reaminCollateralRatio;
    }

    function updateBorrowingFeePerToken(uint256 futureId, uint256 rate, uint256 _price) external onlyManager {
        uint256 lastTime = borrowingUpdateLastTime[futureId];
        uint256 interval = block.timestamp - lastTime;
        require(interval >= borrowingFeeUpdateInterval, "BaseFuture: Invalid updateBorrowingFees time");
        uint256 originalRate = borrowingFeePerToken[futureId];
        require(rate >= originalRate, "BaseFuture: Invalid BorrowingRate");
        uint256 diff = rate - originalRate;
        if (lastTime > 0 && ((diff * MAX_FEE_PER_TOKEN_PRECISION) / getUSDValue(futureId, 1, _price) / interval) > maxBorrowingFee)
            revert BaseFuture__GreaterThanMaxFee();
        borrowingFeePerToken[futureId] = rate;
        borrowingUpdateLastTime[futureId] = block.timestamp;

        // update global borrowing fees.
        borrowingFeeGlobal[futureId] += sizeGlobal[futureId] * diff;
        emit UpdateBorrowingFeePerToken(futureId, rate);
    }

    function updateFundingFees(uint256 _futureId, int256 _totalFundingFees, uint256 _price) external onlyManager {
        uint256 lastTime = fundingUpdateLastTime[_futureId];
        uint256 interval = block.timestamp - lastTime;
        require(interval >= fundingFeeUpdateInterval, "BaseFuture: Invalid updateFundingFees time");
        if (sizeGlobal[_futureId] > 0) {
            int256 feePerToken = _totalFundingFees / SafeCast.toInt256(sizeGlobal[_futureId]);
            if (
                feePerToken > 0 &&
                lastTime > 0 &&
                ((SafeCast.toUint256(feePerToken) * MAX_FEE_PER_TOKEN_PRECISION) / getUSDValue(_futureId, 1, _price) / interval) > maxFundingFee
            ) revert BaseFuture__GreaterThanMaxFee();
            fundingFeePerToken[_futureId] += feePerToken;
            fundingFeeGlobal[_futureId] += SafeCast.toInt256(sizeGlobal[_futureId]) * feePerToken;
            emit UpdateFundingFeePerToken(_futureId, fundingFeePerToken[_futureId]);
        }
        fundingUpdateLastTime[_futureId] = block.timestamp;
    }

    function _checkFutureManager() internal view {
        require(msg.sender == futureManager, "BaseFuture: CallerIsNotFutureManager");
    }

    function _isOrderImpl() internal view {
        require(IFutureManager(futureManager).orderImpl(msg.sender), "BaseFuture: NonOrderImpl");
    }

    modifier onlyOrderImpl() {
        _isOrderImpl();
        _;
    }

    modifier onlyManager() {
        _checkFutureManager();
        _;
    }

    function _checkFee(uint256 txFeeRatio, uint256 piFeeRatio) internal view {
        if (txFeeRatio > maxTxFee || piFeeRatio > maxPriceImpactFee) revert BaseFuture__GreaterThanMaxFee();
    }

    function checkFutureId(uint256 _futureId) public view {
        require(_futureId < nextFutureId, "BaseFuture: InvalidFutureId");
    }

    function _checkPositionOffset(address user, uint256 futureId) internal {
        if (s_position[futureId][user].tokenSize == 0) {
            emit UpdateOffset(user, futureId, ++positionOffset[futureId][user]);
        }
    }

    /*
        user initiative opearation 1 : increase position. 
    */
    function increasePosition(
        address _user,
        uint256 _futureId,
        uint256 _price,
        uint256 _increaseTokenSize,
        uint256 _increaseCollateral,
        Struct.FutureFeeInfo calldata _feeInfo,
        bytes32 label
    ) external whenSubproductNotPaused(_futureId) onlyOrderImpl returns (Struct.UpdatePositionResult memory result) {
        checkFutureId(_futureId);
        _checkFee(_feeInfo.txFeeRatio, _feeInfo.priceImpactRatio);
        Struct.Position memory position = s_position[_futureId][_user];
        Struct.ChargeFeeResult memory chargeFeeResult;
        // step1. check if the origin position should be liquidated[1] or max profit closed[2]. priority: [1] > [2].
        if (checkLiquidation(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.Liquidation, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.LiquidatePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else if (
            checkMaxProfitClosePosition(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)
        ) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.MaxProfit, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.MaxProfitClosePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else {
            // step2. execute increase position
            _updatePositionFees(_futureId, position);
            if (position.tokenSize == 0) {
                position.maxProfitRatio = maxProfitRatio[_futureId];
            }
            uint256 txFee = _chargeTransactionFee(_futureId, _increaseTokenSize, _price, _feeInfo.txFeeRatio);
            uint256 piFee = _chargePriceImpactFee(_futureId, _increaseTokenSize, _price, _feeInfo.priceImpactRatio);
            if (_increaseCollateral <= txFee + piFee + ((getUSDValue(_futureId, _increaseTokenSize, _price) * (reaminCollateralRatio[_futureId])) / 10000)) {
                // equal to increaseCollateral - txFee - piFee <= remainCollateralForNewPosition
                result.success = false;
            } else {
                if (txFee + piFee <= _feeInfo.availableUserBalance) {
                    result.userBalanceToTeam += txFee + piFee;
                } else {
                    // check new position collateral - cumulativeTeamFee
                    result.userBalanceToTeam += _feeInfo.availableUserBalance;
                    position.cumulativeTeamFee += txFee + piFee - _feeInfo.availableUserBalance;
                }
                result.userBalanceToCollateral += _increaseCollateral;
                position.collateral += _increaseCollateral;
                position.tokenSize += _increaseTokenSize;
                position.openCost += getUSDValue(_futureId, _increaseTokenSize, _price);
                emit ChargeFees(_user, _futureId, ChargeFeeReason.IncreasePosition, txFee, piFee, 0);
                result.success = true;
            }
        }
        _updatePositionStorage(_futureId, _user, position, result, _price, label);
        _checkPositionOffset(_user, _futureId);
    }

    /*
        user initiative operation 2 : increase collateral
     */
    function increaseCollateral(
        address _user,
        uint256 _futureId,
        uint256 _price,
        Struct.FutureFeeInfo memory _feeInfo,
        uint256 _increaseCollateral,
        bytes32 label
    ) external whenSubproductNotPaused(_futureId) onlyOrderImpl returns (Struct.UpdatePositionResult memory result) {
        checkFutureId(_futureId);
        _checkFee(_feeInfo.txFeeRatio, _feeInfo.priceImpactRatio);
        Struct.Position memory position = s_position[_futureId][_user];
        Struct.ChargeFeeResult memory chargeFeeResult;
        // step1. check if the origin position should be liquidated[1] or max profit closed[2]. priority: [1] > [2].
        if (checkLiquidation(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.Liquidation, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.LiquidatePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else if (
            checkMaxProfitClosePosition(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)
        ) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.MaxProfit, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.MaxProfitClosePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else {
            // step2. execute increase collateral
            result.userBalanceToCollateral += _increaseCollateral;
            position.collateral += _increaseCollateral;
            result.success = true;
        }
        _updatePositionStorage(_futureId, _user, position, result, _price, label);
        _checkPositionOffset(_user, _futureId);
    }

    /*
        user initiative operation 3 : decrease position
     */
    function decreasePosition(
        address _user,
        uint256 _futureId,
        uint256 _price,
        uint256 _decreaseTokenSize,
        Struct.FutureFeeInfo calldata _feeInfo,
        bytes32 label
    ) external whenSubproductNotPaused(_futureId) onlyOrderImpl returns (Struct.UpdatePositionResult memory result) {
        checkFutureId(_futureId);
        _checkFee(_feeInfo.txFeeRatio, _feeInfo.priceImpactRatio);
        Struct.Position memory position = s_position[_futureId][_user];
        Struct.ChargeFeeResult memory chargeFeeResult;
        // step1. check if the origin position should be liquidated[1] or max profit closed[2]. priority: [1] > [2].
        if (checkLiquidation(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.Liquidation, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.LiquidatePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else if (
            checkMaxProfitClosePosition(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)
        ) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.MaxProfit, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.MaxProfitClosePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else {
            // step2. execute decrease position
            uint256 txFee = _chargeTransactionFee(_futureId, _decreaseTokenSize, _price, _feeInfo.txFeeRatio);
            uint256 piFee = _chargePriceImpactFee(_futureId, _decreaseTokenSize, _price, _feeInfo.priceImpactRatio);
            _executePositionDecrease(_futureId, position, _decreaseTokenSize, _price, txFee + piFee, _feeInfo.availableLp, result);
            emit ChargeFees(_user, _futureId, ChargeFeeReason.DecreasePosition, txFee, piFee, 0);
            result.success = true;
        }
        _updatePositionStorage(_futureId, _user, position, result, _price, label);
        _checkPositionOffset(_user, _futureId);
    }

    function _executePositionDecrease(
        uint256 _futureId,
        Struct.Position memory position,
        uint256 _decreaseTokenSize,
        uint256 _price,
        uint256 _decreaseFees,
        uint256 _availableLp,
        Struct.UpdatePositionResult memory result
    ) internal view {
        // step1. calculate
        _updatePositionFees(_futureId, position);
        uint256 movedCollateral = (_decreaseTokenSize * position.collateral) / position.tokenSize;
        uint256 totalTeamFees = _decreaseFees + (position.cumulativeTeamFee * _decreaseTokenSize) / position.tokenSize;
        int256 feesToLp = (position.cumulativeFundingFee * SafeCast.toInt256(_decreaseTokenSize)) /
            SafeCast.toInt256(position.tokenSize) +
            SafeCast.toInt256((position.cumulativeBorrowingFee * _decreaseTokenSize) / position.tokenSize);

        // if user charge funding & borrowing fees from lp, the maximum fees is capped by availableLp.
        if (feesToLp < 0) {
            if (SafeCast.toUint256(-feesToLp) > _availableLp) {
                feesToLp = -SafeCast.toInt256(_availableLp);
            }
        }

        (int256 pnl, ) = getPositionPnl(_futureId, position, _price);
        pnl = (pnl * SafeCast.toInt256(_decreaseTokenSize)) / SafeCast.toInt256(position.tokenSize);

        position.collateral -= movedCollateral;
        if (pnl - feesToLp > 0) {
            // users gain from lp, user current asset = movedCollateral + userGainFromLp.
            uint256 userGainFromLp = SafeCast.toUint256(pnl - feesToLp);
            // charge team fees from movedCollateral first then charge team fees from userGainFromLp.
            if (totalTeamFees > 0) {
                uint256 chargeFee = Math.min(movedCollateral, totalTeamFees);
                result.collateralToTeam += chargeFee;
                movedCollateral -= chargeFee;
                totalTeamFees -= chargeFee;
            }
            if (totalTeamFees > 0) {
                uint256 chargeFee = Math.min(userGainFromLp, totalTeamFees);
                result.lpToTeam += chargeFee;
                userGainFromLp -= chargeFee;
                totalTeamFees -= chargeFee;
            }
            result.lpToUserBalance = userGainFromLp;
            result.collateralToUserBalance = movedCollateral;
        } else {
            // users loss to lp, user current asset = movedCollateral - userLossToLp.
            uint256 userLossToLp = SafeCast.toUint256(-(pnl - feesToLp));
            // firstly, charge userLossToLp from movedCollateral to Lp
            result.collateralToLp += Math.min(userLossToLp, movedCollateral);
            movedCollateral -= Math.min(userLossToLp, movedCollateral);
            // secondly, charge team fees from remaining collateral, here is movedCollateral
            result.collateralToTeam += Math.min(totalTeamFees, movedCollateral);
            movedCollateral -= Math.min(totalTeamFees, movedCollateral);
            // thirdly, send remaining collateral back to user balance.
            result.collateralToUserBalance += movedCollateral;
        }

        // update position infos by decrease tokens size : 1. realize cumulative fees
        position.cumulativeTeamFee -= (position.cumulativeTeamFee * _decreaseTokenSize) / position.tokenSize;
        position.cumulativeFundingFee -= (position.cumulativeFundingFee * SafeCast.toInt256(_decreaseTokenSize)) / SafeCast.toInt256(position.tokenSize);
        position.cumulativeBorrowingFee -= (position.cumulativeBorrowingFee * _decreaseTokenSize) / position.tokenSize;
        // 2. change position states.
        position.openCost -= (position.openCost * _decreaseTokenSize) / position.tokenSize;
        position.tokenSize -= _decreaseTokenSize;
    }

    /*
        user initiative operation 4 : decrease collateral
     */
    function decreaseCollateral(
        address _user,
        uint256 _futureId,
        uint256 _price,
        Struct.FutureFeeInfo memory _feeInfo,
        uint256 _decreaseCollateral,
        bytes32 label
    ) external whenSubproductNotPaused(_futureId) onlyOrderImpl returns (Struct.UpdatePositionResult memory result) {
        checkFutureId(_futureId);
        _checkFee(_feeInfo.txFeeRatio, _feeInfo.priceImpactRatio);
        Struct.Position memory position = s_position[_futureId][_user];
        Struct.ChargeFeeResult memory chargeFeeResult;
        // step1. check if the origin position should be liquidated[1] or max profit closed[2]. priority: [1] > [2].
        if (checkLiquidation(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.Liquidation, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.LiquidatePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else if (
            checkMaxProfitClosePosition(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)
        ) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.MaxProfit, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.MaxProfitClosePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
        } else {
            // step2. execute decrease collateral
            uint256 maxDecreaseCollateral = getMaxDecreaseCollateral(_futureId, position, _price, _feeInfo.predictedLiquidateFeeRatio);
            // calculate actual decreased collateral
            if (_decreaseCollateral > maxDecreaseCollateral) {
                _decreaseCollateral = maxDecreaseCollateral;
            }
            position.collateral -= _decreaseCollateral;
            result.collateralToUserBalance += _decreaseCollateral;
            result.success = true;
            emit UpdateCollateral(_user, _futureId, false, _decreaseCollateral);
        }
        _updatePositionStorage(_futureId, _user, position, result, _price, label);
        _checkPositionOffset(_user, _futureId);
    }

    /*
        manager operation 1: liquidate position
     */
    function liquidatePosition(
        address _user,
        uint256 _futureId,
        uint256 _price,
        Struct.FutureFeeInfo calldata _feeInfo
    ) external whenNotPaused onlyManager returns (Struct.UpdatePositionResult memory result) {
        checkFutureId(_futureId);
        _checkFee(_feeInfo.txFeeRatio, _feeInfo.priceImpactRatio);
        Struct.Position memory position = s_position[_futureId][_user];
        Struct.ChargeFeeResult memory chargeFeeResult;
        // step1. check if the origin position should be liquidated[1] or max profit closed[2]. priority: [1] > [2].
        bool liquidated = false;
        if (checkLiquidation(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.Liquidation, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.LiquidatePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
            liquidated = true;
        } else if (
            checkMaxProfitClosePosition(_futureId, position, _price, result, _feeInfo.predictedLiquidateFeeRatio, _feeInfo.availableLp, chargeFeeResult)
        ) {
            emit ForceClosePosition(_user, _futureId, ForceClosePositionReason.MaxProfit, _price);
            emit ChargeFees(
                _user,
                _futureId,
                ChargeFeeReason.MaxProfitClosePosition,
                chargeFeeResult.txFee,
                chargeFeeResult.piFee,
                chargeFeeResult.remainCollateral
            );
            _emptyPosition(position);
            liquidated = true;
        }
        require(liquidated, "BaseFuture: Position should not be liquidated.");
        _updatePositionStorage(_futureId, _user, position, result, _price, 0);
        _checkPositionOffset(_user, _futureId);
    }

    function getPositionPnl(uint256 _futureId, Struct.Position memory position, uint256 _price) public view virtual returns (int256 pnl, bool maxProfitReached);

    function _chargePriceImpactFee(uint256 _futureId, uint256 _increaseTokenSize, uint256 _price, uint256 _priceImpactRatio) public view returns (uint256) {
        return (getUSDValue(_futureId, _increaseTokenSize, _price) * _priceImpactRatio) / (10 ** (feeDecimal));
    }

    function _chargeTransactionFee(uint256 _futureId, uint256 _increaseTokenSize, uint256 _price, uint256 _txFeeRatio) public view returns (uint256) {
        return (getUSDValue(_futureId, _increaseTokenSize, _price) * _txFeeRatio) / (10 ** feeDecimal);
    }

    /*
        @dev calculate funding fee in position, fee can be nagative.
    */
    function calcFundingFee(uint256 _futureId, uint256 _tokenSize, int256 _entryFundingFeePerToken, int256 _cumulativeFundingFee) public view returns (int256) {
        return SafeCast.toInt256(_tokenSize) * (fundingFeePerToken[_futureId] - _entryFundingFeePerToken) + _cumulativeFundingFee;
    }

    /*
        @dev calculate borrowing fee in position, fee must be >= 0.
    */
    function calcBorrowingFee(
        uint256 _futureId,
        uint256 _tokenSize,
        uint256 _entryBorrowingFeePerToken,
        uint256 _cumulativeBorrowingFee
    ) public view returns (uint256) {
        return _tokenSize * (borrowingFeePerToken[_futureId] - _entryBorrowingFeePerToken) + _cumulativeBorrowingFee;
    }

    function _updatePositionFees(uint256 _futureId, Struct.Position memory position) internal view {
        position.cumulativeFundingFee += SafeCast.toInt256(position.tokenSize) * (fundingFeePerToken[_futureId] - position.entryFundingFeePerToken);
        position.cumulativeBorrowingFee += position.tokenSize * (borrowingFeePerToken[_futureId] - position.entryBorrowingFeePerToken);
        position.entryFundingFeePerToken = fundingFeePerToken[_futureId];
        position.entryBorrowingFeePerToken = borrowingFeePerToken[_futureId];
    }

    function transfer(address _token, address _dist, uint256 _tokenAmount) external onlyManager {
        IERC20(_token).safeTransfer(_dist, _tokenAmount);
    }

    /* 
        @dev liquidity pool calls getUnrealizedPnlInUSD to claculate profit/loss in each futures.
    */
    function getUnrealizedPnlInUSD(uint256 _futureId, uint256 _price) public view virtual returns (int256);

    function getOrderMaxLeverage(uint _futureId) public view returns (uint256) {
        return IFutureConfig(IFutureManager(futureManager).futureConfig()).getConfig(ConfigConstants.ORDER_MAX_LEVERAGE, _futureId);
    }

    function getMaxDecreaseCollateral(
        uint256 _futureId,
        Struct.Position memory position,
        uint256 _price,
        uint256 _predictedFeeRatio
    ) public view returns (uint256) {
        int256 collateral = SafeCast.toInt256(position.collateral);
        (int256 pnl, ) = getPositionPnl(_futureId, position, _price);
        uint256 positionValue = getUSDValue(_futureId, position.tokenSize, _price);
        int256 minRemainCollateral = (2 * SafeCast.toInt256(positionValue * (reaminCollateralRatio[_futureId] + _predictedFeeRatio))) / 10000;
        uint256 orderMaxLeverage = getOrderMaxLeverage(_futureId);
        // limit 1, user cannot reach leverage >= order max leaverge.
        if (minRemainCollateral < SafeCast.toInt256((positionValue * ConfigConstants.LEVERAGE_PRECISION) / orderMaxLeverage)) {
            minRemainCollateral = SafeCast.toInt256((positionValue * ConfigConstants.LEVERAGE_PRECISION) / orderMaxLeverage);
        }
        // limit 2, to prevent max profit closed after decreasing collateral
        if (pnl > 0) {
            int256 minRemainCollateralNotReachMaxProfit = pnl / SafeCast.toInt256(position.maxProfitRatio) + 1;
            if (minRemainCollateral < minRemainCollateralNotReachMaxProfit) {
                minRemainCollateral = minRemainCollateralNotReachMaxProfit;
            }
        }
        // limit 3, minimum collateral
        if (minRemainCollateral < SafeCast.toInt256(minimumCollateralUSD)) {
            minRemainCollateral = SafeCast.toInt256(minimumCollateralUSD);
        }
        int256 netValue = getNetValue(_futureId, position, _price);
        int256 maxDecreaseCollateral = netValue > collateral ? collateral - minRemainCollateral : netValue - minRemainCollateral;
        if (maxDecreaseCollateral > 0) {
            return SafeCast.toUint256(maxDecreaseCollateral);
        } else {
            return 0;
        }
    }

    function checkMaxProfitClosePosition(
        uint256 _futureId,
        Struct.Position memory position,
        uint256 _price,
        Struct.UpdatePositionResult memory result,
        uint256 _predictedFeeRatio,
        uint256 _availableLp,
        Struct.ChargeFeeResult memory chargeFeeResult
    ) public view returns (bool) {
        (, bool maxProfitReached) = getPositionPnl(_futureId, position, _price);
        if (maxProfitReached) {
            uint256 positionValue = getUSDValue(_futureId, position.tokenSize, _price);
            uint256 decreaseFees = (positionValue * _predictedFeeRatio) / 10000;
            _executePositionDecrease(_futureId, position, position.tokenSize, _price, decreaseFees, _availableLp, result);
            chargeFeeResult.txFee += decreaseFees;
            return true;
        }
        return false;
    }

    function getNetValue(uint256 _futureId, Struct.Position memory position, uint256 _price) public view returns (int256 netValueUSD) {
        netValueUSD = SafeCast.toInt256(position.collateral);
        (int256 pnl, ) = getPositionPnl(_futureId, position, _price);
        int256 fundingFee = calcFundingFee(_futureId, position.tokenSize, position.entryFundingFeePerToken, position.cumulativeFundingFee);
        uint256 borrowingFee = calcBorrowingFee(_futureId, position.tokenSize, position.entryBorrowingFeePerToken, position.cumulativeBorrowingFee);
        uint256 txFee = position.cumulativeTeamFee;
        netValueUSD = netValueUSD - fundingFee - SafeCast.toInt256(borrowingFee) + pnl - SafeCast.toInt256(txFee);
    }

    /*
        position value = token size * 1 contract value 
                       = token size * price * (10 ** (contractValueDecimal - priceDecimal))   if contractValueDecimal >= priceDecimal
                       = token size * price / (10 ** (priceDecimal - contractValueDecimal))   if priceDecimal < contractValueDecimal. 
    */
    function getUSDValue(uint256 _futureId, uint256 _tokenSize, uint256 _price) public view returns (uint256) {
        int8 diff = contractValueDecimal[_futureId] - int8(priceDecimal[_futureId]);
        if (diff >= 0) {
            return _tokenSize * _price * (10 ** SafeCast.toUint256(int256(diff)));
        } else {
            return (_tokenSize * _price) / (10 ** SafeCast.toUint256(-int256(diff)));
        }
    }

    function checkEnoughRemainingUSDValue(
        address _user,
        uint256 _futureId,
        uint256 _decreaseTokenSize,
        uint256 _price,
        uint256 _minUSDValue
    ) public view returns (bool) {
        if (s_position[_futureId][_user].tokenSize == _decreaseTokenSize) {
            return true;
        }
        return getUSDValue(_futureId, s_position[_futureId][_user].tokenSize - _decreaseTokenSize, _price) >= _minUSDValue;
    }

    function checkEnoughDecreaseTokenSize(address _user, uint256 _futureId, uint256 decreaseTokenSize) public view returns (bool) {
        return decreaseTokenSize > 0 && s_position[_futureId][_user].tokenSize >= decreaseTokenSize;
    }

    function getFutureInfo(string[] calldata tokens) external view returns (Struct.FutureInfo[] memory futureIds) {
        futureIds = new Struct.FutureInfo[](tokens.length);
        unchecked {
            for (uint256 i; i < tokens.length; ++i) {
                uint256 futureId = futureLookup[tokens[i]];
                futureIds[i] = Struct.FutureInfo({
                    futureId: futureId,
                    contractValueDecimal: contractValueDecimal[futureId],
                    priceDecimal: priceDecimal[futureId],
                    reaminCollateralRatio: reaminCollateralRatio[futureId],
                    fundingFeePerToken: fundingFeePerToken[futureId],
                    borrowingFeePerToken: borrowingFeePerToken[futureId],
                    sizeGlobal: sizeGlobal[futureId],
                    costGlobal: costGlobal[futureId]
                });
            }
        }
    }

    function getGlobalUSDValue(uint256 _futureId, uint256 _price) external view returns (uint256) {
        return getUSDValue(_futureId, sizeGlobal[_futureId], _price);
    }

    function checkLiquidation(
        uint256 _futureId,
        Struct.Position memory position,
        uint256 _price,
        Struct.UpdatePositionResult memory result,
        uint256 _predictedFeeRatio,
        uint256 _availableLp,
        Struct.ChargeFeeResult memory chargeFeeResult
    ) public view returns (bool) {
        // not change position
        if (position.tokenSize > 0) {
            uint256 positionValue = getUSDValue(_futureId, position.tokenSize, _price);
            int256 netValueUSD = getNetValue(_futureId, position, _price);
            uint256 txFee = (positionValue * _predictedFeeRatio) / 10000;
            uint256 remainCollateral = (positionValue * (reaminCollateralRatio[_futureId] + _predictedFeeRatio)) / 10000;
            if (netValueUSD <= SafeCast.toInt256(remainCollateral)) {
                _executePositionDecrease(_futureId, position, position.tokenSize, _price, remainCollateral, _availableLp, result);
                chargeFeeResult.txFee += txFee;
                chargeFeeResult.remainCollateral += remainCollateral - txFee;
                return true;
            }
        }
        return false;
    }

    function _updatePositionStorage(
        uint256 _futureId,
        address _user,
        Struct.Position memory newPosition,
        Struct.UpdatePositionResult memory result,
        uint256 _price,
        bytes32 label
    ) internal {
        Struct.Position memory originPosition = s_position[_futureId][_user];
        // update global token size
        if (newPosition.tokenSize > originPosition.tokenSize) {
            sizeGlobal[_futureId] += newPosition.tokenSize - originPosition.tokenSize;
            emit UpdateTradingVolume(_futureId, getUSDValue(_futureId, newPosition.tokenSize - originPosition.tokenSize, _price), true);
        } else {
            sizeGlobal[_futureId] -= originPosition.tokenSize - newPosition.tokenSize;
            emit UpdateTradingVolume(_futureId, getUSDValue(_futureId, originPosition.tokenSize - newPosition.tokenSize, _price), false);
        }
        // update open cost
        if (newPosition.openCost > originPosition.openCost) {
            costGlobal[_futureId] += newPosition.openCost - originPosition.openCost;
        } else {
            costGlobal[_futureId] -= originPosition.openCost - newPosition.openCost;
        }

        // borrowing fees realized = origin position borrowing fees - new position borrowing fees
        borrowingFeeGlobal[_futureId] -=
            calcBorrowingFee(_futureId, originPosition.tokenSize, originPosition.entryBorrowingFeePerToken, originPosition.cumulativeBorrowingFee) -
            calcBorrowingFee(_futureId, newPosition.tokenSize, newPosition.entryBorrowingFeePerToken, newPosition.cumulativeBorrowingFee);

        // funding fees realized = origin position funding fees - new position funding fees
        fundingFeeGlobal[_futureId] -=
            calcFundingFee(_futureId, originPosition.tokenSize, originPosition.entryFundingFeePerToken, originPosition.cumulativeFundingFee) -
            calcFundingFee(_futureId, newPosition.tokenSize, newPosition.entryFundingFeePerToken, newPosition.cumulativeFundingFee);

        // update locked/unlocked usd.
        if (newPosition.collateral > originPosition.collateral) {
            result.lockedTokenSize += (newPosition.collateral - originPosition.collateral) * newPosition.maxProfitRatio;
        } else {
            result.unlockedTokenSize += (originPosition.collateral - newPosition.collateral) * newPosition.maxProfitRatio;
        }
        s_position[_futureId][_user] = newPosition;
        // this line should never be reached.
        if (newPosition.collateral == 0 && newPosition.tokenSize > 0) {
            revert BaseFuture__PositionInvalid();
        }
        emit UpdatePosition(_user, _futureId, _price, label, newPosition, result);
    }

    function _emptyPosition(Struct.Position memory position) internal pure {
        position.openCost = 0;
        position.tokenSize = 0;
        position.collateral = 0;
        position.cumulativeFundingFee = 0;
        position.cumulativeBorrowingFee = 0;
        position.cumulativeTeamFee = 0;
    }

    function getLockedTokenSize(uint256 _futureId, address _user, uint256 _increaseCollateral) public view returns (uint256) {
        Struct.Position storage position = s_position[_futureId][_user];
        return _increaseCollateral * (position.tokenSize == 0 ? maxProfitRatio[_futureId] : position.maxProfitRatio);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

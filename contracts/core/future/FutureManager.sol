// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../Delegatable.sol";

import "../../interfaces/ILiquidityPool.sol";
import "../../interfaces/IUserBalance.sol";
import "../../interfaces/IPriceOracle.sol";
import "../../interfaces/IFuture.sol";
import "../../libraries/Struct.sol";

error FutureManager__CreateOrderAccessError();
error FutureManager__CancelOrderAccessError();
error FutureManager__InvalidTokenSizeToDecrease();
error FutureManager__InvalidFutureId();

contract FutureManager is UUPSUpgradeable, OwnableUpgradeable, Delegatable {
    struct FundingFeeUpdateInfo {
        string name;
        uint256 rate;
        uint256 price;
    }

    struct FundingFeeUpdateInfoV2 {
        string name;
        uint256 baseRate;
        uint256 linearRate;
        uint256 price;
    }

    struct BorrowingFeeUpdateInfo {
        Struct.FutureType futureType;
        uint256 borrowingFeePerToken;
        uint256 futureId;
        uint256 price;
    }

    address public tokenUSD;
    address public teamAddress;

    ILiquidityPool public liquidityPool;
    IUserBalance public userBalance;
    IFuture public futureLong;
    IFuture public futureShort;
    IPriceOracle public oracle;

    uint256 public minExecutionFee;

    mapping(address => bool) public orderImpl;
    address public futureConfig;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IUserBalance _userBalance,
        ILiquidityPool _liquidityPool,
        IFuture _long,
        IFuture _short,
        IPriceOracle _oracle,
        address _futureConfig,
        address _teamAddress,
        uint256 _minExecutionFee
    ) external initializer {
        __Ownable_init();

        userBalance = _userBalance;
        liquidityPool = _liquidityPool;
        futureLong = _long;
        futureShort = _short;
        oracle = _oracle;
        tokenUSD = _liquidityPool.usd();
        futureConfig = _futureConfig;
        teamAddress = _teamAddress;
        minExecutionFee = _minExecutionFee;
    }

    function setMinExecutionFee(uint256 _fee) external onlyOwner {
        minExecutionFee = _fee;
    }

    function setHub(address hub) external onlyOwner {
        _setHub(hub);
    }

    function setTeamAddress(address _teamAddress) external onlyOwner {
        teamAddress = _teamAddress;
    }

    function getFutureByType(Struct.FutureType _futureType) public view returns (address) {
        if (_futureType == Struct.FutureType.Long) {
            return address(futureLong);
        } else if (_futureType == Struct.FutureType.Short) {
            return address(futureShort);
        } else {
            revert("FutureManager: Invalid FutureType");
        }
    }

    function setOrderImpl(address[] calldata impls, bool[] calldata status) external onlyOwner {
        require(impls.length == status.length, "FutureManager: InvalidData");
        unchecked {
            for (uint256 i; i < impls.length; ++i) {
                orderImpl[impls[i]] = status[i];
            }
        }
    }

    function _isOrderImpl() internal view {
        require(orderImpl[msg.sender], "FutureManager: NonOrderImpl");
    }

    modifier onlyOrderImpl() {
        _isOrderImpl();
        _;
    }

    function takeUserFund(address user, address future, uint256 amount) external onlyOrderImpl {
        userBalance.transfer(tokenUSD, user, future, amount);
    }

    function giveUserFund(address user, address future, uint256 amount) external onlyOrderImpl {
        IFuture(future).transfer(tokenUSD, address(userBalance), amount);
        userBalance.increaseBalance(tokenUSD, user, amount);
    }

    function _settleFuture(address _future, uint256 _futureId, address _user, Struct.UpdatePositionResult memory _result) private {
        // P0, locked = 0 && unlocked > 0
        if (_result.lockedTokenSize > 0) {
            liquidityPool.lockLiquidity(_result.lockedTokenSize, _future, _futureId);
        }
        // locked > 0 && unlocked = 0
        if (_result.unlockedTokenSize > 0) {
            liquidityPool.unlockLiquidity(_result.unlockedTokenSize, _future, _futureId);
        }
        // P1, lp pays userBalance / team
        if (_result.lpToUserBalance > 0) {
            liquidityPool.transferUSD(address(userBalance), _result.lpToUserBalance);
            userBalance.increaseBalance(tokenUSD, _user, _result.lpToUserBalance);
        }
        if (_result.lpToTeam > 0) {
            liquidityPool.transferUSD(address(teamAddress), _result.lpToTeam);
        }
        if (_result.userBalanceToTeam > 0) {
            userBalance.transfer(tokenUSD, _user, address(teamAddress), _result.userBalanceToTeam);
        }
        // P3. collateral to lp / team / userbalance
        if (_result.collateralToLp > 0) {
            IFuture(_future).transfer(tokenUSD, address(liquidityPool), _result.collateralToLp);
            liquidityPool.increaseLiquidity(_result.collateralToLp);
        }
        if (_result.collateralToTeam > 0) {
            IFuture(_future).transfer(tokenUSD, address(teamAddress), _result.collateralToTeam);
        }
        if (_result.collateralToUserBalance > 0) {
            IFuture(_future).transfer(tokenUSD, address(userBalance), _result.collateralToUserBalance);
            userBalance.increaseBalance(tokenUSD, _user, _result.collateralToUserBalance);
        }
    }

    function getCheckedAllUpl(
        uint256 startFutureLongId,
        uint256 startFutureShortId,
        uint256[] calldata _futureLongPrices,
        uint256[] calldata _futureShortPrices
    ) external view returns (int256 upl, bool settledAll) {
        if (
            startFutureLongId + _futureLongPrices.length > IFuture(futureLong).nextFutureId() ||
            startFutureShortId + _futureShortPrices.length > IFuture(futureShort).nextFutureId()
        ) {
            revert FutureManager__InvalidFutureId();
        }
        unchecked {
            address long = address(futureLong);
            for (uint256 i; i < _futureLongPrices.length; ++i) {
                oracle.validatePrice(long, startFutureLongId + i, _futureLongPrices[i]);
            }
            address short = address(futureShort);
            for (uint256 i; i < _futureShortPrices.length; ++i) {
                oracle.validatePrice(short, startFutureShortId + i, _futureShortPrices[i]);
            }
        }
        settledAll =
            startFutureLongId + _futureLongPrices.length == IFuture(futureLong).nextFutureId() &&
            startFutureShortId + _futureShortPrices.length == IFuture(futureShort).nextFutureId();
        for (uint256 i; i < _futureLongPrices.length; ++i) {
            upl += futureLong.getUnrealizedPnlInUSD(startFutureLongId + i, _futureLongPrices[i]);
        }
        for (uint256 i; i < _futureShortPrices.length; ++i) {
            upl += futureShort.getUnrealizedPnlInUSD(startFutureShortId + i, _futureShortPrices[i]);
        }
        return (upl, settledAll);
    }

    function updateExchangeByUpdatePositionResult(
        address _future,
        uint256 _futureId,
        address _user,
        Struct.UpdatePositionResult memory _result
    ) external onlyOrderImpl {
        _settleFuture(_future, _futureId, _user, _result);
    }

    function liquidatePosition(
        uint256 _futureId,
        address _user,
        uint256 _curPrice,
        Struct.OrderFeeInfo calldata _feeInfo,
        Struct.FutureType _futureType
    ) external onlyOperator {
        address _future = getFutureByType(_futureType);
        oracle.validatePrice(_future, _futureId, _curPrice);
        Struct.UpdatePositionResult memory result = IFuture(_future).liquidatePosition(
            _user,
            _futureId,
            _curPrice,
            getFeeInfoWithAvailableToken(_user, false, _feeInfo)
        );
        _settleFuture(_future, _futureId, _user, result);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function checkFutureLockedSizeEnough(address _future, uint256 _futureId, address _user, uint256 increaseCollateral) public view returns (bool) {
        uint256 avalibleTokenForCurFuture = liquidityPool.getAvailableTokenForFuture(_future, _futureId);
        uint256 lockedTokenSize = IFuture(_future).getLockedTokenSize(_futureId, _user, increaseCollateral);
        return avalibleTokenForCurFuture >= lockedTokenSize;
    }

    function updateFundingFee(FundingFeeUpdateInfo[] calldata data) external onlyOperator {
        for (uint256 i; i < data.length; ++i) {
            FundingFeeUpdateInfo memory info = data[i];
            address futureShortAddress = address(futureShort);
            address futureLongAddress = address(futureLong);

            uint256 futureIdShort = IFuture(futureShortAddress).futureLookup(info.name);
            uint256 futureIdLong = IFuture(futureLongAddress).futureLookup(info.name);

            require(futureIdShort != 0, "FutureManager: Invalid short token name.");
            require(futureIdLong != 0, "FutureManager: Invalid long token name.");

            uint256 globalLongUSDValue = IFuture(futureLongAddress).getGlobalUSDValue(futureIdLong, info.price);
            uint256 gloablShortUSDValue = IFuture(futureShortAddress).getGlobalUSDValue(futureIdShort, info.price);

            if (globalLongUSDValue > gloablShortUSDValue) {
                // long pays short
                uint256 collectFees = ((globalLongUSDValue - gloablShortUSDValue) * info.rate) / 10 ** 8;
                IFuture(futureLongAddress).updateFundingFees(futureIdLong, SafeCast.toInt256(collectFees), info.price);
                IFuture(futureShortAddress).updateFundingFees(futureIdShort, -SafeCast.toInt256(collectFees), info.price);
            } else {
                // short pays long
                uint256 collectFees = ((gloablShortUSDValue - globalLongUSDValue) * info.rate) / 10 ** 8;
                IFuture(futureLongAddress).updateFundingFees(futureIdLong, -SafeCast.toInt256(collectFees), info.price);
                IFuture(futureShortAddress).updateFundingFees(futureIdShort, SafeCast.toInt256(collectFees), info.price);
            }
        }
    }

    function updateFundingFeeV2(FundingFeeUpdateInfoV2[] calldata data) external onlyOperator {
        uint256 lpPooled = liquidityPool.poolAmount();
        uint256 longUpdateInterval = IFuture(address(futureLong)).fundingFeeUpdateInterval();
        uint256 shortUpdateInterval = IFuture(address(futureShort)).fundingFeeUpdateInterval();
        for (uint256 i; i < data.length; ++i) {
            FundingFeeUpdateInfoV2 memory info = data[i];
            // valiadate token_name && future_id
            uint256 futureIdLong = IFuture(address(futureLong)).futureLookup(info.name);
            uint256 futureIdShort = IFuture(address(futureShort)).futureLookup(info.name);
            require(futureIdLong != 0, "FutureManager: Invalid long token name.");
            require(futureIdShort != 0, "FutureManager: Invalid short token name.");
            // if maxLockRatio for Long & Short is not equal, then higher token size does not lead to higher funding fee rate.
            uint256 maxLockRatio = liquidityPool.maxLockedRatio(address(futureLong), futureIdLong);
            require(maxLockRatio == liquidityPool.maxLockedRatio(address(futureShort), futureIdShort), "FutureManager: Invalid FutureConfig");
            // maxLockRatio precision is 10^4, if the maxLockRatio is not set, then maxLockRatio = 1.0 by default.
            // calculate funding fee rates by formula:
            // rate (daily) = baseRate + linearRate * maxLockedRatio * position_value / (lp_amount * maxLockRatio), 0.08% + 8% * position_value / (lp_amount * maxLockRatio)
            // rate precision is 10^6, and capped by 100%
            if (maxLockRatio == 0) {
                maxLockRatio = 10 ** 4;
            }
            uint256 longGlobalUSDValue = IFuture(address(futureLong)).getGlobalUSDValue(futureIdLong, info.price);
            uint256 shortGlobalUSDValue = IFuture(address(futureShort)).getGlobalUSDValue(futureIdShort, info.price);
            uint256 longRate = info.baseRate + (info.linearRate * longGlobalUSDValue * (10 ** 4)) / ((lpPooled * maxLockRatio));
            uint256 shortRate = info.baseRate + (info.linearRate * shortGlobalUSDValue * (10 ** 4)) / ((lpPooled * maxLockRatio));

            longRate = (Math.min(10 ** 8, longRate) * longUpdateInterval) / 86400;
            shortRate = (Math.min(10 ** 8, shortRate) * shortUpdateInterval) / 86400;

            // check the fees direction, from Long to Short or Short to Long.
            uint256 feesToLp;
            bool isLongPaysShort;
            {
                uint256 longSize = IFuture(address(futureLong)).sizeGlobal(futureIdLong);
                uint256 shortSize = IFuture(address(futureShort)).sizeGlobal(futureIdShort);
                isLongPaysShort = longSize > shortSize;
                // fees to liquidityPool
                if (longSize > 0 || shortSize > 0) {
                    feesToLp = isLongPaysShort
                        ? (longGlobalUSDValue * longRate * (longSize - shortSize)) / (longSize * 10 ** 8)
                        : (shortGlobalUSDValue * shortRate * (shortSize - longSize)) / (shortSize * 10 ** 8);
                }
            }
            // fees from Long to Short / or from Short to Long
            uint256 feesToOpt = isLongPaysShort
                ? (shortGlobalUSDValue * (longRate - shortRate)) / (10 ** 8)
                : (longGlobalUSDValue * (shortRate - longRate)) / (10 ** 8);
            if (isLongPaysShort) {
                IFuture(address(futureLong)).updateFundingFees(futureIdLong, SafeCast.toInt256(feesToLp + feesToOpt), info.price);
                IFuture(address(futureShort)).updateFundingFees(futureIdShort, -SafeCast.toInt256(feesToOpt), info.price);
            } else {
                IFuture(address(futureShort)).updateFundingFees(futureIdShort, SafeCast.toInt256(feesToLp + feesToOpt), info.price);
                IFuture(address(futureLong)).updateFundingFees(futureIdLong, -SafeCast.toInt256(feesToOpt), info.price);
            }
        }
    }

    function updateBorrowingFeePerToken(BorrowingFeeUpdateInfo[] calldata data) external onlyOperator {
        for (uint256 i; i < data.length; ++i) {
            BorrowingFeeUpdateInfo memory info = data[i];
            IFuture(getFutureByType(info.futureType)).updateBorrowingFeePerToken(info.futureId, info.borrowingFeePerToken, info.price);
        }
    }

    function getFeeInfoWithAvailableToken(
        address user,
        bool includeUserBalance,
        Struct.OrderFeeInfo memory info
    ) public view returns (Struct.FutureFeeInfo memory fee) {
        fee.txFeeRatio = info.txFeeRatio;
        fee.priceImpactRatio = info.priceImpactRatio;
        fee.predictedLiquidateFeeRatio = info.predictedLiquidateFeeRatio;
        fee.availableUserBalance = includeUserBalance ? userBalance.userBalance(tokenUSD, user) : 0;
        fee.availableLp = liquidityPool.getTotalAvailableToken();
    }
}

// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

library Struct {
    struct OptionProduct {
        bool isCall;
        uint256 strikePrice;
    }

    struct OptionPosInfo {
        uint256 totalCost;
        uint256 totalSize;
        uint8 isSettle;
    }

    struct OptionOrder {
        uint256 optionId;
        uint256 epochId;
        uint256 batch;
        uint256 productId;
        uint256 maxPrice;
        uint256 size;
        uint256 deadline;
        uint256 executionFee;
        bool valid;
    }

    enum FutureType {
        Long,
        Short
    }

    enum CancelReason {
        UserCanceled,
        NotEnoughLP,
        NotEnoughTokenSize,
        NoExistingPosition,
        LessThanMinUSDValue,
        MoreThanMaxLeverage,
        LessThanMinLeverage,
        checkEnoughRemainingUSDValue
    }

    struct FutureIncreaseLimitOrder {
        address future;
        uint256 futureId;
        uint256 increaseCollateral;
        uint256 increaseTokenSize;
        uint256 price;
        uint256 executionFee;
        bool valid;
    }

    struct FutureDecreaseLimitOrder {
        address future;
        uint256 futureId;
        uint256 decreaseTokenSize;
        uint256 price;
        uint256 executionFee;
        uint256 offset;
        bool valid;
    }

    struct FutureIncreaseMarketOrder {
        address future;
        uint256 futureId;
        uint256 increaseCollateral;
        uint256 increaseTokenSize;
        uint256 executePrice;
        uint256 deadline;
        uint256 executionFee;
        bool valid;
    }

    struct FutureDecreaseMarketOrder {
        address future;
        uint256 futureId;
        uint256 decreaseTokenSize;
        uint256 executePrice;
        uint256 deadline;
        uint256 executionFee;
        bool valid;
    }

    struct FutureStopOrder {
        address future;
        uint256 futureId;
        uint256 decreaseTokenSize;
        uint256 triggerPrice;
        uint256 executionFee;
        uint256 offset;
        bool isStopLoss;
        bool valid;
    }

    struct FutureInfo {
        uint256 futureId;
        int8 contractValueDecimal;
        uint8 priceDecimal;
        uint256 reaminCollateralRatio;
        int256 fundingFeePerToken;
        uint256 borrowingFeePerToken;
        uint256 sizeGlobal;
        uint256 costGlobal;
    }

    struct UpdateCollateralOrder {
        address future;
        uint256 futureId;
        uint256 deltaAmount;
        uint256 executionFee;
        uint256 offset;
        bool increase;
        bool valid;
    }

    struct UpdatePositionResult {
        uint256 userBalanceToTeam;
        uint256 userBalanceToCollateral;
        uint256 collateralToLp;
        uint256 collateralToTeam;
        uint256 collateralToUserBalance;
        uint256 lpToUserBalance;
        uint256 lpToTeam;
        uint256 lockedTokenSize;
        uint256 unlockedTokenSize;
        bool success;
    }

    struct ChargeFeeResult {
        uint256 txFee;
        uint256 piFee;
        uint256 remainCollateral;
    }

    struct OrderFeeInfo {
        uint256 txFeeRatio;
        uint256 priceImpactRatio;
        uint256 predictedLiquidateFeeRatio;
        address feeReceiver;
    }

    struct FutureFeeInfo {
        uint256 txFeeRatio;
        uint256 priceImpactRatio;
        uint256 availableUserBalance;
        uint256 availableLp;
        uint256 predictedLiquidateFeeRatio;
    }

    struct Position {
        uint256 openCost;
        uint256 tokenSize;
        uint256 collateral;
        int256 entryFundingFeePerToken;
        int256 cumulativeFundingFee;
        uint256 entryBorrowingFeePerToken;
        uint256 cumulativeBorrowingFee;
        uint256 maxProfitRatio;
        uint256 cumulativeTeamFee;
    }
}

// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./BaseFuture.sol";

contract FutureShort is BaseFuture {
    // @dev traders profit = upl - borrowing fees - funding fees
    function getUnrealizedPnlInUSD(uint256 _futureId, uint256 _price) public view override returns (int256) {
        return
            SafeCast.toInt256(costGlobal[_futureId]) -
            SafeCast.toInt256(getUSDValue(_futureId, sizeGlobal[_futureId], _price)) -
            SafeCast.toInt256(borrowingFeeGlobal[_futureId]) -
            fundingFeeGlobal[_futureId];
    }

    function getPositionPnl(
        uint256 _futureId,
        Struct.Position memory position,
        uint256 _price
    ) public view override returns (int256 pnl, bool maxProfitReached) {
        if (position.tokenSize > 0) {
            int256 maxProfit = SafeCast.toInt256(position.collateral * position.maxProfitRatio);
            uint256 positionValue = getUSDValue(_futureId, position.tokenSize, _price);
            pnl = SafeCast.toInt256(position.openCost) - SafeCast.toInt256(positionValue);
            if (pnl > maxProfit) {
                pnl = maxProfit;
                maxProfitReached = true;
            }
        }
    }
}

// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

contract SubstanceOracle is Ownable {
    uint8 public decimals;
    int256 private _price;
    uint256 private _updatedAt;

    event UpdatePrice(int256 price);

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function setPriceDecimals(uint8 _decimals) external onlyOwner {
        decimals = _decimals;
    }

    function setPrice(int128 _p) external onlyOwner {
        _price = _p;
        _updatedAt = block.timestamp;
        emit UpdatePrice(_p);
    }

    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        answer = _price;
        updatedAt = block.timestamp;
    }
}

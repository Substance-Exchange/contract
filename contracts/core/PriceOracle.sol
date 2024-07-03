// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../libraries/SubstancePausable.sol";
import "hardhat/console.sol";

error PriceOracle__InvalidPrice(int256 oraclePrice);

contract PriceOracle is UUPSUpgradeable, SubstancePausable {
    struct UpdateOracle {
        address product;
        uint256 subproduct;
        OracleInfo info;
    }

    struct OracleInfo {
        address oracle;
        uint64 acceptanceThreshold;
        uint32 decimalOffset;
    }

    uint256 public constant ACCEPTANCE_PRECISION = 10000;

    mapping(bytes32 => OracleInfo) public oracle;

    event OracleUpdated(address indexed product, uint256 indexed subproduct, OracleInfo oracleInfo);

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __SubstancePausable_init();
    }

    function getProductHash(address product, uint256 subproduct) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(product, subproduct));
    }

    function setOracle(UpdateOracle[] calldata data) external onlyOwner {
        unchecked {
            for (uint256 i; i < data.length; ++i) {
                oracle[getProductHash(data[i].product, data[i].subproduct)] = data[i].info;
                emit OracleUpdated(data[i].product, data[i].subproduct, data[i].info);
            }
        }
    }

    function validatePrice(
        address product,
        uint256 subproduct,
        uint256 price
    ) external view {
        (bool success, int256 op) = validateSubproductPrice(getProductHash(product, subproduct), price);
        if (!success) {
            revert PriceOracle__InvalidPrice(op);
        }
    }

    function validateSubproductPrice(bytes32 product, uint256 price) internal view returns (bool, int256) {
        // Substance Oracle Price is always 6 decimals
        OracleInfo memory info = oracle[product];
        if (info.oracle != address(0)) {
            uint8 oracleDecimals = AggregatorV3Interface(info.oracle).decimals();
            (, int256 oraclePrice, , , ) = AggregatorV3Interface(info.oracle).latestRoundData();
            if (oraclePrice <= 0) revert PriceOracle__InvalidPrice(oraclePrice);
            price = (price * (10**oracleDecimals)) / (10**(6 + info.decimalOffset));
            int256 acceptanceRange = oraclePrice * SafeCast.toInt256(SafeCast.toUint64(info.acceptanceThreshold));
            int256 diff = (oraclePrice - SafeCast.toInt256(price)) * SafeCast.toInt256(ACCEPTANCE_PRECISION);
            if ((diff < 0 && (-diff > acceptanceRange)) || (diff >= 0 && (diff > acceptanceRange))) {
                return (false, oraclePrice);
            }
        }
        return (true, 0);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

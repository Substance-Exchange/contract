// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

error FutureConfig__ConfigNotSet();

contract FutureConfig is UUPSUpgradeable, OwnableUpgradeable {
    mapping(bytes32 => uint256) public config;

    event UpdateConfig(bytes32 indexed key, uint256 indexed futureId, uint256 value);
    event UpdateGlobalConfig(bytes32 indexed key, uint256 value);

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init();
    }

    function getConfig(bytes32 key, uint256 futureId) public view returns (uint256) {
        uint256 productConfig = config[keccak256(abi.encodePacked(key, futureId))];
        if (productConfig & 0x1 == 1) {
            return productConfig >> 1;
        }
        uint256 globalConfig = config[keccak256(abi.encodePacked(key))];
        if (globalConfig & 0x1 == 1) {
            return globalConfig >> 1;
        }
        revert FutureConfig__ConfigNotSet();
    }

    // @dev Set Config with uint256 max value means to unset value
    // This function will put a flag with valid value
    function _setConfig(bytes32 key, uint256 value) internal {
        if (value == type(uint256).max) {
            config[key] = 0;
        } else {
            config[key] = value << 1 | 0x1;
        }
    }

    function setConfig(bytes32[] calldata key, uint256[] calldata futureId, uint256[] calldata value) public onlyOwner {
        require(key.length == futureId.length && futureId.length == value.length, "invalid data");
        unchecked {
            for (uint256 i; i < key.length; ++i) {
                _setConfig(keccak256(abi.encodePacked(key[i], futureId[i])), value[i]);
                emit UpdateConfig(key[i], futureId[i], value[i]);
            }
        }
    }

    function setGlobalConfig(bytes32[] calldata key, uint256[] calldata value) public onlyOwner {
        require(key.length == value.length, "invalid data");
        unchecked {
            for (uint256 i; i < key.length; ++i) {
                _setConfig(keccak256(abi.encodePacked(key[i])), value[i]);
                emit UpdateGlobalConfig(key[i], value[i]);
            }
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

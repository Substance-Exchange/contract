// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../../Delegatable.sol";
import "../../../interfaces/IFutureManager.sol";
import "../../../interfaces/IPriceOracle.sol";
import "../../../interfaces/IFutureConfig.sol";

error Order__InsufficientExecutionFee();
error Order__InvalidFuture();
error Order__InvalidNonce();
error Order__ExecutedOrder();
error Order__ZeroParam();
error Order__InvalidOffset();
error Order__InvalidDeltaAmount();

abstract contract Order is UUPSUpgradeable, OwnableUpgradeable, Delegatable {
    uint8 public constant SUBTYPE_NONE = 0;
    uint8 public constant SUBTYPE_INCREASE = 1;
    uint8 public constant SUBTYPE_DECREASE = 2;

    IFutureManager public manager;
    IPriceOracle public oracle;

    constructor() {
        _disableInitializers();
    }

    function __Order_init(IFutureManager _manager, IPriceOracle _oracle) internal onlyInitializing {
        __Ownable_init();

        manager = _manager;
        oracle = _oracle;
    }

    function _checkExecutionFee() internal view {
        if (msg.value < manager.minExecutionFee()) {
            revert Order__InsufficientExecutionFee();
        }
    }

    modifier checkFee() {
        _checkExecutionFee();
        _;
    }

    function setHub(address hub) external onlyOwner {
        _setHub(hub);
    }

    function _checkFuture() internal view {
        if (msg.sender != manager.futureLong() && msg.sender != manager.futureShort()) {
            revert Order__InvalidFuture();
        }
    }

    function _checkPositive(uint256 param) internal pure {
        if (param == 0) {
            revert Order__ZeroParam();
        }
    }

    function _getConfig(bytes32 key, uint256 futureId) internal view returns (uint256) {
        return IFutureConfig(manager.futureConfig()).getConfig(key, futureId);
    }

    function _getLabel(uint256 nonce, uint8 orderSubtype) internal view returns (bytes32) {
        // 20B for address, 1B for subtype, 11B for nonce
        return bytes32(abi.encodePacked(address(this), orderSubtype, uint88(nonce)));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[50] private __gap;
}

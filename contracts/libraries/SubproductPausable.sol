// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "./SubstancePausable.sol";

error SubproductPausable__Paused();

abstract contract SubproductPausable is SubstancePausable {
    mapping(uint256 => bool) public pausedSubproduct;

    event SubproductPaused(uint256 indexed subproduct, bool paused);

    function __SubproductPausable_init() internal onlyInitializing {
        __SubstancePausable_init();
    }

    function setSubproductPaused(uint256 product, bool paused) external onlyOwner {
        bool current = pausedSubproduct[product];
        if ((current && !paused) || (!current && paused)) {
            pausedSubproduct[product] = paused;
            emit SubproductPaused(product, paused);
        }
    }

    function _requireSubproductNotPaused(uint256 product) internal view virtual {
        if (pausedSubproduct[product]) revert SubproductPausable__Paused();
    }

    function _checkPaused(uint256 product) internal view {
        _requireNotPaused();
        _requireSubproductNotPaused(product);
    }

    modifier whenSubproductNotPaused(uint256 product) {
        _checkPaused(product);
        _;
    }

    uint256[50] private __gap;
}

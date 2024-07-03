// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

abstract contract SubstancePausable is OwnableUpgradeable, PausableUpgradeable {
    function __SubstancePausable_init() internal onlyInitializing {
        __Ownable_init();
        __Pausable_init();
    }

    function setPause(bool _paused) external onlyOwner {
        bool current = paused();
        if (_paused && !current) {
            _pause();
        } else if (!_paused && current) {
            _unpause();
        }
    }

    uint256[50] private __gap;
}

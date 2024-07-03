// SPDX-License-Identifier: BUSL-1.1

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

error GradualVester__InvalidBeneficiaryAddress();
error GradualVester__VestingAccountAlreadyExists();
error GradualVester__InvalidCliffTime();
error GradualVester__InvalidVestingAccount();
error GradualVester__TokensStillInCliffPeriod();
error GradualVester__NoTokensToRelease();
error GradualVester__Jailed();

contract GradualVester is UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token;

    struct VestingInfo {
        uint256 cliff;
        uint256 vestingDuration;
        uint256 amount;
        uint256 releasedAmount;
    }

    mapping(address => VestingInfo) public vestingAccounts;
    mapping(address => bool) public isJailed;

    event AddBeneficiary(address indexed beneficiary, uint256 cliff, uint256 vestingDuration, uint256 amount);
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event Jail(address indexed beneficiary);

    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20Upgradeable _token) external initializer {
        __Ownable_init();
        token = _token;
    }

    function addVestingAccount(
        address _beneficiary,
        uint256 _cliff,
        uint256 _vestingDuration,
        uint256 _amount
    ) external onlyOwner {
        if (_beneficiary == address(0)) revert GradualVester__InvalidBeneficiaryAddress();
        if (vestingAccounts[_beneficiary].cliff != 0) revert GradualVester__VestingAccountAlreadyExists();
        if (_cliff <= block.timestamp) revert GradualVester__InvalidCliffTime();

        vestingAccounts[_beneficiary] = VestingInfo(_cliff, _vestingDuration, _amount, 0);
        token.safeTransferFrom(msg.sender, address(this), _amount);

        emit AddBeneficiary(_beneficiary, _cliff, _vestingDuration, _amount);
    }

    function jail(address beneficiary) external onlyOwner {
        isJailed[beneficiary] = true;
        VestingInfo storage vestingInfo = vestingAccounts[beneficiary];
        uint256 left = vestingInfo.amount - vestingInfo.releasedAmount;
        if (left > 0) {
            token.safeTransfer(msg.sender, left);
        }
        emit Jail(beneficiary);
    }

    function release() external {
        if (isJailed[msg.sender]) revert GradualVester__Jailed();
        VestingInfo storage vestingInfo = vestingAccounts[msg.sender];

        if (vestingInfo.cliff == 0) revert GradualVester__InvalidVestingAccount();
        if (block.timestamp < vestingInfo.cliff) revert GradualVester__TokensStillInCliffPeriod();

        uint256 elapsedTime = block.timestamp - vestingInfo.cliff;
        uint256 totalReleasableAmount = (vestingInfo.amount * elapsedTime) / vestingInfo.vestingDuration;
        uint256 releaseAmount = totalReleasableAmount - vestingInfo.releasedAmount;

        if (releaseAmount == 0) revert GradualVester__NoTokensToRelease();

        vestingInfo.releasedAmount += releaseAmount;
        token.safeTransfer(msg.sender, releaseAmount);

        emit TokensReleased(msg.sender, releaseAmount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

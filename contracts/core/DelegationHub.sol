// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IDelegationHub.sol";

import "../libraries/TransferHelper.sol";

error DelegationHub__InvalidData();
error DelegationHub__DelegateToContract();
error DelegationHub__ReentrantCall();
error DelegationHub__Unauthoried();
error DelegationHub__CallerIsNotOperator();
error DelegationHub__ValueMismatch();
error DelegationHub__NotWhitelistedSelector();

contract DelegationHub is UUPSUpgradeable, OwnableUpgradeable, IDelegationHub {
    mapping(address => address) public delegations;
    mapping(address => bool) public isOperator;
    mapping(address => bool) public dOp;
    mapping(address whitelistedTarget => mapping(bytes4 whitelistedSelector => bool)) calleeWhitelist;
    address private senderOverride;

    event SetDelegate(address indexed delegator, address indexed delegatee);

    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        __Ownable_init();
    }

    function setCalleeWhitelist(address[] calldata targets, bytes4[] calldata selectors, bool[] calldata status) external onlyOwner {
        if (targets.length != selectors.length || targets.length != status.length) revert DelegationHub__InvalidData();
        unchecked {
            for(uint256 i; i < targets.length; ++i) {
                calleeWhitelist[targets[i]][selectors[i]] = status[i];
            }
        }
    }

    function setOperator(address[] calldata _op, bool[] calldata _status) external onlyOwner {
        if (_op.length != _status.length) {
            revert DelegationHub__InvalidData();
        }
        unchecked {
            for (uint256 i; i < _op.length; ++i) {
                isOperator[_op[i]] = _status[i];
            }
        }
    }

    function setDOp(address[] calldata _op, bool[] calldata _status) external onlyOwner {
        if (_op.length != _status.length) {
            revert DelegationHub__InvalidData();
        }
        unchecked {
            for (uint256 i; i < _op.length; ++i) {
                dOp[_op[i]] = _status[i];
            }
        }
    }

    function operatorSetDelegate(address _delegator, address _delegatee) external {
        if (!dOp[msg.sender]) {
            revert DelegationHub__CallerIsNotOperator();
        }
        _setDelegate(_delegator, _delegatee);
    }

    function _setDelegate(address _delegator, address _delegatee) internal {
        delegations[_delegator] = _delegatee;
        emit SetDelegate(_delegator, _delegatee);
    }

    function setDelegate(address _delegatee) external {
        if (tx.origin != msg.sender) {
            revert DelegationHub__DelegateToContract();
        }
        _setDelegate(msg.sender, _delegatee);
    }

    function withdrawETH() external onlyOwner {
        TransferHelper.safeTransferETH(msg.sender, address(this).balance);
    }

    function msgSender() public view returns (address) {
        if (senderOverride == address(0)) {
            return msg.sender;
        } else {
            return senderOverride;
        }
    }

    function traderDelegate(address trader, Call[] calldata calls) external payable returns (Result[] memory returnData) {
        if (msg.sender != address(0) && delegations[trader] != msg.sender) {
            revert DelegationHub__Unauthoried();
        }
        returnData = _aggregate(trader, calls, true);
    }

    function delegate(Call[] calldata calls) external payable returns (Result[] memory returnData) {
        returnData = _aggregate(msg.sender, calls, !isOperator[msg.sender]);
    }

    function _aggregate(address sender, Call[] calldata calls, bool needValidation) internal returns (Result[] memory returnData) {
        if (senderOverride != address(0)) {
            revert DelegationHub__ReentrantCall();
        }
        senderOverride = sender;
        uint256 valAccumulator;
        uint256 length = calls.length;
        returnData = new Result[](length);
        Call calldata calli;
        for (uint256 i; i < length; ) {
            Result memory result = returnData[i];
            calli = calls[i];
            uint256 val = calli.value;
            unchecked {
                valAccumulator += val;
            }
            if (needValidation && !calleeWhitelist[calli.target][bytes4(calli.payload)]) {
                revert DelegationHub__NotWhitelistedSelector();
            }
            (bool success, bytes memory retData) = calli.target.call{value: val}(calli.payload);
            if (!success && !calli.allowFailure) {
                if (retData.length == 0) revert();
                assembly {
                    revert(add(0x20, retData), mload(retData))
                }
            } else {
                result.success = success;
                result.returnData = retData;
            }
            unchecked {
                ++i;
            }
        }
        if (msg.value != valAccumulator) {
            revert DelegationHub__ValueMismatch();
        }
        senderOverride = address(0);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

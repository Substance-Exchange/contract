// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "../interfaces/IUserBalance.sol";
import "./Delegatable.sol";
import "../libraries/SubstancePausable.sol";

error SubstanceUSD__InvalidOraclePrice();
error SubstanceUSD__InvalidToken();
error SubstanceUSD__InsufficiantOutputAmount();
error SubstanceUSD__InvalidUnderlyingTokenData();

contract SubstanceUSD is UUPSUpgradeable, ERC20Upgradeable, SubstancePausable, Delegatable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public constant PRECISION = 10 ** 6;

    IUserBalance public userBalance;
    uint256 public mintFee;
    uint256 public burnFee;
    address public feeReceiver;
    uint256 public stalePriceDelay;

    struct TokenInfo {
        address oracle;
        uint8 decimals;
    }

    mapping(address => TokenInfo) public underlyingToken;

    event UpdateUnderlyingAsset(address indexed token, address oracle, uint8 decimals);
    event BuyUSDX(address indexed user, address indexed token, uint256 tokenAmount, uint256 usdxAmount, uint256 price, uint256 fee);
    event SellUSDX(address indexed user, address indexed token, uint256 tokenAmount, uint256 usdxAmount, uint256 price, uint256 fee);

    function initialize(IUserBalance _userBalance, uint256 _mintFee, uint256 _burnFee, address _feeReceiver, uint256 _stalePriceDelay) external initializer {
        __ERC20_init("SubstanceX USD", "USDX");
        __SubstancePausable_init();

        userBalance = _userBalance;
        mintFee = _mintFee;
        burnFee = _burnFee;
        feeReceiver = _feeReceiver;
        stalePriceDelay = _stalePriceDelay;
    }

    function setStalePriceDelay(uint256 _delay) external onlyOwner {
        stalePriceDelay = _delay;
    }

    function setFee(uint256 _mintFee, uint256 _burnFee) external onlyOwner {
        mintFee = _mintFee;
        burnFee = _burnFee;
    }

    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
    }

    function setUnderlyingToken(address[] calldata assets, address[] calldata oracles) public onlyOwner {
        if (assets.length != oracles.length) {
            revert SubstanceUSD__InvalidUnderlyingTokenData();
        }
        unchecked {
            for (uint256 i; i < assets.length; ++i) {
                uint8 dec = IERC20MetadataUpgradeable(assets[i]).decimals();
                TokenInfo storage info = underlyingToken[assets[i]];
                info.oracle = oracles[i];
                info.decimals = dec;
                emit UpdateUnderlyingAsset(assets[i], oracles[i], dec);
            }
        }
    }

    function setHub(address hub) external onlyOwner {
        _setHub(hub);
    }

    function decimals() public pure virtual override returns (uint8) {
        return 6;
    }

    function mintUSDFee(address[] calldata tokens) external onlyOwner {
        uint256 totalUSD;
        for (uint256 i; i < tokens.length; ++i) {
            uint8 tokenDecimals = underlyingToken[tokens[i]].decimals;
            if (tokenDecimals == 0) revert SubstanceUSD__InvalidToken();
            totalUSD += (IERC20Upgradeable(tokens[i]).balanceOf(address(this)) * (10 ** decimals())) / (10 ** tokenDecimals);
        }
        uint256 totalSupply = totalSupply();
        if (totalSupply < totalUSD) {
            _mint(msg.sender, totalUSD - totalSupply);
        }
    }

    // min ? min(1, price) : max(1, price)
    function getPrice(address token, bool min) public view returns (uint256 price) {
        address oracle = underlyingToken[token].oracle;
        if (oracle == address(0)) {
            revert SubstanceUSD__InvalidToken();
        }
        (, int256 oraclePrice, , uint256 updatedAt, ) = AggregatorV3Interface(oracle).latestRoundData();
        if (oraclePrice <= 0 || block.timestamp > updatedAt + stalePriceDelay) {
            revert SubstanceUSD__InvalidOraclePrice();
        }
        uint8 pDecimals = AggregatorV3Interface(oracle).decimals();
        price = (uint256(oraclePrice) * PRECISION) / (10 ** pDecimals);
        price = min ? MathUpgradeable.min(PRECISION, price) : MathUpgradeable.max(PRECISION, price);
    }

    function previewBuy(address token, uint256 tokenAmount) external view returns (uint256) {
        tokenAmount -= (tokenAmount * mintFee) / PRECISION;
        return (tokenAmount * getPrice(token, true)) / (10 ** underlyingToken[token].decimals);
    }

    function buy(address token, uint256 minUsdxOut, uint256 tokenAmount) external whenNotPaused returns (uint256 usdxAmount) {
        address user = msgSender();
        uint256 fee = (tokenAmount * mintFee) / PRECISION;
        userBalance.transfer(token, user, feeReceiver, fee);
        tokenAmount -= fee;
        uint256 price = getPrice(token, true);
        userBalance.transfer(token, user, address(this), tokenAmount);
        usdxAmount = (tokenAmount * price) / (10 ** underlyingToken[token].decimals);
        if (usdxAmount < minUsdxOut) {
            revert SubstanceUSD__InsufficiantOutputAmount();
        }
        _mint(address(userBalance), usdxAmount);
        userBalance.increaseBalance(address(this), user, usdxAmount);

        emit BuyUSDX(user, token, tokenAmount, usdxAmount, price, fee);
    }

    function previewSell(address token, uint256 usdxAmount) external view returns (uint256) {
        uint256 tokenAmount = (usdxAmount * (10 ** underlyingToken[token].decimals)) / getPrice(token, false);
        return tokenAmount - (tokenAmount * burnFee) / PRECISION;
    }

    function sell(address token, uint256 minTokenOut, uint256 usdxAmount) external whenNotPaused returns (uint256 tokenAmount) {
        address user = msgSender();
        uint256 price = getPrice(token, false);
        tokenAmount = (usdxAmount * (10 ** underlyingToken[token].decimals)) / price;
        uint256 fee = (tokenAmount * burnFee) / PRECISION;
        tokenAmount -= fee;
        if (tokenAmount < minTokenOut) {
            revert SubstanceUSD__InsufficiantOutputAmount();
        }
        userBalance.transfer(address(this), user, address(this), usdxAmount);
        _burn(address(this), usdxAmount);
        IERC20Upgradeable(token).safeTransfer(address(userBalance), tokenAmount + fee);
        userBalance.increaseBalance(token, user, tokenAmount);
        userBalance.increaseBalance(token, feeReceiver, fee);

        emit SellUSDX(user, token, tokenAmount, usdxAmount, price, fee);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

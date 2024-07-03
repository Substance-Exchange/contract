// SPDX-License-Identifier: UNLICENSED

/*
 * Substance Exchange Contracts
 * Copyright (C) 2023 Substance Technologies Limited
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

error LiquidityPool__InvalidDepositOrWithdrawTime();
error LiquidityPool__InvalidEpochNumber();
error LiquidityPool__InsufficientLiquidity();
error LiquidityPool__InsufficientLockedLiquidity();
error LiquidityPool__UserLiquidityNotClaimable();
error LiquidityPool__UserSLPNotClaimable();
error LiquidityPool__UPLGreaterThanPoolValue();
error LiquidityPool__InvalidAmount();

contract LiquidityPool is UUPSUpgradeable, OwnableUpgradeable, ERC20Upgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Access
    address public exchangeManager;
    address public userBalance;
    mapping(address => bool) public productManagers;

    uint256 public epochNumber;
    uint256 public epochEndTime;

    uint256 public initSLPTokenPrice; // 1000000 = 1USD

    uint256 public poolAmount;
    uint256 public poolLockedAmount;

    address public teamAddress;

    // to handle dynamic max locked ratio for each token.
    mapping(address => mapping(uint256 => uint256)) public maxLockedRatio;
    mapping(address => mapping(uint256 => uint256)) public subproductLockedAmount;
    mapping(address => uint256) public productLockedAmount;
    mapping(address => uint256) public productMaxLockedAmount;

    mapping(uint256 => mapping(address => uint256)) public userDepositAmount;
    mapping(uint256 => mapping(address => uint256)) public userWithdrawAmount;

    mapping(uint256 => uint256) public globalDepositAmount;
    mapping(uint256 => uint256) public globalWithdrawAmount;

    mapping(uint256 => mapping(address => bool)) public userClaimed;
    mapping(uint256 => mapping(address => bool)) public userBurned;

    mapping(uint256 => uint256) public lpTokenPrice;
    address public usd;

    struct PoolInfo {
        uint256 value;
        uint256 lpAmount;
    }
    mapping(uint256 => PoolInfo) public epochMintInfo;
    mapping(uint256 => PoolInfo) public epochBurnInfo;

    // Fees
    uint256 public withdrawFeeBasisPoints;
    uint256 public requestTimeDelay;

    event EpochMintSLPToken(uint256 indexed epoch, uint256 usdValue, uint256 SLPTokenAmount);
    event EpochBurnSLPToken(uint256 indexed epoch, uint256 usdValue, uint256 SLPTokenAmount);
    event UpdatePool(uint256 lockedAmount, uint256 totalAmount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _susd,
        uint256 _initSLPTokenPrice,
        uint256 _withdrawFeeBasisPoints,
        address _teamAddress
    ) external initializer {
        __Ownable_init();
        __ERC20_init("SubstanceX Liquidity Provider", "SLP");
        usd = _susd;
        initSLPTokenPrice = _initSLPTokenPrice;
        withdrawFeeBasisPoints = _withdrawFeeBasisPoints;
        teamAddress = _teamAddress;
        requestTimeDelay = 5;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setFees(uint256 _withdrawFeeBasisPoints) public onlyOwner {
        withdrawFeeBasisPoints = _withdrawFeeBasisPoints;
    }

    function setMaxLockedRatio(
        address _product,
        uint256 _productId,
        uint256 _maxRatio
    ) public onlyOwner {
        maxLockedRatio[_product][_productId] = _maxRatio;
    }

    function setProductMaxAvailableAmount(address product, uint256 amount) external onlyOwner {
        productMaxLockedAmount[product] = amount;
    }

    function setExchangeManager(address _exchangeManager) public onlyOwner {
        exchangeManager = _exchangeManager;
    }

    function setProductManager(address _productManager) public onlyOwner {
        productManagers[_productManager] = true;
    }

    function setUserBalance(address _userBalance) public onlyOwner {
        userBalance = _userBalance;
    }

    modifier isExchangeManager() {
        require(msg.sender == exchangeManager);
        _;
    }

    modifier isProductManager() {
        require(productManagers[msg.sender]);
        _;
    }

    function setTeamAddress(address _teamAddress) public onlyOwner {
        teamAddress = _teamAddress;
    }

    function setRequestTimeDelay(uint256 _requestTimeDelay) public onlyOwner {
        requestTimeDelay = _requestTimeDelay;
    }

    function lpProvideLiquidity(address _user, uint256 _amount) external isExchangeManager {
        _validEpochCheck();
        _validDepositOrWithdrawTime();
        _nonZeroAmountCheck(_amount);
        userDepositAmount[epochNumber][_user] += _amount;
        globalDepositAmount[epochNumber] += _amount;
    }

    /* 
        @dev LP send SLP withdraw request,
    */
    function lpWithdrawSLP(address _user, uint256 _amount) external isExchangeManager {
        _validEpochCheck();
        _validDepositOrWithdrawTime();
        _nonZeroAmountCheck(_amount);
        userWithdrawAmount[epochNumber][_user] += _amount;
        globalWithdrawAmount[epochNumber] += _amount;
    }

    function _validDepositOrWithdrawTime() public view {
        if (block.timestamp >= epochEndTime - requestTimeDelay || isCurrentEpochSLPPriceClaimed()) {
            revert LiquidityPool__InvalidDepositOrWithdrawTime();
        }
    }

    function globalMintSLP(int256 _futureUnrealizedUPL) private {
        lpTokenPrice[epochNumber] = getSLPTokenPrice(_futureUnrealizedUPL, true);
        uint256 deposit = globalDepositAmount[epochNumber];
        PoolInfo memory mintinfo = PoolInfo({value: deposit, lpAmount: (deposit * (10**decimals())) / lpTokenPrice[epochNumber]});
        poolAmount += deposit;
        epochMintInfo[epochNumber] = mintinfo;
        _mint(address(this), mintinfo.lpAmount);
        emit EpochMintSLPToken(epochNumber, mintinfo.value, mintinfo.lpAmount);
    }

    function globalWithdrawToken(int256 _futureUnrealizedUPL) private {
        uint256 lpPrice = getSLPTokenPrice(_futureUnrealizedUPL, false);
        uint256 globalWithdrawUSDValueSLP = (globalWithdrawAmount[epochNumber] * lpPrice) / 10**decimals();
        uint256 globalWithdrawUSDBeforeFee = globalWithdrawUSDValueSLP < poolAmount - poolLockedAmount
            ? globalWithdrawUSDValueSLP
            : poolAmount - poolLockedAmount;
        PoolInfo memory burnInfo;

        uint256 globalWithdrawUSDAfterFee;
        if (globalWithdrawUSDValueSLP > 0) {
            globalWithdrawUSDAfterFee = (globalWithdrawUSDBeforeFee * (10000 - withdrawFeeBasisPoints)) / 10000;
            // calculate USD to users, shoule be USD after fees.
            burnInfo.value = globalWithdrawUSDAfterFee;
            // caculate SLP to users, burnInfo.SLPAmount: unburned SLP tokens back to users
            // total request USD: globalWithdrawUSDValueSLP, total request SLP : globalWithdrawAmount[epochNumber],
            // total withdraw USD: globalWithdrawUSDBeforeFee, total withdraw SLP: globalWithdrawAmount[epochNumber] * globalWithdrawUSDBeforeFee / globalWithdrawUSDValueSLP
            // total return SLP: globalWithdrawAmount[epochNumber] * (globalWithdrawUSDValueSLP - globalWithdrawUSDBeforeFee) / globalWithdrawUSDValueSLP
            burnInfo.lpAmount = (globalWithdrawAmount[epochNumber] * (globalWithdrawUSDValueSLP - globalWithdrawUSDBeforeFee)) / globalWithdrawUSDValueSLP;
            // update global storage
        }
        poolAmount -= globalWithdrawUSDBeforeFee;

        // @dev directly safe transfer to teamAddress
        IERC20Upgradeable(usd).safeTransfer(teamAddress, globalWithdrawUSDBeforeFee - globalWithdrawUSDAfterFee);

        // burnInfo.lpAmount = slp left after burned slp to exchange usdx.
        uint256 burn = (globalWithdrawAmount[epochNumber] - burnInfo.lpAmount);
        _burn(address(this), burn);

        epochBurnInfo[epochNumber] = burnInfo;
        emit EpochBurnSLPToken(epochNumber, burnInfo.value, burn);
    }

    function getUserWithdrawAmount(uint256 epoch, address _user) external view returns (uint256[] memory userInfo) {
        require(epochNumber > epoch, "Epoch has not been completed");
        uint256 globalAmount = globalWithdrawAmount[epoch];
        uint256 userWithdraw = userWithdrawAmount[epoch][_user];
        userInfo = new uint256[](2);
        PoolInfo storage burnInfo = epochBurnInfo[epoch];
        if (globalAmount != 0 && !userBurned[epoch][_user]) {
            // uint256 userBurn = userWithdrawAmount[epoch][token][_user] - userReturn;
            userInfo[0] = (burnInfo.value * userWithdraw) / globalAmount; // withdraw
            userInfo[1] = (burnInfo.lpAmount * userWithdraw) / globalAmount; // return
        }
    }

    function withdrawUsersLiquidity(uint256 epoch, address _user) public isExchangeManager returns (uint256[] memory userInfo) {
        require(epochNumber > epoch, "Epoch has not been completed");
        uint256 globalAmount = globalWithdrawAmount[epoch];
        uint256 userWithdraw = userWithdrawAmount[epoch][_user];
        if (globalAmount == 0 || userWithdraw == 0 || userBurned[epoch][_user]) {
            revert LiquidityPool__UserLiquidityNotClaimable();
        }
        PoolInfo storage burnInfo = epochBurnInfo[epoch];
        userInfo = new uint256[](2);
        userInfo[0] = (burnInfo.value * userWithdraw) / globalAmount; // withdraw
        userInfo[1] = (burnInfo.lpAmount * userWithdraw) / globalAmount; // return
        burnInfo.value -= userInfo[0];
        burnInfo.lpAmount -= userInfo[1];
        globalWithdrawAmount[epoch] -= userWithdraw;
        userBurned[epoch][_user] = true;
        // Burn and move tokens
        IERC20Upgradeable(usd).safeTransfer(userBalance, userInfo[0]);
        _transfer(address(this), userBalance, userInfo[1]);
    }

    function getWithdrawUserSLPClaim(uint256 epoch, address _user) external view returns (uint256) {
        require(epochNumber > epoch, "Epoch has not been completed");
        uint256 userDeposit = userDepositAmount[epoch][_user];
        if (userDeposit == 0 || userClaimed[epoch][_user]) {
            return 0;
        }
        return (epochMintInfo[epoch].lpAmount * userDeposit) / epochMintInfo[epoch].value;
    }

    function withdrawUserSLPClaim(uint256 epoch, address _user) public isExchangeManager returns (uint256 userClaim) {
        require(epochNumber > epoch, "Epoch has not been completed");
        uint256 userDeposit = userDepositAmount[epoch][_user];
        if (userDeposit == 0 || userClaimed[epoch][_user]) {
            revert LiquidityPool__UserSLPNotClaimable();
        }
        PoolInfo storage mintInfo = epochMintInfo[epoch];
        userClaim = (mintInfo.lpAmount * userDeposit) / mintInfo.value;
        mintInfo.value -= userDeposit;
        mintInfo.lpAmount -= userClaim;
        userClaimed[epoch][_user] = true;

        _transfer(address(this), userBalance, userClaim);
    }

    function isUPLValid(int256 _futureUnrealizedUPL) public view {
        if (_futureUnrealizedUPL < 0) {
            uint256 valueLoss = SafeCast.toUint256(-_futureUnrealizedUPL);
            // Maybe just Locked?
            if (poolAmount < valueLoss) {
                revert LiquidityPool__UPLGreaterThanPoolValue();
            }
        }
    }

    // @dev _futureUnrealizedUPL : future unrealized profit of all users.
    function moveToNextEpoch(uint256 _nextEpochEndTime, int256 _futureUnrealizedUPL) public isExchangeManager {
        if (epochNumber > 0) {
            isUPLValid(-_futureUnrealizedUPL);
            globalMintSLP(-_futureUnrealizedUPL);
            globalWithdrawToken(-_futureUnrealizedUPL);
        }
        ++epochNumber;
        epochEndTime = _nextEpochEndTime;
    }

    function lockLiquidity(
        uint256 _amount,
        address _product,
        uint256 _productId
    ) external isProductManager {
        if (poolAmount - poolLockedAmount < _amount) {
            revert LiquidityPool__InsufficientLiquidity();
        }
        subproductLockedAmount[_product][_productId] += _amount;
        productLockedAmount[_product] += _amount;
        poolLockedAmount += _amount;
        _emitUpdatePool();
    }

    function unlockLiquidity(
        uint256 _amount,
        address _product,
        uint256 _productId
    ) external isProductManager {
        if (poolLockedAmount < _amount) {
            revert LiquidityPool__InsufficientLockedLiquidity();
        }
        subproductLockedAmount[_product][_productId] -= _amount;
        productLockedAmount[_product] = _amount;
        poolLockedAmount -= _amount;
        _emitUpdatePool();
    }

    function increaseLiquidity(uint256 _amount) external isProductManager {
        poolAmount += _amount;
        _emitUpdatePool();
    }

    function transferUSD(address _to, uint256 _amount) external isProductManager {
        poolAmount -= _amount;
        IERC20Upgradeable(usd).safeTransfer(_to, _amount);
        _emitUpdatePool();
    }

    // view functons
    function isCurrentEpochSLPPriceClaimed() public view returns (bool) {
        return lpTokenPrice[epochNumber] > 0;
    }

    function _nonZeroAmountCheck(uint256 _amount) public pure {
        if (_amount == 0) {
            revert LiquidityPool__InvalidAmount();
        }
    }

    function _validEpochCheck() public view {
        if (epochNumber == 0) {
            revert LiquidityPool__InvalidEpochNumber();
        }
    }

    function getSLPTokenPrice(int256 _futureUnrealizedUPL, bool isDeposit) public view returns (uint256 slpPrice) {
        uint256 total = totalSupply();
        if (total == 0) {
            return initSLPTokenPrice;
        }
        uint256 globalUSDValue = poolAmount;
        if (_futureUnrealizedUPL < 0) {
            uint256 valueLoss = SafeCast.toUint256(-_futureUnrealizedUPL);
            globalUSDValue = globalUSDValue > valueLoss ? globalUSDValue - valueLoss : 0;
        } else {
            globalUSDValue += SafeCast.toUint256(_futureUnrealizedUPL);
        }
        slpPrice = (globalUSDValue * 10**decimals()) / total;
        if (isDeposit) {
            slpPrice = MathUpgradeable.max(1, slpPrice);
        }
    }

    function getTotalAvailableToken() public view returns (uint256) {
        return poolAmount - poolLockedAmount;
    }

    function getAvailableToken(address product) public view returns (uint256) {
        uint256 productMax = productMaxLockedAmount[product];
        // no max locked amount set
        if (productMax == 0) {
            return poolAmount - poolLockedAmount;
        }
        uint256 poolAvailable = poolAmount - poolLockedAmount;
        uint256 poolAvailableForProduct = productMax > productLockedAmount[product] ? productMax - productLockedAmount[product] : 0;
        return MathUpgradeable.min(poolAvailable, poolAvailableForProduct);
    }

    function getAvailableTokenForFuture(address _future, uint256 _futureId) public view returns (uint256) {
        uint256 ratio = maxLockedRatio[_future][_futureId];
        if (ratio == 0) {
            ratio = 10000;
        }
        uint256 maxLockedAmountByRatio = (poolAmount * ratio) / 10000;
        if (maxLockedAmountByRatio <= subproductLockedAmount[_future][_futureId]) {
            return 0;
        }
        return MathUpgradeable.min(maxLockedAmountByRatio - subproductLockedAmount[_future][_futureId], getAvailableToken(_future));
    }

    function _emitUpdatePool() internal {
        emit UpdatePool(poolLockedAmount, poolAmount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

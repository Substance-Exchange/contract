// SPDX-License-Identifier: BUSL-1.1

/*
 * Substance Exchange Contracts
 * @author Substance Technologies Limited
 * Based on Synthetix StakingRewards
 * https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
 */

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../core/Delegatable.sol";
import "../interfaces/IUserBalance.sol";

error StakingReward__InvalidLockTime();
error StakingReward__CannotStakeZero();
error StakingReward__NotOwner();
error StakingReward__NotVesting();
error StakingReward__AlreadyVested();
error StakingReward__ProvidedRewardTooHigh();

contract StakingReward is UUPSUpgradeable, ERC721Upgradeable, OwnableUpgradeable, Delegatable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct StakedPosition {
        uint256 amount;
        uint256 share;
        uint256 unlockTime;
        uint256 rewardPerSharePaid;
        uint256 reward;
        uint256 claimed;
        uint256 lastClaimTime;
    }

    IUserBalance public exchangeWallet;
    IERC20Upgradeable public rewardToken;
    IERC20Upgradeable public stakingToken;
    uint256 public duration;

    uint256 public constant BOOST_PRECISION = 10 ** 4;
    uint256 public maxLockupPeriod; // default = 2 * 360 days
    uint256 public minLockupPeriod;
    uint256 public maxBoost;
    uint256 public vestingPeriod; // default 365 days

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerShareStored;
    uint256 public historicalRewards;

    uint256 public nextTokenId;
    string private baseURI;

    uint256 public totalShare;
    mapping(uint256 => StakedPosition) public positions;

    event RewardAdded(uint256 reward);
    event CreatePosition(uint256 indexed tokenId, uint256 amount, uint256 share, uint256 lockupTime);
    event StartVesting(uint256 indexed tokenId, uint256 reward);
    event RewardPaid(uint256 indexed tokenId, uint256 reward);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        IUserBalance exchangeWallet_,
        IERC20Upgradeable stakingToken_,
        IERC20Upgradeable reward_,
        uint256 duration_,
        uint256 maxLockupPeriod_,
        uint256 vestingPeriod_
    ) external initializer {
        __ERC721_init(name_, symbol_);
        __Ownable_init();

        exchangeWallet = exchangeWallet_;
        duration = duration_;
        rewardToken = reward_;
        stakingToken = stakingToken_;
        maxLockupPeriod = maxLockupPeriod_;
        vestingPeriod = vestingPeriod_;

        minLockupPeriod = 30 days;
        maxBoost = 2 * BOOST_PRECISION;
    }

    function setHub(address hub) external onlyOwner {
        _setHub(hub);
    }

    function setBaseURI(string calldata _uri) external onlyOwner {
        baseURI = _uri;
    }

    function _baseURI() internal view override returns (string memory) {
        return baseURI;
    }

    function boostMultiplier(uint256 _lockTime) public view returns (uint256) {
        if (_lockTime < minLockupPeriod || _lockTime > maxLockupPeriod) revert StakingReward__InvalidLockTime();
        return (maxBoost * _lockTime) / maxLockupPeriod;
    }

    function setMinLockupPeriod(uint256 _min) external onlyOwner {
        minLockupPeriod = _min;
    }

    function _updateReward() internal {
        rewardPerShareStored = rewardPerShare();
        lastUpdateTime = lastTimeRewardApplicable();
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return MathUpgradeable.min(block.timestamp, periodFinish);
    }

    function rewardPerShare() public view returns (uint256) {
        if (totalShare == 0) {
            return rewardPerShareStored;
        }
        return rewardPerShareStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalShare;
    }

    function earned(uint256 tokenId) public view returns (uint256) {
        StakedPosition storage position = positions[tokenId];
        return (position.share * (rewardPerShare() - position.rewardPerSharePaid)) / 1e18;
    }

    function stake(uint256 amount, uint256 lockupTime) external {
        if (amount == 0) revert StakingReward__CannotStakeZero();
        _updateReward();
        address user = msgSender();
        uint256 share = (amount * boostMultiplier(lockupTime)) / BOOST_PRECISION;
        exchangeWallet.transfer(address(stakingToken), user, address(this), amount);
        totalShare += share;
        uint256 tokenId = nextTokenId++;
        StakedPosition storage position = positions[tokenId];
        position.amount = amount;
        position.unlockTime = block.timestamp + lockupTime;
        position.rewardPerSharePaid = rewardPerShare();
        position.share = share;

        emit CreatePosition(tokenId, amount, share, lockupTime);

        _mint(user, tokenId);
    }

    function vest(uint256 tokenId) external {
        // Anyone can HELP the fully locked NFT to begin vesting
        // if (ownerOf(tokenId) != msgSender()) revert StakingReward__NotOwner();
        _updateReward();
        StakedPosition storage position = positions[tokenId];
        if (position.unlockTime > block.timestamp) revert StakingReward__NotVesting();
        if (position.lastClaimTime > 0) revert StakingReward__AlreadyVested();

        position.lastClaimTime = block.timestamp;
        uint256 reward = earned(tokenId);
        position.reward = reward;
        totalShare -= position.share;
        uint256 principal = position.amount;
        stakingToken.safeTransfer(address(exchangeWallet), principal);
        exchangeWallet.increaseBalance(address(stakingToken), ownerOf(tokenId), principal);

        emit StartVesting(tokenId, reward);
    }

    function claim(uint256 tokenId) external {
        address user = msgSender();
        if (ownerOf(tokenId) != user) revert StakingReward__NotOwner();
        StakedPosition storage position = positions[tokenId];
        uint256 lastClaimTime = position.lastClaimTime;
        uint256 posReward = position.reward;
        uint256 claimed = position.claimed;
        if (lastClaimTime == 0) revert StakingReward__NotVesting();
        uint256 reward = (posReward * (block.timestamp - lastClaimTime)) / vestingPeriod;
        bool burn;
        if (reward + claimed >= posReward) {
            reward = posReward - claimed; // dust
            burn = true;
        }
        position.claimed += reward;
        position.lastClaimTime = block.timestamp;
        rewardToken.safeTransfer(address(exchangeWallet), reward);
        exchangeWallet.increaseBalance(address(rewardToken), user, reward);
        emit RewardPaid(tokenId, reward);
        if (burn) {
            _burn(tokenId);
        }
    }

    function claimable(uint256 tokenId) external view returns (uint256 reward) {
        StakedPosition memory position = positions[tokenId];
        reward = (position.reward * (block.timestamp - position.lastClaimTime)) / vestingPeriod;
        if (reward + position.claimed >= position.reward) {
            reward = position.reward - position.claimed;
        }
    }

    function notifyRewardAmount(uint256 _reward) external onlyOperator {
        _updateReward();
        historicalRewards += _reward;
        if (block.timestamp >= periodFinish) {
            rewardRate = _reward / duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (_reward + leftover) / duration;
        }

        uint256 balance = rewardToken.balanceOf(address(this));
        if (rewardRate > balance / duration) revert StakingReward__ProvidedRewardTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit RewardAdded(_reward);
    }

    function setRewardDuartion(uint256 _duration) external onlyOperator {
        duration = _duration;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

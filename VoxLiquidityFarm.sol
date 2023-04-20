// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./utils/Pausable.sol";

import "./interfaces/IStakingPool.sol";

/*
    VOX FINANCE 2.0

    Website: https://vox.finance
    Twitter: https://twitter.com/RealVoxFinance
    Telegram: https://t.me/VoxFinance
 */

contract VoxLiquidityFarm is ReentrancyGuard, Pausable {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    // STATE VARIABLES

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint public periodFinish = 0;
    uint public rewardRate = 0;
    uint public rewardsDuration = 63072000; // 2 years
    uint public lastUpdateTime;
    uint public rewardPerTokenStored;

    address public treasury = address(0xB565A72868A70da734DA10e3750196Dd82Cb7f16);
    IStakingPool public stakingPool;

    uint public withdrawalFee = 500; // 5.0 %
    uint public withdrawalFeeMax = 1000;
    uint internal withdrawalFeeBase = 10000;

    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public rewards;

    uint private _totalSupply;
    mapping(address => uint) private _balances;

    // CONSTRUCTOR

    constructor(
        address _rewardsToken,
        address _stakingToken,
        address _stakingPool
    ) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        stakingPool = IStakingPool(_stakingPool);
    }

    // VIEWS

    function totalSupply() external view returns (uint) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint) {
        return min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(_totalSupply)
            );
    }

    function earned(address account) public view returns (uint) {
        return
            _balances[account]
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint) {
        return rewardRate.mul(rewardsDuration);
    }

    function min(uint a, uint b) public pure returns (uint) {
        return a < b ? a : b;
    }

    // PUBLIC FUNCTIONS

    function deposit(uint amount)
        external
        nonReentrant
        notPaused
        updateReward(msg.sender)
    {
        require(amount > 0, "Cannot deposit 0");

        uint balBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint balAfter = stakingToken.balanceOf(address(this));
        uint actualReceived = balAfter.sub(balBefore);

        _totalSupply = _totalSupply.add(actualReceived);
        _balances[msg.sender] = _balances[msg.sender].add(actualReceived);
        
        emit Deposited(msg.sender, actualReceived);
    }

    function withdraw(uint amount)
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "Cannot withdraw 0");

        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);

        uint fee = amount.mul(withdrawalFee).div(withdrawalFeeBase);
        stakingToken.safeTransfer(treasury, fee);
        stakingToken.safeTransfer(msg.sender, amount.sub(fee));

        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function stakeReward() public nonReentrant updateReward(msg.sender) {
        require(address(stakingPool) != address(0), "!stakingPool");
        uint reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            stakingPool.depositFor(msg.sender, reward);
            rewardsToken.safeTransfer(address(stakingPool), reward);
            emit RewardStaked(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    // OWNER FUNCTIONS

    function setTreasury(address _treasury)
        external
        onlyOwner
    {
        require(msg.sender == address(treasury), "!treasury");
        treasury = _treasury;
    }

    function setStakingPool(address _stakingPool)
        external
        onlyOwner
    {
        require(address(_stakingPool) != address(0), "!stakingPool");
        stakingPool = IStakingPool(_stakingPool);
    }

    function setWithdrawalFee(uint _withdrawalFee)
        external
        onlyOwner
    {
        require(_withdrawalFee < withdrawalFeeMax, "!withdrawalFee");
        withdrawalFee = _withdrawalFee;
    }

    function notifyRewardAmount(uint reward)
        external
        onlyOwner
        updateReward(address(0))
    {
        uint oldBalance = rewardsToken.balanceOf(address(this));
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);
        uint newBalance = rewardsToken.balanceOf(address(this));
        uint actualReceived = newBalance - oldBalance;
        require(actualReceived == reward, "Whitelist the pool to exclude fees");

        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
            periodFinish = block.timestamp.add(rewardsDuration);
        } else {
            rewardRate += reward / (periodFinish - block.timestamp);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(
            rewardRate <= balance.div(rewardsDuration),
            "Provided reward too high"
        );

        lastUpdateTime = block.timestamp;
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint tokenAmount)
        external
        onlyOwner
    {
        // Cannot recover the staking token or the rewards token
        require(
            tokenAddress != address(stakingToken) &&
                tokenAddress != address(rewardsToken),
            "Cannot withdraw the staking or rewards tokens"
        );
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint _rewardsDuration) 
        external 
        onlyOwner 
    {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        require(_rewardsDuration > 0 
            && _rewardsDuration <= 4 years,
            "Rewards duration is not within bounds");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    // *** MODIFIERS ***

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    // EVENTS

    event RewardAdded(uint reward);
    event Deposited(address indexed user, uint amount);
    event Withdrawn(address indexed user, uint amount);
    event RewardPaid(address indexed user, uint reward);
    event RewardStaked(address indexed user, uint reward);
    event RewardsDurationUpdated(uint newDuration);
    event Recovered(address token, uint amount);
}

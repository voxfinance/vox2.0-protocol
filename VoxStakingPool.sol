// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./utils/Pausable.sol";

/*
    VOX FINANCE 2.0

    Website: https://vox.finance
    Twitter: https://twitter.com/RealVoxFinance
    Telegram: https://t.me/VoxFinance
 */

contract VoxStakingPool is ReentrancyGuard, Pausable {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    // STATE VARIABLES

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    address public treasury = address(0xB565A72868A70da734DA10e3750196Dd82Cb7f16);

    uint public periodFinish = 0;
    uint public rewardRate = 0;
    uint public rewardsDuration = 126144000; // 4 years
    uint public lastUpdateTime;
    uint public rewardPerTokenStored;

    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public rewards;

    uint private _totalSupply;
    uint private _totalDeposited;
    uint private _totalLocked;
    mapping(address => uint) private _balances;
    mapping(address => uint) private _deposits;
    mapping(address => uint) private _locked;
    mapping(address => uint) private _periods;
    mapping(address => uint) private _locks;
    mapping(address => bool) private _pools;
    mapping(address => bool) private _privatePools;

    uint public withdrawalFee = 75; // 0.75 %
    uint public withdrawalFeeMax = 500;
    uint internal withdrawalFeeBase = 10000;

    uint private minimumLock = 2 weeks;
    uint private maximumLock = 52 weeks;

    uint public multiplier = 5; // 5 %
    uint private constant multiplierBase = 100;

    // CONSTRUCTOR

    constructor(
        address _rewardsToken,
        address _stakingToken
    ) {
        require(_rewardsToken != address(0) 
            && _stakingToken != address(0),
            "Rewards and staking token can not be null address!");
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
    }

    // VIEWS

    function totalSupply() external view returns (uint) {
        return _totalSupply;
    }

    function totalDeposited() external view returns (uint) {
        return _totalDeposited;
    }

    function totalLocked() external view returns (uint) {
        return _totalLocked;
    }

    function balanceOf(address account) external view returns (uint) {
        return _balances[account];
    }

    function depositOf(address account) external view returns (uint) {
        return _deposits[account];
    }

    function lockedOf(address account) external view returns (uint) {
        return _locked[account];
    }

    function availableOf(address account) external view returns (uint) {
        return _balances[account].sub(_locked[account]);
    }

    function unlockedAt(address account) external view returns (uint) {
        return _locks[account];
    }

    function lockedFor(address account) external view returns (uint) {
        return _periods[account];
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

    function deposit(uint amount, uint lockPeriod)
        external
        nonReentrant
        notPaused
        updateReward(msg.sender)
    {
        require(amount > 0, "!stake-0");
        require(lockPeriod >= minimumLock, "!stake-<2weeks");

        if (_deposits[msg.sender] > 0) {
            require(lockPeriod >= _periods[msg.sender], "!stake-lock");
        }

        if (lockPeriod > maximumLock) {
            lockPeriod = maximumLock;
        }

        uint balBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint balAfter = stakingToken.balanceOf(address(this));
        uint actualReceived = balAfter.sub(balBefore);

        // add already deposited amount to current deposit
        uint total = _deposits[msg.sender].add(actualReceived);
        uint shares = 0;

        // calculate multiplier: (lock weeks - two weeks) / 1 week + add base
        uint lockMultiplier = ((lockPeriod - minimumLock).div(1 weeks)).mul(multiplier).add(multiplierBase);

        // calculate shares: total deposited amount * multiplier / base
        shares = total.mul(lockMultiplier).div(multiplierBase);

        // update all balances
        _deposits[msg.sender] = total;
        _totalDeposited = _totalDeposited.add(actualReceived);

        _totalSupply = _totalSupply.sub(_balances[msg.sender]);
        _balances[msg.sender] = shares;
        _totalSupply = _totalSupply.add(shares);

        _periods[msg.sender] = lockPeriod;
        _locks[msg.sender] = block.timestamp.add(lockPeriod);
        emit Deposited(msg.sender, actualReceived, lockPeriod);
    }

    function withdraw(uint amount)
        public
        nonReentrant
        updateReward(msg.sender)
    {
        require(amount > 0, "!withdraw-0");
        require(_deposits[msg.sender] > 0, "!withdraw-nostake");
        require(amount <= _deposits[msg.sender], "!withdraw-amount");
        require(block.timestamp >= _locks[msg.sender], "!withdraw-lock");

        // Calculate percentage of principal being withdrawn
        uint percentage = (amount.mul(1e18).div(_deposits[msg.sender]));

        // Calculate amount of shares to be removed
        uint shares = _balances[msg.sender].mul(percentage).div(1e18);

        if (shares > _balances[msg.sender]) {
            shares = _balances[msg.sender];
        }

        require(_balances[msg.sender].sub(_locked[msg.sender]) >= shares, '!locked');

        _deposits[msg.sender] = _deposits[msg.sender].sub(amount);
        _totalDeposited = _totalDeposited.sub(amount);

        _balances[msg.sender] = _balances[msg.sender].sub(shares);
        _totalSupply = _totalSupply.sub(shares);

        uint fee = amount.mul(withdrawalFee).div(withdrawalFeeBase);
        stakingToken.safeTransfer(treasury, fee);
        stakingToken.safeTransfer(msg.sender, amount.sub(fee));

        emit Withdrawn(msg.sender, amount);
    }

    function lockShares(address account, uint shares)
        external
        notPaused
        updateReward(account)
    {
        require(shares > 0, '!shares');
        require(_privatePools[msg.sender], '!private');
        require(_balances[account].sub(_locked[account]) >= shares, '!locked');

        _locked[account] = _locked[account].add(shares);
        _totalLocked = _totalLocked.add(shares);
        emit Locked(account, shares);
    }

    function unlockShares(address account, uint shares)
        external
        updateReward(account)
    {
        require(shares > 0, '!shares');
        require(_privatePools[msg.sender], '!private');
        require(_locked[account] >= shares, '!locked');

        _locked[account] = _locked[account].sub(shares);
        _totalLocked = _totalLocked.sub(shares);
        emit Unlocked(account, shares);
    }

    function depositFor(address account, uint amount)
        external
        notPaused
        updateReward(account)
    {
        require(amount > 0, "!stake-0");
        require(_pools[msg.sender], '!pool');
        _deposit(account, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        if (reward == 0) revert ZeroRewards();
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function stakeReward() public nonReentrant notPaused updateReward(msg.sender) {
        uint reward = rewards[msg.sender];
        if (reward == 0) revert ZeroRewards();
        if (reward > 0) {
            rewards[msg.sender] = 0;
            _deposit(msg.sender, reward);
            emit RewardStaked(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_deposits[msg.sender]);
        getReward();
    }

    // INTERNAL FUNCTIONS

    function _deposit(address account, uint amount)
        internal
    {
        uint lockPeriod = _periods[account];
        if (lockPeriod <= 0 || _deposits[account] <= 0) {
            lockPeriod = minimumLock;
            _periods[account] = lockPeriod;
            _locks[account] = block.timestamp.add(lockPeriod);
        }

        // add already deposited amount to current deposit
        uint total = _deposits[account].add(amount);
        uint shares = 0;

        // calculate multiplier: (lock weeks - two weeks) / 1 week + add base
        uint lockMultiplier = ((lockPeriod - minimumLock).div(1 weeks)).mul(multiplier).add(multiplierBase);

        // calculate shares: total deposited amount * multiplier / base
        shares = total.mul(lockMultiplier).div(multiplierBase);

        // update all balances
        _deposits[account] = total;
        _totalDeposited = _totalDeposited.add(amount);

        _totalSupply = _totalSupply.sub(_balances[account]);
        _balances[account] = shares;
        _totalSupply = _totalSupply.add(shares);
    }

    // OWNER FUNCTIONS

    function togglePool(address _pool)
        external
        onlyOwner
    {
        _pools[_pool] = !_pools[_pool];
    }

    function togglePrivatePool(address _pool)
        external
        onlyOwner
    {
        _privatePools[_pool] = !_privatePools[_pool];
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
            tokenAddress != address(rewardsToken) &&
            tokenAddress != address(stakingToken),
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

    function setTreasury(address _treasury)
        external
        onlyOwner
    {
        require(msg.sender == address(treasury), "!treasury");
        treasury = _treasury;
    }

    function setWithdrawalFee(uint _withdrawalFee)
        external
        onlyOwner
    {
        require(_withdrawalFee <= withdrawalFeeMax, "!withdrawalFee");
        withdrawalFee = _withdrawalFee;
    }

    function setLockingPeriods(uint _minimumLock, uint _maximumLock) 
        external 
        onlyOwner 
    {
        require(
            _maximumLock <= 52 weeks,
            '!maximumLock'
        );
        require(
            _minimumLock < _maximumLock,
            '!minLock>maxLock'
        );
        minimumLock = _minimumLock;
        maximumLock = _maximumLock;
    }

    function setMultiplier(uint _multiplier) external onlyOwner {
        multiplier = _multiplier;
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

    error ZeroRewards();

    // EVENTS

    event RewardAdded(uint reward);
    event Deposited(address indexed user, uint amount, uint lock);
    event Withdrawn(address indexed user, uint amount);
    event Locked(address indexed user, uint shares);
    event Unlocked(address indexed user, uint shares);
    event RewardPaid(address indexed user, uint reward);
    event RewardStaked(address indexed user, uint reward);
    event RewardsDurationUpdated(uint newDuration);
    event Recovered(address token, uint amount);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStakingPool {
    function balanceOf(address account) external view returns (uint);
    function lockedOf(address account) external view returns (uint);
    function availableOf(address account) external view returns (uint);
    function lock(address account, uint shares) external;
    function unlock(address account, uint shares) external;
    function depositFor(address account, uint amount) external;
    function setPaused(bool _paused) external;
    function setStakingToken(address _stakingToken) external;
    function notifyRewardAmount(uint reward) external;
    function setRewardsDuration(uint _rewardsDuration) external;
}
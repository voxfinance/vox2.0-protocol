// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/*
    VOX FINANCE 2.0

    Website: https://vox.finance
    Twitter: https://twitter.com/RealVoxFinance
    Telegram: https://t.me/VoxFinance
 */

contract VoxTokenAirdrop is Ownable2Step {
    // This declares a state variable that would store the contract address
    IERC20 public token;

    constructor () {}

    function setToken(address _token) external onlyOwner {
        token = IERC20(_token);
    }

    function sendBatch(address[] calldata _recipients, uint[] calldata _values) external onlyOwner returns (bool) {
        require(_recipients.length == _values.length);
        for (uint i = 0; i < _values.length; i++) {
            token.transfer(_recipients[i], _values[i]);
        }
        
        return true;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVOXToken is IERC20 {
    function uniswapV2Router() external returns (address);
    function uniswapV2Pair() external returns (address);

    function weth() external returns (address);
}
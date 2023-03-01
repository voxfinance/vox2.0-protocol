// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISwapManager {
    function addLiquidity(uint voxAmount, uint wethAmount) external;
    function swapToWeth(uint voxAmount) external;
    function buyAndBurn(uint wethAmount) external;
}
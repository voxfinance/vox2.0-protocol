// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IVoxToken.sol";

/*
    VOX FINANCE 2.0

    Website: https://vox.finance
    Twitter: https://twitter.com/RealVoxFinance
    Telegram: https://t.me/VoxFinance
 */

contract VoxSwapManager is Ownable {
    using SafeMath for uint;

    address public constant deadAddress = address(0xdead);
    IVOXToken public immutable vox;

    address public marketingWallet;

    constructor (
        address _vox
    ) {
        // set contract address prior to deploying
        vox = IVOXToken(_vox);
        marketingWallet = address(0xB565A72868A70da734DA10e3750196Dd82Cb7f16);
    }

    event AddLiquidity(
        uint voxAmount,
        uint wethAmount,
        uint timestamp
    );

    event BuybackAndBurn(
        uint wethAmount,
        uint voxAmount,
        uint timestamp
    );

    function addLiquidity(uint voxAmount, uint wethAmount) external {
        require(
            msg.sender == address(vox),
            "Only VOX token can call this function"
        );

        vox.transferFrom(address(vox), address(this), voxAmount);
        IERC20(vox.weth()).transferFrom(address(vox), address(this), wethAmount);

        IUniswapV2Router02 router = IUniswapV2Router02(vox.uniswapV2Router());

        vox.approve(address(router), voxAmount);
        IERC20(vox.weth()).approve(address(router), wethAmount);

        router.addLiquidity(
            address(vox),
            vox.weth(),
            voxAmount,
            wethAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );

        emit AddLiquidity(voxAmount, wethAmount, block.timestamp);
    }

    function swapToWeth(uint voxAmount) external {
        require(
            msg.sender == address(vox),
            "Only VOX token can call this function"
        );

        vox.transferFrom(address(vox), address(this), voxAmount);
        
        address[] memory path = new address[](2);
        path[0] = address(vox);
        path[1] = vox.weth();

        IUniswapV2Router02 router = IUniswapV2Router02(vox.uniswapV2Router());
        vox.approve(address(router), voxAmount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            voxAmount,
            0,
            path,
            address(this),
            block.timestamp
        );

        IERC20(vox.weth()).transfer(address(vox), IERC20(vox.weth()).balanceOf(address(this)));
    }

    function buyAndBurn(uint wethAmount) external {
        require(
            msg.sender == address(vox),
            "Only VOX token can call this function"
        );

        IERC20(vox.weth()).transferFrom(address(vox), address(this), wethAmount);
        
        address[] memory path = new address[](2);
        path[0] = vox.weth();
        path[1] = address(vox);

        IUniswapV2Router02 router = IUniswapV2Router02(vox.uniswapV2Router());
        IERC20(vox.weth()).approve(address(router), wethAmount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wethAmount,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint balance = vox.balanceOf(address(this));

        vox.transfer(deadAddress, balance);

        emit BuybackAndBurn(wethAmount, balance, block.timestamp);
    }

    function recover(address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
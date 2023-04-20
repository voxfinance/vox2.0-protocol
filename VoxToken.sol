// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/ISwapManager.sol";

/*
    VOX FINANCE 2.0

    Website: https://vox.finance
    Twitter: https://twitter.com/RealVoxFinance
    Telegram: https://t.me/VoxFinance
 */

contract VoxToken is ERC20, Ownable2Step {
    using SafeMath for uint;

    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;
    address public immutable weth;
    address public constant deadAddress = address(0xdead);

    bool private swapping;

    address public marketingWallet;

    ISwapManager public swapManager;
    uint public maxTransactionAmount;
    uint public swapTokensAtAmount;
    uint public maxWallet;

    bool public limitsInEffect = true;
    bool public tradingActive = false;
    bool public swapEnabled = false;

    // Anti-bot and anti-whale mappings and variables
    mapping(address => uint) private _holderLastTransferTimestamp; // to hold last Transfers temporarily during launch
    bool public transferDelayEnabled = true;

    uint public buyTotalFees;
    uint public buyMarketingFee;
    uint public buyLiquidityFee;
    uint public buyBurnFee;

    uint public sellTotalFees;
    uint public sellMarketingFee;
    uint public sellLiquidityFee;
    uint public sellBurnFee;

    uint public tokensForMarketing;
    uint public tokensForLiquidity;
    uint public tokensForBurn;

    // exlcude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) public _isExcludedMaxTransactionAmount;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    event UpdateUniswapV2Router(
        address indexed newAddress,
        address indexed oldAddress
    );

    event ExcludeFromFees(address indexed account, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event SwapManagerUpdated(
        address indexed newManager,
        address indexed oldManager
    );

    event MarketingWalletUpdated(
        address indexed newWallet,
        address indexed oldWallet
    );

    event OperationsWalletUpdated(
        address indexed newWallet,
        address indexed oldWallet
    );

    event TeamWalletUpdated(
        address indexed newWallet,
        address indexed oldWallet
    );

    event SwapAndLiquify(
        uint tokensSwapped,
        uint usdcReceived,
        uint tokensIntoLiquidity
    );

    constructor() ERC20("Vox Finance 2.0", "VOX2.0") {
        // BSC TESTNET ROUTER: 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3
        // FANTOM TESTNET ROUTER: 0xa6AD18C2aC47803E193F75c3677b14BF19B94883
        // ARBITRUM GOERLI ROUTER: 0x81cD91B6BD7D275a7AeebBA15929AE0f0751d18C
        // ARBITRUM MAINNET SUSHI ROUTER: 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506);

        // ARBITRUM GOERLI WETH: 0xEe01c0CD76354C383B8c7B4e65EA88D00B06f36f
        // ARBITRUM MAINNET WETH: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
        weth = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);

        excludeFromMaxTransaction(address(_uniswapV2Router), true);
        uniswapV2Router = _uniswapV2Router;

        address pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), weth);
            
        uniswapV2Pair = pair;
        excludeFromMaxTransaction(pair, true);
        _setAutomatedMarketMakerPair(pair, true);

        uint totalSupply = 45_000 * 1e18;

        maxTransactionAmount = totalSupply * 5 / 1000;
        maxWallet = totalSupply / 100;
        swapTokensAtAmount = totalSupply / 2000;

        buyMarketingFee = 2;
        buyLiquidityFee = 1;
        buyBurnFee = 1;
        buyTotalFees = buyMarketingFee + buyLiquidityFee + buyBurnFee;

        sellMarketingFee = 2;
        sellLiquidityFee = 1;
        sellBurnFee = 1;
        sellTotalFees = sellMarketingFee + sellLiquidityFee + sellBurnFee;

        marketingWallet = address(0xB565A72868A70da734DA10e3750196Dd82Cb7f16);

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeFromFees(deadAddress, true);
        excludeFromFees(marketingWallet, true);

        excludeFromMaxTransaction(owner(), true);
        excludeFromMaxTransaction(address(this), true);
        excludeFromMaxTransaction(deadAddress, true);
        excludeFromMaxTransaction(marketingWallet, true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(msg.sender, totalSupply);
    }

    // once enabled, can never be turned off
    function enableTrading() external onlyOwner {
        require (
            address(swapManager) != address(0), 
            "Need to set swap manager"
        );
        tradingActive = true;
        swapEnabled = true;
    }

    // remove limits after token is stable
    function removeLimits() external onlyOwner returns (bool) {
        limitsInEffect = false;
        return true;
    }

    // disable Transfer delay - cannot be reenabled
    function disableTransferDelay() external onlyOwner returns (bool) {
        transferDelayEnabled = false;
        return true;
    }

    // change the minimum amount of tokens to sell from fees
    function updateSwapTokensAtAmount(uint newAmount)
        external
        onlyOwner
        returns (bool)
    {
        require(
            newAmount >= (totalSupply() * 1) / 100000,
            "Swap amount cannot be lower than 0.001% total supply."
        );
        require(
            newAmount <= (totalSupply() * 5) / 1000,
            "Swap amount cannot be higher than 0.5% total supply."
        );
        swapTokensAtAmount = newAmount;
        return true;
    }

    function excludeFromMaxTransaction(address updAds, bool isEx)
        public
        onlyOwner
    {
        _isExcludedMaxTransactionAmount[updAds] = isEx;
    }

    function updateSwapManager(address newManager) external onlyOwner {
        emit SwapManagerUpdated(newManager, address(swapManager));
        swapManager = ISwapManager(newManager);
        excludeFromFees(newManager, true);
        excludeFromMaxTransaction(newManager, true);
    }

    // only use to disable contract sales if absolutely necessary (emergency use only)
    function updateSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    function setAutomatedMarketMakerPair(address pair, bool value)
        public
        onlyOwner
    {
        require(
            pair != uniswapV2Pair,
            "The pair cannot be removed from automatedMarketMakerPairs"
        );

        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value;

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function updateMarketingWallet(address newMarketingWallet)
        external
        onlyOwner
    {
        emit MarketingWalletUpdated(newMarketingWallet, marketingWallet);
        marketingWallet = newMarketingWallet;
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function _transfer(
        address from,
        address to,
        uint amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if (limitsInEffect) {
            if (
                from != owner() &&
                to != owner() &&
                to != address(0) &&
                to != address(0xdead) &&
                !swapping
            ) {
                if (!tradingActive) {
                    require(
                        _isExcludedFromFees[from] || _isExcludedFromFees[to],
                        "Trading is not active."
                    );
                } else {
                    // at launch if the transfer delay is enabled, ensure the block timestamps for purchasers is set -- during launch.
                    if (transferDelayEnabled) {
                        if (
                            to != owner() &&
                            to != address(uniswapV2Router) &&
                            to != address(uniswapV2Pair) &&
                            !_isExcludedFromFees[from]
                        ) {
                            require(
                                _holderLastTransferTimestamp[tx.origin] <
                                    block.number,
                                "_transfer:: Transfer Delay enabled.  Only one purchase per block allowed."
                            );
                            _holderLastTransferTimestamp[tx.origin] = block.number;
                        }
                    }

                    //when buy
                    if (
                        automatedMarketMakerPairs[from] &&
                        !_isExcludedMaxTransactionAmount[to]
                    ) {
                        require(
                            amount <= maxTransactionAmount,
                            "Buy transfer amount exceeds the maxTransactionAmount."
                        );
                        require(
                            amount + balanceOf(to) <= maxWallet,
                            "Max wallet exceeded"
                        );
                    }
                    //when sell
                    else if (
                        automatedMarketMakerPairs[to] &&
                        !_isExcludedMaxTransactionAmount[from]
                    ) {
                        require(
                            amount <= maxTransactionAmount,
                            "Sell transfer amount exceeds the maxTransactionAmount."
                        );
                    } else if (!_isExcludedMaxTransactionAmount[to]) {
                        require(
                            amount + balanceOf(to) <= maxWallet,
                            "Max wallet exceeded"
                        );
                    }
                }
            }
        }

        uint contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if (
            canSwap &&
            swapEnabled &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            !_isExcludedFromFees[from] &&
            !_isExcludedFromFees[to]
        ) {
            swapping = true;

            swapBack();

            swapping = false;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        uint fees = 0;
        // only take fees on buys/sells, do not take on wallet transfers
        if (takeFee) {
            // on sell
            if (automatedMarketMakerPairs[to] && sellTotalFees > 0) {
                fees = amount.mul(sellTotalFees).div(100);
                tokensForMarketing += (fees * sellMarketingFee) / sellTotalFees;
                tokensForLiquidity += (fees * sellLiquidityFee) / sellTotalFees;
                tokensForBurn += (fees * sellBurnFee) / sellTotalFees;
                
            }
            // on buy
            else if (automatedMarketMakerPairs[from] && buyTotalFees > 0) {
                fees = amount.mul(buyTotalFees).div(100);
                tokensForMarketing += (fees * buyMarketingFee) / buyTotalFees;
                tokensForLiquidity += (fees * buyLiquidityFee) / buyTotalFees;
                tokensForBurn += (fees * buyBurnFee) / buyTotalFees;
            }

            if (fees > 0) {
                super._transfer(from, address(this), fees);
            }

            amount -= fees;
        }

        super._transfer(from, to, amount);
    }

    function swapBack() private {
        uint contractBalance = balanceOf(address(this));
        uint totalTokensToSwap = tokensForMarketing +
            tokensForLiquidity +
            tokensForBurn;

        if (contractBalance == 0 || totalTokensToSwap == 0) {
            return;
        }

        if (contractBalance > swapTokensAtAmount * 20) {
            contractBalance = swapTokensAtAmount * 20;
        }

        // Halve the amount of liquidity tokens
        uint liquidityTokens = (contractBalance * tokensForLiquidity) /
            totalTokensToSwap / 2;
        uint amountToSwapForEth = contractBalance.sub(liquidityTokens);

        uint initialEthBalance = IERC20(weth).balanceOf(address(this));

        _approve(address(this), address(swapManager), amountToSwapForEth);
        swapManager.swapToWeth(amountToSwapForEth);

        uint wethBalance = IERC20(weth).balanceOf(address(this)).sub(initialEthBalance);

        uint ethForMarketing = wethBalance.mul(tokensForMarketing).div(totalTokensToSwap);
        uint ethForLiquidity = wethBalance.mul(tokensForLiquidity).div(totalTokensToSwap);
        uint ethForBurn = wethBalance - ethForMarketing - ethForLiquidity;

        tokensForMarketing = 0;
        tokensForLiquidity = 0;
        tokensForBurn = 0;

        IERC20(weth).transfer(marketingWallet, ethForMarketing);

        if (liquidityTokens > 0 && ethForLiquidity > 0) {
            _approve(address(this), address(swapManager), liquidityTokens);
            IERC20(weth).approve(address(swapManager), ethForLiquidity);

            swapManager.addLiquidity(liquidityTokens, ethForLiquidity);
            emit SwapAndLiquify(
                amountToSwapForEth,
                ethForLiquidity,
                tokensForLiquidity
            );
        }

        IERC20(weth).approve(address(swapManager), ethForBurn);
        swapManager.buyAndBurn(ethForBurn);
    }

    function recover(address _token) external onlyOwner {
        require(_token != address(this), "Can not recover base token");
        uint balance = IERC20(_token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(_token).transfer(owner(), balance);
        }
    }
}
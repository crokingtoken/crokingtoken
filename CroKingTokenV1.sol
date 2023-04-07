// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IWETH.sol";

import "./DividendTracker.sol";

contract CroKingToken is ERC20, Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public wbnb;
    address public uniswapV2Pair;

    bool private swapping;

    DividendTracker public dividendTracker;

    address public constant deadWallet = 0x000000000000000000000000000000000000dEaD;

    uint256 public swapTokensAtAmount = 2000000 * (10**9);

    mapping(address => bool) public _isBlacklisted;
    mapping(address => bool) public _isWhitelisted;

    uint256 public bnbRewardsFee = 5;
    uint256 public liquidityFee = 5;
    uint256 public marketingFee = 2;
    uint256 public totalFees =
        bnbRewardsFee.add(liquidityFee).add(marketingFee);

    bool private tradingOpen = false;

    address public _marketingWalletAddress;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

    uint256 public maxWalletBalance;    

    bool public initialized = false;

    mapping(address => bool) public excludedFromMaxBalance;

    // exlcude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);

    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);

    event LiquidityWalletUpdated(
        address indexed newLiquidityWallet,
        address indexed oldLiquidityWallet
    );

    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);

    event SendDividends(uint256 tokensSwapped, uint256 amount);

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    event FeesChanged(
        uint256 bnbRewardsFee,
        uint256 liquidityFee,
        uint256 marketingFee
    );

    event MarketingWalletChanged(address indexed oldWallet, address indexed newWallet);

    event BlacklistAddress(address indexed user, bool value);
    event WhitelistAddress(address indexed user, bool value);
    event Error(bytes data);

    event ExcludedFromMaxBalance(address indexed account, bool excluded);
    event MaxWalletBalanceUpdated(uint256 percent);
    event SwapTokensAtAmountUpdated(uint256 amount);

    constructor(
        string memory name, 
        string memory symbol,
        address marketingWalletAddress,
        IUniswapV2Router02 _uniswapV2Router
    ) public ERC20(name, symbol) {
        wbnb = _uniswapV2Router.WETH();
        uniswapV2Router = _uniswapV2Router;
        // Create a uniswap pair for this new token
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(
            address(this),
            wbnb
        );
        _marketingWalletAddress = marketingWalletAddress;
    }

    function initialize(address dividendTrackerAddress) external onlyOwner {
        require(!initialized, "initialized");
        initialized = true;
        DividendTracker _dividendTracker = DividendTracker(dividendTrackerAddress);
        dividendTracker = _dividendTracker;

        address _uniswapV2Pair = uniswapV2Pair;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        address _owner = owner();

        // exclude from receiving dividends
        _dividendTracker.excludeFromDividends(address(_dividendTracker));
        _dividendTracker.excludeFromDividends(address(this));
        _dividendTracker.excludeFromDividends(_owner);
        _dividendTracker.excludeFromDividends(deadWallet);
        _dividendTracker.excludeFromDividends(address(uniswapV2Router));

        // exclude from paying fees or having max transaction amount
        excludeFromFees(_owner, true);
        excludeFromFees(_marketingWalletAddress, true);
        excludeFromFees(address(this), true);

        excludedFromMaxBalance[_uniswapV2Pair] = true;
        excludedFromMaxBalance[address(this)] = true;
        excludedFromMaxBalance[_marketingWalletAddress] = true;

        emit MarketingWalletChanged(address(0), _marketingWalletAddress);

        _isWhitelisted[msg.sender] = true;
        _setupDecimals(9);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(_owner, 1_000_000_000_000_000 * (10**9));

        maxWalletBalance = totalSupply() * 2 / 100;
    }

    receive() external payable {}

    function updateDividendTracker(address newAddress) public onlyOwner {
        require(
            newAddress != address(dividendTracker),
            "The dividend tracker already has that address"
        );

        DividendTracker newDividendTracker = DividendTracker(payable(newAddress));

        require(
            newDividendTracker.owner() == address(this),
            "The new dividend tracker must be owned by the token contract"
        );

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));

        emit UpdateDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        address _oldUniswapV2Router = address(uniswapV2Router);
        require(newAddress != _oldUniswapV2Router, "The router already has that address");
        emit UpdateUniswapV2Router(newAddress, _oldUniswapV2Router);
        uniswapV2Router = IUniswapV2Router02(newAddress);
        address _wbnb = IUniswapV2Router02(newAddress).WETH();
        wbnb = _wbnb;
        address _uniswapV2Pair = IUniswapV2Factory(IUniswapV2Router02(newAddress).factory())
            .createPair(address(this), _wbnb);
        uniswapV2Pair = _uniswapV2Pair;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(
            _isExcludedFromFees[account] != excluded,
            "Account is already the value of 'excluded'"
        );
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] memory accounts, bool excluded)
        public
        onlyOwner
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setMarketingWallet(address payable wallet) external onlyOwner {
        emit MarketingWalletChanged(_marketingWalletAddress, wallet);
        _marketingWalletAddress = wallet;
    }


    function setFees(
        uint256 _bnbRewardsFee,
        uint256 _liquidityFee,
        uint256 _marketingFee
    ) external onlyOwner {
        require(
            _bnbRewardsFee + _liquidityFee + _marketingFee <= 20,
            "CRK: Too high fees"
        );

        bnbRewardsFee = _bnbRewardsFee;
        liquidityFee = _liquidityFee;
        marketingFee = _marketingFee;
        totalFees = _bnbRewardsFee.add(_liquidityFee).add(_marketingFee);

        emit FeesChanged(_bnbRewardsFee, _liquidityFee, _marketingFee);
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(
            pair != uniswapV2Pair,
            "The pair cannot be removed"
        );

        _setAutomatedMarketMakerPair(pair, value);
    }

    function blacklistAddress(address account, bool value) external onlyOwner {
        _isBlacklisted[account] = value;
        emit BlacklistAddress(account, value);
    }

    function whitelistAddress(address account, bool value) external onlyOwner {
        _isWhitelisted[account] = value;
        emit WhitelistAddress(account, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(
            automatedMarketMakerPairs[pair] != value,
            "Already set to that value"
        );
        automatedMarketMakerPairs[pair] = value;

        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(
            newValue >= 200000 && newValue <= 500000,
            "wrong gasForProcessing value"
        );
        require(
            newValue != gasForProcessing,
            "same value"
        );
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns (uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account) public view returns (uint256) {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function dividendTokenBalanceOf(address account) public view returns (uint256) {
        return dividendTracker.balanceOf(account);
    }

    function excludeFromDividends(address account) external onlyOwner {
        dividendTracker.excludeFromDividends(account);
    }

    function getAccountDividendsInfo(address account)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccount(account);
    }

    function getAccountDividendsInfoAtIndex(uint256 index)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccountAtIndex(index);
    }

    function processDividendTracker(uint256 gas) external {
        (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(
            gas
        );
        emit ProcessedDividendTracker(
            iterations,
            claims,
            lastProcessedIndex,
            false,
            gas,
            tx.origin
        );
    }

    function claim() external {
        dividendTracker.processAccount(msg.sender, false);
    }

    function getLastProcessedIndex() external view returns (uint256) {
        return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns (uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function openTrading() public onlyOwner {
        tradingOpen = true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "transfer from the zero address");
        require(to != address(0), "transfer to the zero address");
        require(!_isBlacklisted[from] && !_isBlacklisted[to], "Blacklisted");

        if (!_isWhitelisted[from] && !_isWhitelisted[to]) {
            require(tradingOpen, "no tranding");
        }

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        address _owner = owner();
        bool _swapping = swapping;
        uint256 _totalFees = totalFees;
        if (
            canSwap &&
            !_swapping &&
            !automatedMarketMakerPairs[from] &&
            from != _owner &&
            to != _owner
        ) {
            swapping = true;

            uint256 marketingTokens = contractTokenBalance.mul(marketingFee).div(_totalFees);
            swapAndSendToFee(marketingTokens, _marketingWalletAddress);

            uint256 swapTokens = contractTokenBalance.mul(liquidityFee).div(_totalFees);
            swapAndLiquify(swapTokens);

            uint256 sellTokens = balanceOf(address(this));
            swapAndSendDividends(sellTokens);

            swapping = false;
        }

        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account or not buy or sell then remove the fee
        if (!(automatedMarketMakerPairs[from] || automatedMarketMakerPairs[to]) || _isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if (takeFee) {
            uint256 fees = amount.mul(_totalFees).div(100);
            if (automatedMarketMakerPairs[to]) {
                fees += amount.mul(3).div(100);
            }
            amount = amount.sub(fees);

            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);
        if(!excludedFromMaxBalance[to]) {
            require(balanceOf(to) <= maxWalletBalance, "max wallet balance exceeded");
        }

        DividendTracker _dividendTracker = dividendTracker;
        _dividendTracker.setBalance(payable(from), balanceOf(from));
        _dividendTracker.setBalance(payable(to), balanceOf(to));

        require(gasleft() >= gasForProcessing + 100000, "insufficient gas");

        if (!_swapping) {
            uint256 gas = gasForProcessing;

            try _dividendTracker.process(gas) returns (
                uint256 iterations,
                uint256 claims,
                uint256 lastProcessedIndex
            ) {
                emit ProcessedDividendTracker(
                    iterations,
                    claims,
                    lastProcessedIndex,
                    true,
                    gas,
                    tx.origin
                );
            } catch (bytes memory data) {
                emit Error(data);
            }
        }
    }

    function swapAndSendToFee(uint256 tokens, address dest) private {
        address _wbnb = wbnb;
        uint256 initialBnbBalance = address(this).balance;

        swapTokensForEth(tokens);

        uint256 dividends = address(this).balance.sub(initialBnbBalance);
        IWETH(_wbnb).deposit{value: dividends}();
        IERC20(_wbnb).transfer(dest, dividends);
    }

    function swapAndLiquify(uint256 tokens) private {
        // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        IUniswapV2Router02 _uniswapV2Router = uniswapV2Router;

        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;

        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        // make the swap
        _uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        IUniswapV2Router02 _uniswapV2Router = uniswapV2Router;

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        // add the liquidity
        _uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );
    }

    function swapAndSendDividends(uint256 tokens) private {
        swapTokensForEth(tokens);

        address _wbnb = wbnb;
        DividendTracker _dividendTracker = dividendTracker;

        uint256 dividends = address(this).balance;
        try _dividendTracker.distributeDividends(dividends) {
            IWETH(_wbnb).deposit{value: dividends}();

            IERC20(_wbnb).transfer(address(_dividendTracker), dividends);
            emit SendDividends(tokens, dividends);
        } catch(bytes memory data) {
            emit Error(data);
        }

    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        try dividendTracker.setBalance(payable(msg.sender), balanceOf(msg.sender)) {} catch {}
    }

    function setMaxWalletBalancePercent(uint256 percent) external onlyOwner {
        require(percent >= 2, "min 2%");
        require(percent <= 100, "max 100%");
        maxWalletBalance = totalSupply() * percent / 100;
        emit MaxWalletBalanceUpdated(percent);
    }

    function setExcludedFromMaxBalance(address account, bool excluded) external onlyOwner {
        excludedFromMaxBalance[account] = excluded;
        emit ExcludedFromMaxBalance(account, excluded);
    }

    function setSwapTokensAtAmount(uint256 newSwapTokensAtAmount) external onlyOwner {
        require(newSwapTokensAtAmount >= 100000 * (10**9), "too small value");
        swapTokensAtAmount = newSwapTokensAtAmount;
        emit SwapTokensAtAmountUpdated(newSwapTokensAtAmount);
    }

}

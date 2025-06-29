// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Interface for a standard DEX Router like Uniswap V2
interface IDEXRouter {
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/**
 * @title BondingCurveToken
 * @dev An ERC20 token with a linear bonding curve for pricing.
 * Users can buy/sell tokens until the market cap threshold is reached,
 * triggering automatic liquidity pool creation on a DEX.
 */
contract BondingCurveToken is ERC20, Ownable, ReentrancyGuard {
    // --- State Variables ---

    // DEX Router (e.g., Uniswap V2 Router address)
    IDEXRouter public immutable dexRouter;
    
    // The price of the first token minted (in wei)
    uint256 public constant INITIAL_PRICE = 0.0000001 ether; 
    
    // Price increase per token minted (in wei)
    uint256 public constant PRICE_INCREMENT = 0.000000001 ether; 

    // Market cap threshold for DEX migration (in wei)
    uint256 public immutable marketCapThreshold;

    // Address of the token creator
    address public immutable creator;

    // Flag indicating if trading has moved to the DEX
    bool public isLiveOnDex = false;

    // Timestamp of contract creation
    uint256 public immutable createdAt;

    // --- Events ---

    event Bought(address indexed buyer, uint256 amountIn, uint256 tokensOut);
    event Sold(address indexed seller, uint256 tokensIn, uint256 amountOut);
    event MigratedToDex(address indexed tokenAddress, uint256 ethAmount, uint256 tokenAmount);
    event FundsRecovered(address indexed owner, uint256 ethAmount, uint256 tokenAmount);

    // --- Constructor ---

    /**
     * @dev Initializes the token with name, symbol, market cap threshold, creator, and DEX router.
     * @param name The name of the token.
     * @param symbol The symbol of the token.
     * @param _marketCapThreshold The market cap threshold for DEX migration (in wei).
     * @param _creator The address of the token creator.
     * @param _dexRouterAddress The address of the DEX router.
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 _marketCapThreshold,
        address _creator,
        address _dexRouterAddress
    ) ERC20(name, symbol) Ownable(_creator) {
        require(_marketCapThreshold > 0, "Market cap threshold must be greater than 0");
        require(_dexRouterAddress != address(0), "Invalid DEX router address");
        require(_creator != address(0), "Invalid creator address");

        marketCapThreshold = _marketCapThreshold;
        creator = _creator;
        dexRouter = IDEXRouter(_dexRouterAddress);
        createdAt = block.timestamp;
    }

    // --- Bonding Curve Functions ---

    /**
     * @dev Returns the current price of one token based on the bonding curve.
     * @return The current price in wei.
     */
    function getCurrentPrice() public view returns (uint256) {
        return INITIAL_PRICE + (totalSupply() * PRICE_INCREMENT);
    }

    /**
     * @dev Calculates the ETH cost to buy a specified number of tokens.
     * @param tokenAmount The number of tokens to buy.
     * @return The cost in wei.
     */
    function getCostToBuy(uint256 tokenAmount) public view returns (uint256) {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        uint256 supply = totalSupply();
        uint256 startPrice = INITIAL_PRICE + (supply * PRICE_INCREMENT);
        uint256 endPrice = startPrice + (tokenAmount * PRICE_INCREMENT);
        return ((startPrice + endPrice) / 2) * tokenAmount / 1 ether;
    }
    
    /**
     * @dev Calculates the ETH proceeds from selling a specified number of tokens.
     * @param tokenAmount The number of tokens to sell.
     * @return The proceeds in wei.
     */
    function getProceedsFromSell(uint256 tokenAmount) public view returns (uint256) {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(totalSupply() >= tokenAmount, "Cannot sell more than total supply");
        uint256 supply = totalSupply();
        uint256 endPrice = INITIAL_PRICE + (supply * PRICE_INCREMENT);
        uint256 startPrice = endPrice - (tokenAmount * PRICE_INCREMENT);
        return ((startPrice + endPrice) / 2) * tokenAmount / 1 ether;
    }

    /**
     * @dev Returns the current market capitalization of the token.
     * @return The market cap in wei.
     */
    function getMarketCap() public view returns (uint256) {
        return getCurrentPrice() * totalSupply() / 1 ether;
    }

    /**
     * @dev Returns all token details for frontend display.
     * @return tokenName Token name.
     * @return tokenSymbol Token symbol.
     * @return currentPrice Current token price in wei.
     * @return marketCap Current market cap in wei.
     * @return liveOnDex Whether trading has moved to the DEX.
     * @return tokenSupply Total token supply.
     */
    function getTokenDetails() external view returns (
        string memory tokenName,
        string memory tokenSymbol,
        uint256 currentPrice,
        uint256 marketCap,
        bool liveOnDex,
        uint256 tokenSupply
    ) {
        return (
            this.name(),
            this.symbol(),
            getCurrentPrice(),
            getMarketCap(),
            isLiveOnDex,
            totalSupply()
        );
    }

    /**
     * @dev Allows users to buy tokens with ETH based on the bonding curve.
     * @param minTokensToReceive Minimum tokens to receive (slippage protection).
     */
    function buy(uint256 minTokensToReceive) external payable nonReentrant {
        require(!isLiveOnDex, "Trading is now on the DEX");
        require(msg.value > 0, "Must send ETH to buy");

        uint256 tokensToMint = calculateTokensForEth(msg.value);
        require(tokensToMint >= minTokensToReceive, "Slippage: too few tokens");

        _mint(msg.sender, tokensToMint);

        emit Bought(msg.sender, msg.value, tokensToMint);

        if (getMarketCap() >= marketCapThreshold) {
            _migrateToDex();
        }
    }

    /**
     * @dev Allows users to sell tokens for ETH based on the bonding curve.
     * @param tokenAmount The number of tokens to sell.
     * @param minEthToReceive Minimum ETH to receive (slippage protection).
     */
    function sell(uint256 tokenAmount, uint256 minEthToReceive) external nonReentrant {
        require(!isLiveOnDex, "Trading is now on the DEX");
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient token balance");

        uint256 proceeds = getProceedsFromSell(tokenAmount);
        require(proceeds >= minEthToReceive, "Slippage: too little ETH");

        _burn(msg.sender, tokenAmount);
        Address.sendValue(payable(msg.sender), proceeds);

        emit Sold(msg.sender, tokenAmount, proceeds);
    }

    /**
     * @dev Allows the owner to recover stuck funds after a 30-day timelock.
     */
    function recoverFunds() external onlyOwner nonReentrant {
        require(block.timestamp > createdAt + 30 days, "Too early to recover funds");
        require(!isLiveOnDex, "Already migrated to DEX");

        uint256 ethBalance = address(this).balance;
        uint256 tokenBalance = balanceOf(address(this));

        if (ethBalance > 0) {
            Address.sendValue(payable(owner()), ethBalance);
        }
        if (tokenBalance > 0) {
            _transfer(address(this), owner(), tokenBalance);
        }

        emit FundsRecovered(owner(), ethBalance, tokenBalance);
    }

    // --- DEX Migration ---

    /**
     * @dev Migrates liquidity to the DEX when market cap threshold is reached.
     */
    function _migrateToDex() internal {
        isLiveOnDex = true;
        uint256 ethBalance = address(this).balance;
        uint256 tokenBalance = totalSupply();

        require(ethBalance > 0 && tokenBalance > 0, "Insufficient balance for migration");

        // Approve DEX router to spend tokens
        _approve(address(this), address(dexRouter), tokenBalance);

        // Add liquidity with 1% slippage tolerance
        uint256 minTokenAmount = tokenBalance * 99 / 100;
        uint256 minEthAmount = ethBalance * 99 / 100;

        (uint256 amountToken, uint256 amountETH, ) = dexRouter.addLiquidityETH{value: ethBalance}(
            address(this),
            tokenBalance,
            minTokenAmount,
            minEthAmount,
            creator,
            block.timestamp
        );

        emit MigratedToDex(address(this), amountETH, amountToken);
    }

    // --- Helper Functions ---

    /**
     * @dev Calculates the number of tokens that can be bought with a given ETH amount.
     * @param ethAmount The amount of ETH to spend (in wei).
     * @return The number of tokens to mint.
     */
    function calculateTokensForEth(uint256 ethAmount) public view returns (uint256) {
        require(ethAmount > 0, "ETH amount must be greater than 0");
        uint256 scaledEthAmount = ethAmount * 1e18;
        
        uint256 a = PRICE_INCREMENT / 2;
        uint256 b = (INITIAL_PRICE + (totalSupply() * PRICE_INCREMENT)) - a;
        uint256 c = scaledEthAmount;

        uint256 discriminant = (b * b) + (4 * a * c);
        uint256 sqrtDiscriminant = Math.sqrt(discriminant);

        return (sqrtDiscriminant - b) / PRICE_INCREMENT;
    }

    /**
     * @dev Fallback function to receive ETH.
     */
    receive() external payable {}
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// Interface for a standard DEX Router like Uniswap V2
/*
interface IDEXRouter {
    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );
}
*/

/**
 * @title BondingCurveToken
 * @dev An ERC20 token with a linear bonding curve for pricing.
 * This version includes robust mathematical handling to prevent overflows.
 */
contract BondingCurveToken is ERC20, Ownable, ReentrancyGuard {
    // --- State Variables ---

    // IDEXRouter public immutable dexRouter; // Commented out for now
    uint256 public immutable marketCapThreshold;
    address public immutable creator;

    // Using a scaling factor for all price calculations to maintain precision.
    uint256 private constant PRICE_PRECISION = 1e18;

    // Prices are now scaled up to avoid floating-point math.
    uint256 public constant INITIAL_PRICE_SCALED = 1e11; // 0.0000001 * 1e18
    uint256 public constant PRICE_INCREMENT_SCALED = 1e9;  // 0.000000001 * 1e18

    bool public isLiveOnDex = false;
    uint256 public immutable createdAt;

    // --- Events ---

    event Bought(address indexed buyer, uint256 ethIn, uint256 tokensOut);
    event Sold(address indexed seller, uint256 tokensIn, uint256 ethOut);
    event FundsRecovered(address indexed owner, uint256 ethAmount, uint256 tokenAmount);

    // --- Constructor ---

    constructor(
        string memory name,
        string memory symbol,
        uint256 _marketCapThreshold,
        address _creator,
        address _dexRouterAddress
    ) ERC20(name, symbol) Ownable(_creator) {
        require(_marketCapThreshold > 0, "Market cap threshold must be > 0");
        require(_creator != address(0), "Invalid creator address");

        marketCapThreshold = _marketCapThreshold;
        creator = _creator;
        createdAt = block.timestamp;

        _transferOwnership(_creator);

        // dexRouter = IDEXRouter(_dexRouterAddress); // Commented out
    }

    // --- Bonding Curve View Functions ---

    function getCurrentPrice() public view returns (uint256) {
        uint256 scaledPrice = INITIAL_PRICE_SCALED + (totalSupply() * PRICE_INCREMENT_SCALED) / PRICE_PRECISION;
        return scaledPrice;
    }

    function getMarketCap() public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return (getCurrentPrice() * totalSupply()) / PRICE_PRECISION;
    }

    function getCostToBuy(uint256 tokenAmount) public view returns (uint256) {
        require(tokenAmount > 0, "Token amount must be > 0");
        uint256 supply = totalSupply();
        uint256 startPrice = INITIAL_PRICE_SCALED + (supply * PRICE_INCREMENT_SCALED) / PRICE_PRECISION;
        uint256 endPrice = INITIAL_PRICE_SCALED + ((supply + tokenAmount) * PRICE_INCREMENT_SCALED) / PRICE_PRECISION;

        return ((startPrice + endPrice) * tokenAmount) / 2 / PRICE_PRECISION;
    }

    function getProceedsFromSell(uint256 tokenAmount) public view returns (uint256) {
        require(tokenAmount > 0, "Token amount must be > 0");
        uint256 supply = totalSupply();
        require(supply >= tokenAmount, "Sell amount exceeds total supply");
        uint256 startPrice = INITIAL_PRICE_SCALED + ((supply - tokenAmount) * PRICE_INCREMENT_SCALED) / PRICE_PRECISION;
        uint256 endPrice = INITIAL_PRICE_SCALED + (supply * PRICE_INCREMENT_SCALED) / PRICE_PRECISION;
        return ((startPrice + endPrice) * tokenAmount) / 2 / PRICE_PRECISION;
    }

    function calculateTokensForEth(uint256 ethAmount) public view returns (uint256) {
        require(ethAmount > 0, "ETH amount must be > 0");
        uint256 supply = totalSupply();
        uint256 p0 = INITIAL_PRICE_SCALED + (supply * PRICE_INCREMENT_SCALED) / PRICE_PRECISION;
        uint256 b = PRICE_INCREMENT_SCALED;

        uint256 scaledEthAmount = ethAmount * PRICE_PRECISION;
        uint256 p0_squared = p0 * p0;
        uint256 term = (2 * scaledEthAmount * b) / PRICE_PRECISION;
        uint256 discriminant = p0_squared + term;
        uint256 sqrtDiscriminant = Math.sqrt(discriminant);

        if (sqrtDiscriminant <= p0) {
            return 0;
        }

        uint256 numerator = sqrtDiscriminant - p0;
        return (numerator * PRICE_PRECISION) / b;
    }

    // --- Core Functions ---

    function buy(uint256 minTokensToReceive) external payable nonReentrant {
        require(!isLiveOnDex, "Trading has moved to the DEX");
        require(msg.value > 0, "Must send ETH to buy");

        uint256 tokensToMint = calculateTokensForEth(msg.value);
        require(tokensToMint > 0, "ETH amount is too low to buy any tokens");
        require(tokensToMint >= minTokensToReceive, "Slippage: not enough tokens received");

        _mint(msg.sender, tokensToMint);
        emit Bought(msg.sender, msg.value, tokensToMint);

        if (getMarketCap() >= marketCapThreshold) {
            _migrateToDex();
        }
    }

    function sell(uint256 tokenAmount, uint256 minEthToReceive) external nonReentrant {
        require(!isLiveOnDex, "Trading has moved to the DEX");
        require(tokenAmount > 0, "Token amount must be > 0");
        uint256 userBalance = balanceOf(msg.sender);
        require(userBalance >= tokenAmount, "Insufficient token balance");

        uint256 proceeds = getProceedsFromSell(tokenAmount);
        require(proceeds >= minEthToReceive, "Slippage: not enough ETH received");
        require(address(this).balance >= proceeds, "Contract has insufficient ETH to pay");

        _burn(msg.sender, tokenAmount);
        Address.sendValue(payable(msg.sender), proceeds);
        emit Sold(msg.sender, tokenAmount, proceeds);
    }

    function recoverFunds() external onlyOwner nonReentrant {
        require(block.timestamp > createdAt + 30 days, "Timelock not expired");
        require(!isLiveOnDex, "Cannot recover funds after DEX migration");

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

    function getTokenDetails()
        external
        view
        returns (
            string memory tokenName,
            string memory tokenSymbol,
            uint256 currentPrice,
            uint256 marketCap,
            bool liveOnDex,
            uint256 tokenSupply
        )
    {
        return (
            name(),
            symbol(),
            getCurrentPrice(),
            getMarketCap(),
            isLiveOnDex,
            totalSupply()
        );
    }

    // --- Internal & Fallback Functions ---

    function _migrateToDex() internal {
        isLiveOnDex = true;
        // Migration logic has been disabled for now
        // uint256 ethBalance = address(this).balance;
        // uint256 tokenBalance = totalSupply();
        // require(ethBalance > 0 && tokenBalance > 0, "Insufficient balances for migration");

        // _approve(address(this), address(dexRouter), tokenBalance);

        // dexRouter.addLiquidityETH{value: ethBalance}(
        //     address(this),
        //     tokenBalance,
        //     0, // amountTokenMin
        //     0, // amountETHMin
        //     creator,
        //     block.timestamp
        // );

        // emit MigratedToDex(address(this), ethBalance, tokenBalance);
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BondingCurveToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title TokenFactory
 * @dev Deploys BondingCurveToken contracts and maintains a registry with metadata.
 * Optimized for gas efficiency and scalability with pagination support.
 */
contract TokenFactory is Ownable {
    // --- State Variables ---

    // Struct to store token metadata
    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        string logoURI;
        uint256 marketCapThreshold;
        address creator;
    }

    // Struct for paginated token details
    struct TokenDetails {
        address tokenAddress;
        string name;
        string symbol;
        string logoURI;
        uint256 marketCapThreshold;
        address creator;
        uint256 currentPrice;
        uint256 marketCap;
        bool isLiveOnDex;
        uint256 totalSupply;
    }

    // Array of all tokens created
    TokenInfo[] public allTokens;

    // Creation fee in wei
    uint256 public creationFee = 0 ether;

    // DEX router address
    address public dexRouterAddress;

    // Fee wallet address
    address payable public feeWallet;

    // --- Events ---

    event TokenCreated(address indexed tokenAddress, address indexed creator, uint256 marketCapThreshold);
    event CreationFeeUpdated(uint256 newFee);
    event FeeWalletUpdated(address newFeeWallet);
    event DexRouterUpdated(address newDexRouter);

    // --- Constructor ---

    /**
     * @dev Initializes the factory with a DEX router and fee wallet.
     * @param _dexRouterAddress DEX router address.
     * @param _feeWallet Fee recipient address.
     */
    constructor(address _dexRouterAddress, address payable _feeWallet) Ownable(msg.sender) {
        require(_dexRouterAddress != address(0), "Invalid DEX router");
        require(_feeWallet != address(0), "Invalid fee wallet");
        dexRouterAddress = _dexRouterAddress;
        feeWallet = _feeWallet;
    }

    // --- Core Functions ---

    /**
     * @dev Creates a new BondingCurveToken with metadata.
     * @param name Token name.
     * @param symbol Token symbol.
     * @param logoURI Token logo URI.
     * @param marketCapThreshold Market cap threshold in wei.
     * @return Address of the new token.
     */
    function createToken(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        uint256 marketCapThreshold
    ) external payable returns (address) {
        require(msg.value >= creationFee, "Insufficient creation fee");
        require(bytes(name).length > 0, "Empty name");
        require(bytes(symbol).length > 0, "Empty symbol");
        require(marketCapThreshold > 0, "Invalid threshold");

        BondingCurveToken newToken = new BondingCurveToken(
            name,
            symbol,
            marketCapThreshold,
            msg.sender,
            dexRouterAddress
        );

        address tokenAddress = address(newToken);
        allTokens.push(TokenInfo({
            tokenAddress: tokenAddress,
            name: name,
            symbol: symbol,
            logoURI: logoURI,
            marketCapThreshold: marketCapThreshold,
            creator: msg.sender
        }));

        if (msg.value > 0) {
            Address.sendValue(feeWallet, msg.value);
        }

        emit TokenCreated(tokenAddress, msg.sender, marketCapThreshold);
        return tokenAddress;
    }

    /**
     * @dev Updates the creation fee.
     * @param newFee New fee in wei.
     */
    function updateCreationFee(uint256 newFee) external onlyOwner {
        creationFee = newFee;
        emit CreationFeeUpdated(newFee);
    }

    /**
     * @dev Updates the fee wallet.
     * @param newFeeWallet New fee wallet address.
     */
    function updateFeeWallet(address payable newFeeWallet) external onlyOwner {
        require(newFeeWallet != address(0), "Invalid fee wallet");
        feeWallet = newFeeWallet;
        emit FeeWalletUpdated(newFeeWallet);
    }

    /**
     * @dev Updates the DEX router.
     * @param newDexRouter New DEX router address.
     */
    function updateDexRouter(address newDexRouter) external onlyOwner {
        require(newDexRouter != address(0), "Invalid DEX router");
        dexRouterAddress = newDexRouter;
        emit DexRouterUpdated(newDexRouter);
    }

    // --- View Functions ---

    /**
     * @dev Returns the total number of tokens created.
     * @return Number of tokens.
     */
    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /**
     * @dev Returns a paginated list of token details.
     * @param offset Starting index.
     * @param limit Number of tokens to return.
     * @return details Array of TokenDetails structs.
     */
    function getPaginatedTokens(uint256 offset, uint256 limit) 
        external 
        view 
        returns (TokenDetails[] memory details) 
    {
        uint256 count = allTokens.length;
        if (offset >= count || limit == 0) {
            return new TokenDetails[](0);
        }

        uint256 size = offset + limit > count ? count - offset : limit;
        details = new TokenDetails[](size);

        for (uint256 i = 0; i < size; ) {
            TokenInfo storage token = allTokens[offset + i];
            BondingCurveToken tokenContract = BondingCurveToken(payable(token.tokenAddress));
            (
                , // Skip tokenName
                , // Skip tokenSymbol
                uint256 price,
                uint256 marketCap,
                bool liveOnDex,
                uint256 supply
            ) = tokenContract.getTokenDetails();

            details[i] = TokenDetails({
                tokenAddress: token.tokenAddress,
                name: token.name,
                symbol: token.symbol,
                logoURI: token.logoURI,
                marketCapThreshold: token.marketCapThreshold,
                creator: token.creator,
                currentPrice: price,
                marketCap: marketCap,
                isLiveOnDex: liveOnDex,
                totalSupply: supply
            });

            unchecked { ++i; }
        }

        return details;
    }
}
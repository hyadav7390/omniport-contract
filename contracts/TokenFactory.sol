// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BondingCurveToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract TokenFactory is Ownable {
    // --- State Variables ---
    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        string logoURI;
        uint256 marketCapThreshold;
        address creator;
    }

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
        uint256 holders;
        uint256 createdAt;
    }

    TokenInfo[] public allTokens;
    uint256 public creationFee = 0 ether;
    address public dexRouterAddress;
    address payable public feeWallet;

    // --- Events ---
    event TokenCreated(address indexed tokenAddress, address indexed creator, uint256 marketCapThreshold);
    event CreationFeeUpdated(uint256 newFee);
    event FeeWalletUpdated(address newFeeWallet);
    event DexRouterUpdated(address newDexRouter);

    // --- Constructor ---
    constructor(address _dexRouterAddress, address payable _feeWallet) Ownable(msg.sender) {
        require(_dexRouterAddress != address(0), "Invalid DEX router");
        require(_feeWallet != address(0), "Invalid fee wallet");
        dexRouterAddress = _dexRouterAddress;
        feeWallet = _feeWallet;
    }

    // --- Core Functions ---
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

    function updateCreationFee(uint256 newFee) external onlyOwner {
        creationFee = newFee;
        emit CreationFeeUpdated(newFee);
    }

    function updateFeeWallet(address payable newFeeWallet) external onlyOwner {
        require(newFeeWallet != address(0), "Invalid fee wallet");
        feeWallet = newFeeWallet;
        emit FeeWalletUpdated(newFeeWallet);
    }

    function updateDexRouter(address newDexRouter) external onlyOwner {
        require(newDexRouter != address(0), "Invalid DEX router");
        dexRouterAddress = newDexRouter;
        emit DexRouterUpdated(newDexRouter);
    }

    // --- View Functions ---
    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }

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

        for (uint256 i = 0; i < size;) {
            TokenInfo storage token = allTokens[offset + i];
            BondingCurveToken tokenContract = BondingCurveToken(payable(token.tokenAddress));
            (
                string memory tokenName,
                string memory tokenSymbol,
                uint256 price,
                uint256 marketCap,
                bool liveOnDex,
                uint256 supply,
                uint256 holders
            ) = tokenContract.getTokenDetails();

            details[i] = TokenDetails({
                tokenAddress: token.tokenAddress,
                name: tokenName,
                symbol: tokenSymbol,
                logoURI: token.logoURI,
                marketCapThreshold: token.marketCapThreshold,
                creator: token.creator,
                currentPrice: price,
                marketCap: marketCap,
                isLiveOnDex: liveOnDex,
                totalSupply: supply,
                holders: holders,
                createdAt: tokenContract.getCreatedAt()
            });

            unchecked { ++i; }
        }

        return details;
    }
}
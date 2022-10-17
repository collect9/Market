// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


struct TokenInfo {
    uint64 usdMin; // Lowest bound price
    uint64 usdMax; // Starting and maximum bound price
    uint128 listTimeStamp;
}


contract Collect9Market is Ownable, ReentrancyGuard {

    AggregatorV3Interface internal priceFeed;
    address payable public Owner;
    uint256 minEthPrice = 100000000000000000;

    mapping(uint256 => bool) listedTokens;
    mapping(uint256 => TokenInfo) tokenInfo;

    event TokenBought(
        address indexed buyer,
        address indexed origin,
        uint256 indexed tokenId,
        uint256 price
    );

    /**
     * Modifier to make sure token is listed.
     */
    modifier tokenExists(uint256 _tokenId) {
        require(listedTokens[_tokenId], "Token not listed.");
        _;
    }

    /**
     * Modifier to prevent accidental bad price entries.
     */
    modifier validPriceRange(uint64[2] calldata _usdRange) {
        require(_usdRange[1] > _usdRange[0], "High price must be greater than low.");
        require(_usdRange[0] > 50, "Min USD price too low.");
        require(_usdRange[1] < 10000000, "Max USD price too high.");
        _;
    }

    /**
     * Aggregator: ETH/USD
     * Network: Goerli
     * Address: 0xD4a33860578De61DBAbDc8BFdb98FD742fA7028e
     * Network: Mainnet
     * Address: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
     */
    constructor(address _priceFeedAddress) {
        setPriceFeed(_priceFeedAddress);
        Owner = payable(msg.sender);
    }

    /**
     * Make sure the price is within valid bounds, else 
     * return bound exceeded.
     */
    function constrainPrice(uint256 _price, uint256 _min, uint256 _max) internal pure
    returns (uint256) {
        if (_price < _min) {
            return _min;
        }
        if (_price > _max) {
            return _max;
        }
        return _price;
    }

    /**
     * Returns the latest price of ETHUSD with 8 decimals.
     */
    function getLatestETHPrice() internal view
    returns (uint256) {
        (,int256 price,,uint256 timeStamp,) = priceFeed.latestRoundData();
        require(block.timestamp - timeStamp < 3600, "Price feed not recent enough, try again later."); //Make sure price data is less than 1 hour old
        return uint256(price);
    }

    /**
     * Returns an array of token info.
     */
    function getTokenInfo(uint256 _tokenId) public view
    tokenExists(_tokenId)
    returns (
        uint256 tokenId,
        uint64 tokenListUSDPrice,
        uint64 tokenListMinUSDPrice,
        uint256 tokenCurrentUSDPrice,
        uint256 tokenCurrentETHPrice
    ) {
        tokenId = _tokenId;
        tokenListUSDPrice = tokenInfo[_tokenId].usdMax;
        tokenListMinUSDPrice = tokenInfo[_tokenId].usdMin;
        tokenCurrentUSDPrice = getTokenUSDPrice(_tokenId);
        tokenCurrentETHPrice = getTokenETHPrice(_tokenId);
        return (tokenId, tokenListUSDPrice, tokenListMinUSDPrice, tokenCurrentUSDPrice, tokenCurrentETHPrice);
    }

    /**
     * Returns the token price in USDC integer format.
     * The front-end can display this result as-is.
     */
    function getTokenUSDPrice(uint256 _tokenId) internal view
    tokenExists(_tokenId)
    returns (uint256 tokenUSDPrice) {
        uint256 dt = block.timestamp - tokenInfo[_tokenId].listTimeStamp;
        uint256 adjuster = (31536000 - dt + 86400) * 50 / 31536000 + 50;
        tokenUSDPrice = tokenInfo[_tokenId].usdMax * adjuster / 100;
        // Constrain to bounds instead of reverting
        tokenUSDPrice = constrainPrice(
            tokenUSDPrice,
            tokenInfo[_tokenId].usdMin,
            tokenInfo[_tokenId].usdMax
        );
    }

    /**
     * Returns the token price in ETH wei integer format.
     * The front-end will need to convert this into ETH decimal format.
     */
    function getTokenETHPrice(uint256 _tokenId) internal view
    tokenExists(_tokenId)
    returns (uint256 tokenETHPrice) {
        uint256 tokenUSDPrice = getTokenUSDPrice(_tokenId)*10**18;
        uint256 etherPriceUSD = getLatestETHPrice()*10**10;
        tokenETHPrice = (tokenUSDPrice*10**18)/etherPriceUSD; //wei
    }

    /**
     * Add the token to the available list with lower and upper 
     * bound prices in both USDC and ETH.
     */
    function listToken(address _contractAddress, address _minterAddress, uint256 _tokenId, uint64[2] calldata _usdcRange) external
    onlyOwner
    validPriceRange(_usdcRange) {
        require(!listedTokens[_tokenId], "Token already listed.");

        address tokenOwner = IERC721(_contractAddress).ownerOf(_tokenId);
        require(tokenOwner != address(0), "Token does not exist in NFT contract.");
        require(tokenOwner == _minterAddress, "Token owner not minter.");

        tokenInfo[_tokenId] = TokenInfo(
            _usdcRange[0], _usdcRange[1],
            uint128(block.timestamp)
        );
        listedTokens[_tokenId] = true;
    }

    /**
     * Function that handles purchase. Amount in ETH is calculated, 
     * user must send and then token is sent to user.
     * The token's contract address must have this address approved 
     * to make token transfers from it.
     */
    function purchaseToken(address _buyerAddress, address _contractAddress, uint256 _tokenId) external payable
    tokenExists(_tokenId)
    nonReentrant {
        uint256 ethPrice = getTokenETHPrice(_tokenId);
        require(ethPrice > minEthPrice, "ETH price too low, contact Collect9 admin for minEthPrice adjustment.");
        require(msg.value == ethPrice, "Incorrect amount of ETH.");
        (bool success,) = Owner.call{value: msg.value}(""); //This goes to the address holding the NFT
        require(success, "Failed to send ETH.");
        delete listedTokens[_tokenId];
        delete tokenInfo[_tokenId];
        IERC721(_contractAddress).safeTransferFrom(_buyerAddress, msg.sender, _tokenId);
        emit TokenBought(msg.sender, _buyerAddress, _tokenId, msg.value);
    }

    /**
     * Removes token from list of available tokens.
     */
    function removeListing(uint256 _tokenId) public
    onlyOwner
    tokenExists(_tokenId) {
        delete listedTokens[_tokenId];
        delete tokenInfo[_tokenId];
    }

    /**
     * Implemented in case the price feed address changes in the future.
     */
    function setPriceFeed(address _address) public
    onlyOwner {
        priceFeed = AggregatorV3Interface(_address);
    }

    /**
     * Allows minEthPrice to be updated if ETH price changes
     * in the future relative to contract deployment.
     * Manual is safest.
     */
    function updateMinEthPrice(uint256 _newMinEthPrice) external
    onlyOwner {
        minEthPrice = _newMinEthPrice;
    }

    /**
     * Update the bound prices for a listed token.
     */
    function updateToken(uint256 _tokenId, uint64[2] calldata _usdcRange) external
    onlyOwner
    tokenExists(_tokenId)
    validPriceRange(_usdcRange) {
        tokenInfo[_tokenId] = TokenInfo(
            _usdcRange[0], _usdcRange[1],
            uint128(block.timestamp)
        );
    }
}
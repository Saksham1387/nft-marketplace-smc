// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";


contract NFTMarketplace is ERC721URIStorage, ReentrancyGuard, AccessControl {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    
    // Roles for granular access control
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // Configurable fee constants with upper limits
    uint256 private constant MAX_ARTIST_FEE = 30; 
    uint256 private constant MAX_PLATFORM_FEE = 15; 
    uint256 private _artistFee;
    uint256 private _platformFee;
    address private _platformAddress;
    uint256[] private listedNFTitems;

    struct NFTItem {
        uint256 tokenId;      
        address payable artist; 
        uint256 price;       
        bool isForSale;       
    }
    
    mapping(uint256 => NFTItem) public nftItems;
    mapping(address => uint256) public pendingWithdrawals;

    // Enhanced events with more details
    event NFTMinted(uint256 tokenId, address indexed artist, uint256 price, string tokenURI);
    event NFTListed(uint256 indexed tokenId, uint256 price, address indexed seller);
    event NFTSold(uint256 indexed tokenId, address indexed from, address indexed to, uint256 price);
    event FeesUpdated(uint256 artistFee, uint256 platformFee);
    event Withdrawal(address indexed recipient, uint256 amount);

    constructor() ERC721("NFTMarketplace", "ENHM") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        _platformAddress = msg.sender;
        // Set initial fees with reasonable defaults
        _artistFee = 20;
        _platformFee = 10;
    }

    // Error handling with custom errors
    error InsufficientPayment(uint256 required, uint256 sent);
    error InvalidFeePercentage(uint256 fee);
    error NotOwner(address sender, address owner);
    error NFTNotForSale(uint256 tokenId);

    function mintNFT(
        string memory tokenURI, 
        uint256 price
    ) public onlyRole(MINTER_ROLE) returns (uint256) {
        // Input validation
        if (price == 0) revert("Price must be greater than 0");

        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();
    
        _safeMint(msg.sender, newTokenId);
        _setTokenURI(newTokenId, tokenURI);
        
        nftItems[newTokenId] = NFTItem({
            tokenId: newTokenId,
            artist: payable(msg.sender),
            price: price,
            isForSale: true
        });
        
        emit NFTMinted(newTokenId, msg.sender, price, tokenURI);
        return newTokenId;
    }
   
    function listNFT(uint256 tokenId, uint256 price) public {
        if (ownerOf(tokenId) != msg.sender) 
            // revert with the custom error
            revert NotOwner(msg.sender, ownerOf(tokenId));
        nftItems[tokenId].price = price;
        nftItems[tokenId].isForSale = true;

        // check if already listed
        bool alreadylisted = false;
        for (uint256 i=0; i < listedNFTitems.length; i++){
            if (listedNFTitems[i] == tokenId) {
                alreadylisted = true;
                break;
            }
        }

        // if not present then push to the list
         if (!alreadylisted) {
            listedNFTitems.push(tokenId);
        }
        
        emit NFTListed(tokenId, price, msg.sender);
    }

    function getListedNFT() public view returns (NFTItem[] memory){
        uint256 listedCount = listedNFTitems.length;
        NFTItem[] memory itemsForSale = new NFTItem[](listedCount);
        for (uint256 i=0; i< listedCount; i++){
            uint256 tokenId = listedNFTitems[i];
            itemsForSale[i] = nftItems[tokenId];
        }
        return itemsForSale;
    }

    function setPlatformAddress(address newPlatformAddress) public onlyRole(ADMIN_ROLE) {
        require(newPlatformAddress != address(0), "Invalid address");
        _platformAddress = newPlatformAddress;
    }

    function buyNFT(uint256 tokenId) public payable nonReentrant {
        NFTItem storage nft = nftItems[tokenId];
        
        if (!nft.isForSale) revert NFTNotForSale(tokenId);
        if (msg.value < nft.price) 
            revert InsufficientPayment(nft.price, msg.value);
        
        address payable seller = payable(ownerOf(tokenId));
        address payable artist = nft.artist;
        address payable platform = payable(_platformAddress);
        
        uint256 artistFee = (msg.value * _artistFee) / 100;    
        uint256 platformFee = (msg.value * _platformFee) / 100; 
        uint256 sellerAmount = msg.value - artistFee - platformFee;
        
        // Use withdrawal pattern instead of direct transfer
        pendingWithdrawals[artist] += artistFee;
        pendingWithdrawals[platform] += platformFee;
        pendingWithdrawals[seller] += sellerAmount;
        
        _transfer(seller, msg.sender, tokenId);
        nft.isForSale = false;
        
        for (uint256 i = 0; i < listedNFTitems.length; i++) {
            if (listedNFTitems[i] == tokenId) {
                listedNFTitems[i] = listedNFTitems[listedNFTitems.length - 1];
                listedNFTitems.pop();
                break;
            }
        }

        emit NFTSold(tokenId, seller, msg.sender, msg.value);
    }

    // Withdrawal pattern for safer fund distribution
    function withdraw() public {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No funds to withdraw");
        
        pendingWithdrawals[msg.sender] = 0;
        payable(msg.sender).transfer(amount);
        
        emit Withdrawal(msg.sender, amount);
    }
    
    // Granular fee management with access controls to change the fees for artist and the platform
    function setFees(
        uint256 artistFee, 
        uint256 platformFee
    ) public onlyRole(ADMIN_ROLE) {
        if (artistFee > MAX_ARTIST_FEE || platformFee > MAX_PLATFORM_FEE)
            revert InvalidFeePercentage(artistFee);
        
        _artistFee = artistFee;
        _platformFee = platformFee;
        
        emit FeesUpdated(artistFee, platformFee);
    }

    // Additional utility functions to check the current artis and platform fees
    function getCurrentFees() public view returns (uint256, uint256) {
        return (_artistFee, _platformFee);
    }

    // Override supportsInterface for AccessControl
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(ERC721URIStorage, AccessControl) 
        returns (bool) 
    {
        return 
            ERC721.supportsInterface(interfaceId) ||
            AccessControl.supportsInterface(interfaceId);
    }
}
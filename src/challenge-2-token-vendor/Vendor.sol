pragma solidity 0.8.20; //Do not change the solidity version as it negatively impacts submission grading
// SPDX-License-Identifier: MIT

//import "hardhat/console.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./YourToken.sol";

contract Vendor is Ownable {
    /////////////////
    /// Errors //////
    /////////////////

    error InvalidEthAmount();
    error InsufficientVendorTokenBalance(uint256 available, uint256 required);
    error EthTransferFailed(address to, uint256 amount);
    error InvalidTokenAmount();
    error InsufficientVendorEthBalance(uint256 available, uint256 required);

    //////////////////////
    /// State Variables //
    //////////////////////

    YourToken public immutable yourToken;
    uint256 public constant tokensPerEth = 100; // 100 tokens per 1 ETH

    ////////////////
    /// Events /////
    ////////////////

    event BuyTokens(address indexed buyer, uint256 amountOfEth, uint256 amountOfTokens);
    event SellTokens(address indexed seller, uint256 amountOfTokens, uint256 amountOfEth);

    ///////////////////
    /// Constructor ///
    ///////////////////

    constructor(address tokenAddress) Ownable(msg.sender) {
        yourToken = YourToken(tokenAddress);
    }

    ///////////////////
    /// Functions /////
    ///////////////////

    function buyTokens() external payable {
        if (msg.value == uint256(0)) {
            revert InvalidEthAmount();
        }
        uint256 tokensToBuy = msg.value * tokensPerEth;
        uint256 vendorTokenBalance = yourToken.balanceOf(address(this));
        if (tokensToBuy > vendorTokenBalance) {
            revert InsufficientVendorTokenBalance(vendorTokenBalance, tokensToBuy);
        }
        yourToken.transfer(msg.sender, tokensToBuy);
        emit BuyTokens(msg.sender, msg.value, tokensToBuy);
    }

    function withdraw() public onlyOwner {
        uint256 vendorBalance = address(this).balance;
        address owner = owner();
        (bool success, ) = owner.call{ value: vendorBalance }("");
        if (!success) {
            revert EthTransferFailed(owner, vendorBalance);
        }
    }

    function sellTokens(uint256 amount) public {
        if (amount == 0) {
            revert InvalidTokenAmount();
        }
        yourToken.transferFrom(msg.sender, address(this), amount);
        uint256 userEthAmount = amount / tokensPerEth;
        console.log("userEthAmount ", userEthAmount);
        uint256 vendorEthBalance = address(this).balance;
        if (vendorEthBalance < userEthAmount) {
            revert InsufficientVendorEthBalance(vendorEthBalance, userEthAmount);
        }
        (bool success, ) = msg.sender.call{ value: userEthAmount }("");
        if (!success) {
            revert EthTransferFailed(msg.sender, userEthAmount);
        }
        emit SellTokens(msg.sender, amount, userEthAmount);
    }
}

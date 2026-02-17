// SPDX-License-Identifier: MIT
pragma solidity 0.8.20; // Do not change the solidity version as it negatively impacts submission grading

//import "hardhat/console.sol";
import "./FundingRecipient.sol";

contract CrowdFund {
    /////////////////
    /// Errors //////
    /////////////////

    error NotOpenToWithdraw();
    error WithdrawTransferFailed(address to, uint256 amount);
    error TooEarly(uint256 deadline, uint256 currentTimestamp);
    error Completed();

    //////////////////////
    /// State Variables //
    //////////////////////

    FundingRecipient public fundingRecipient;
    mapping(address => uint256) public balances;
    bool public openToWithdraw;
    uint256 public deadline = block.timestamp + 2 hours;
    uint256 public constant threshold = 1 ether;

    ////////////////
    /// Events /////
    ////////////////

    event Contribution(address, uint256);

    ///////////////////
    /// Modifiers /////
    ///////////////////

    modifier notCompleted() {
        if (fundingRecipient.completed()) {
            revert Completed();
        }
        _;
    }

    ///////////////////
    /// Constructor ///
    ///////////////////

    constructor(address fundingRecipientAddress) {
        fundingRecipient = FundingRecipient(fundingRecipientAddress);
    }

    ///////////////////
    /// Functions /////
    ///////////////////

    function contribute() public payable notCompleted {
        balances[msg.sender] += msg.value;
        emit Contribution(msg.sender, msg.value);
    }

    function withdraw() public notCompleted {
        if (!openToWithdraw) {
            revert NotOpenToWithdraw();
        }
        uint256 userBalance = balances[msg.sender];

        balances[msg.sender] = 0;
        (bool success, ) = msg.sender.call{ value: userBalance }("");
        if (!success) {
            revert WithdrawTransferFailed(msg.sender, userBalance);
        }
    }

    function execute() public notCompleted {
        if (block.timestamp <= deadline) {
            revert TooEarly(deadline, block.timestamp);
        }
        uint256 balance = address(this).balance;
        if (balance >= threshold) {
            fundingRecipient.complete{ value: balance }();
        } else {
            openToWithdraw = true;
        }
    }

    receive() external payable {
        contribute();
    }

    ////////////////////////
    /// View Functions /////
    ////////////////////////

    function timeLeft() public view returns (uint256) {
        if (block.timestamp < deadline) {
            return deadline - block.timestamp;
        }
        return 0;
    }
}

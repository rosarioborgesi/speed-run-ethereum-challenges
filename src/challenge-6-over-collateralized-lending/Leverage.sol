// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Lending } from "./Lending.sol";
import { CornDEX } from "./CornDEX.sol";
import { Corn } from "./Corn.sol";

error Leverage__NoBalanceToWithdraw();
error Leverage__FailedToSendEther();
error Leverage__maxWithDrawableNotEqualToBalance();

/**
 * @notice For Side quest only
 * @notice This contract is used to leverage a user's position by borrowing CORN from the Lending contract
 * then borrowing more CORN from the DEX to repay the initial borrow then repeating until the user has borrowed as much as they want
 */
contract Leverage {
    Lending i_lending;
    CornDEX i_cornDEX;
    Corn i_corn;
    address public owner;

    event LeveragedPositionOpened(address user, uint256 loops);
    event LeveragedPositionClosed(address user, uint256 loops);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only the owner can call this function");
        _;
    }

    constructor(address _lending, address _cornDEX, address _corn) {
        i_lending = Lending(_lending);
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        // Approve DEX and Lending to spend the user's CORN
        i_corn.approve(address(i_cornDEX), type(uint256).max);
        i_corn.approve(address(i_lending), type(uint256).max);
    }

    /**
     * @notice Claim ownership of the contract so that no one else can change your position or withdraw your funds
     */
    function claimOwnership() public {
        owner = msg.sender;
    }

    /**
     * @notice Opens a leveraged ETH position using a recursive borrowing strategy.
     *
     * @dev This function implements the classic “looping leverage” pattern:
     *      borrow CORN → swap CORN for ETH → deposit ETH as collateral → borrow more CORN,
     *      repeating the process until the position can no longer be safely extended.
     *
     *      The strategy works as follows:
     *      1. Deposit all available ETH as collateral into the Lending contract
     *      2. Borrow the maximum amount of CORN allowed by the collateral ratio
     *      3. Swap the borrowed CORN for ETH via the DEX
     *      4. Use the newly acquired ETH in the next iteration
     *
     *      The function is payable, so ETH must be sent when calling it.
     *      If called with zero ETH, `addCollateral` is expected to revert or
     *      the loop will exit immediately without creating leverage.
     *
     * @param reserve Minimum amount of ETH to keep unutilized per iteration.
     *        Once the available ETH balance is less than or equal to this value,
     *        the loop terminates to avoid unsafe or inefficient iterations.
     */
    function openLeveragedPosition(uint256 reserve) public payable onlyOwner {
        uint256 loops = 0;

        while (true) {
            // 1) Read the current ETH balance held by this contract
            uint256 balance = address(this).balance;

            // 2) Deposit the entire ETH balance as collateral into the Lending contract
            i_lending.addCollateral{ value: balance }();

            // 3) Stop if the remaining ETH balance is too small to safely continue
            if (balance <= reserve) {
                break;
            }

            // 4) Compute the maximum CORN amount that can be borrowed
            //    while respecting the required collateral ratio
            uint256 maxBorrowAmount = i_lending.getMaxBorrowAmount(balance);

            // 5) Borrow CORN against the newly deposited collateral
            i_lending.borrowCorn(maxBorrowAmount);

            // 6) Swap the borrowed CORN for ETH on the DEX
            //    The resulting ETH becomes the input for the next loop iteration
            i_cornDEX.swap(maxBorrowAmount);

            loops++;
        }

        // Emit the number of leverage iterations performed
        emit LeveragedPositionOpened(msg.sender, loops);
    }

    /**
     * @notice Closes a leveraged ETH position by iteratively unwinding the leverage loop.
     *
     * @dev This function performs the inverse operation of `openLeveragedPosition`.
     *      It repeatedly:
     *        1. Withdraws the maximum amount of ETH collateral that can be safely removed
     *        2. Swaps the withdrawn ETH for CORN on the DEX
     *        3. Uses the CORN to repay outstanding debt
     *
     *      This process continues until the debt is fully repaid. Any remaining
     *      CORN is finally swapped back to ETH so the position ends with no CORN exposure.
     *
     *      When the leveraged position was opened, the contract ended up with:
     *        - A large amount of ETH locked as collateral
     *        - An outstanding CORN debt
     *
     *      Repaying debt increases the amount of collateral that can be safely withdrawn,
     *      which is why the process must be performed iteratively.
     */
    function closeLeveragedPosition() public onlyOwner {
        uint256 loops = 0;

        while (true) {
            /**
             * 1) Compute the maximum amount of ETH collateral that can be safely withdrawn
             *    without violating the minimum collateralization ratio.
             */
            uint256 maxWithdrawable = i_lending.getMaxWithdrawableCollateral(address(this));

            /**
             * 2) Withdraw the maximum safe amount of ETH collateral.
             */
            i_lending.withdrawCollateral(maxWithdrawable);

            /**
             * 3) Sanity check: ensure the withdrawn ETH matches the expected amount.
             *    This assumes the contract held no ETH prior to the withdrawal.
             */
            if (maxWithdrawable != address(this).balance) {
                revert Leverage__maxWithDrawableNotEqualToBalance();
            }

            /**
             * 4) Swap the withdrawn ETH for CORN on the DEX.
             *    The acquired CORN will be used to repay debt.
             */
            i_cornDEX.swap{ value: maxWithdrawable }(maxWithdrawable);

            /**
             * 5) Determine how much CORN can be repaid in this iteration.
             *    This is the minimum of:
             *      - the contract's CORN balance
             *      - the remaining outstanding debt
             */
            uint256 cornBalance = i_corn.balanceOf(address(this));
            uint256 remainingDebt = i_lending.s_userBorrowed(address(this));
            uint256 amountToRepay = cornBalance > remainingDebt ? remainingDebt : cornBalance;

            /**
             * 6) Repay the debt if possible.
             *    Repaying reduces outstanding debt, allowing more collateral
             *    to be withdrawn in the next iteration.
             */
            if (amountToRepay > 0) {
                i_lending.repayCorn(amountToRepay);
            } else {
                /**
                 * 7) No debt remains to be repaid.
                 *    Any leftover CORN represents unwanted exposure and is
                 *    swapped back to ETH before exiting.
                 */
                i_cornDEX.swap(i_corn.balanceOf(address(this)));
                break;
            }

            loops++;
        }

        // Emit the total number of unwind iterations performed
        emit LeveragedPositionClosed(msg.sender, loops);
    }

    /**
     * @notice Withdraw the ETH from the contract
     */
    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        if (balance <= 0) {
            revert Leverage__NoBalanceToWithdraw();
        }

        (bool success, ) = payable(msg.sender).call{ value: balance }("");
        if (!success) {
            revert Leverage__FailedToSendEther();
        }
    }

    receive() external payable {}
}

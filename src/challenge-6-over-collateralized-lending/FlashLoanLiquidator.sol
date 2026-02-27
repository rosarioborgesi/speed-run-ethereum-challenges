// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { IFlashLoanRecipient, Lending } from "./Lending.sol";
import { Corn } from "./Corn.sol";
import { CornDEX } from "./CornDEX.sol";

error FlashLoanLiquidator__FailedTransfer();

/**
 * @notice Side-quest helper contract.
 *
 * @notice This contract performs liquidations of unsafe positions using a flash loan.
 *         It borrows CORN via a flash loan, liquidates an undercollateralized position,
 *         receives ETH collateral, swaps part of that ETH back to CORN, and repays
 *         the flash loan within the same transaction.
 */
contract FlashLoanLiquidator is IFlashLoanRecipient {
    Corn private i_corn;
    CornDEX private i_cornDEX;
    Lending private i_lending;

    constructor(address _lending, address _cornDEX, address _corn) {
        i_corn = Corn(_corn);
        i_cornDEX = CornDEX(_cornDEX);
        i_lending = Lending(_lending);

        // Allow the Lending contract to pull CORN from this contract
        // when repaying debt during liquidation
        i_corn.approve(address(i_lending), type(uint256).max);
    }

    /**
     * @notice Executes the flash-loan logic.
     *
     * @dev This function is called by the Lending contract after CORN has been
     *      transferred to this contract as part of a flash loan.
     *
     *      The flow is:
     *      1. Use flash-loaned CORN to liquidate an unsafe position
     *      2. Receive ETH collateral from the Lending contract
     *      3. Swap part of the ETH into CORN
     *      4. Repay the flash loan
     *      5. Send any remaining ETH as profit to the initiator
     *
     * @param amount The amount of CORN borrowed via the flash loan.
     * @param initiator The original caller of the flash loan.
     * @param extraParam The address of the borrower to liquidate.
     */
    function executeOperation(uint256 amount, address initiator, address extraParam) external override returns (bool) {
        /**
         * Step 1: Liquidate the unsafe position.
         *
         * - This contract uses the flash-loaned CORN to repay the borrower's debt
         * - CORN is transferred from this contract to the Lending contract
         * - The borrower's debt is cleared
         * - ETH collateral is transferred to this contract
         *
         * After this call, this contract holds ETH collateral.
         */
        i_lending.liquidate(extraParam);

        /**
         * Step 2: Read current AMM reserves.
         *
         * These values are required to compute the exact amount of ETH
         * needed to swap for CORN.
         */
        uint256 ethReserves = address(i_cornDEX).balance;
        uint256 tokenReserves = i_corn.balanceOf(address(i_cornDEX));

        /**
         * Step 3: Compute the exact ETH input required to receive `amount` CORN.
         *
         * This ensures the swap produces exactly enough CORN
         * to repay the flash loan.
         */
        uint256 requiredETHInput = i_cornDEX.calculateXInput(amount, ethReserves, tokenReserves);

        /**
         * Step 4: Swap ETH for CORN.
         *
         * A portion of the ETH collateral is exchanged for CORN,
         * giving this contract the exact amount needed to repay the flash loan.
         */
        i_cornDEX.swap{ value: requiredETHInput }(requiredETHInput);

        /**
         * Step 5: Send remaining ETH as profit.
         *
         * Any ETH left after repaying the flash loan and paying swap costs
         * represents liquidation profit and is sent to the initiator.
         */
        if (address(this).balance > 0) {
            (bool success, ) = payable(initiator).call{ value: address(this).balance }("");
            if (!success) {
                revert FlashLoanLiquidator__FailedTransfer();
            }
        }

        /**
         * Step 6: Return success.
         *
         * If any step above fails (liquidation, swap, or repayment),
         * the entire transaction reverts, preserving atomicity.
         */
        return true;
    }

    /**
     * @notice Allows this contract to receive ETH collateral.
     */
    receive() external payable {}
}

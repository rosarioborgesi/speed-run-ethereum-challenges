// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Corn.sol";
import "./CornDEX.sol";

error Lending__InvalidAmount();
error Lending__TransferFailed();
error Lending__UnsafePositionRatio();
error Lending__BorrowingFailed();
error Lending__RepayingFailed();
error Lending__PositionSafe();
error Lending__NotLiquidatable();
error Lending__InsufficientLiquidatorCorn();
error Lending__InsufficientAllowance();
error Lending__LiquidationFailed();
error Lending__FlashloanFailed();
error Lending__FlashloanExecuteOperationFailed();

contract Lending is Ownable {
    uint256 private constant COLLATERAL_RATIO = 120; // 120% collateralization required
    uint256 private constant LIQUIDATOR_REWARD = 10; // 10% reward for liquidators

    Corn private i_corn;
    CornDEX private i_cornDEX;

    mapping(address => uint256) public s_userCollateral; // User's collateral balance
    mapping(address => uint256) public s_userBorrowed; // User's borrowed corn balance

    event CollateralAdded(address indexed user, uint256 indexed amount, uint256 price);
    event CollateralWithdrawn(address indexed user, uint256 indexed amount, uint256 price);
    event AssetBorrowed(address indexed user, uint256 indexed amount, uint256 price);
    event AssetRepaid(address indexed user, uint256 indexed amount, uint256 price);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 amountForLiquidator,
        uint256 liquidatedUserDebt,
        uint256 price
    );

    constructor(address _cornDEX, address _corn) Ownable(msg.sender) {
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        i_corn.approve(address(this), type(uint256).max);
    }

    /**
     * @notice Allows users to add collateral to their account
     */
    function addCollateral() public payable {
        if (msg.value == 0) {
            revert Lending__InvalidAmount();
        }
        s_userCollateral[msg.sender] += msg.value;
        emit CollateralAdded(msg.sender, msg.value, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to withdraw collateral as long as it doesn't make them liquidatable
     * @param amount The amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) public {
        if (amount == 0) {
            revert Lending__InvalidAmount();
        }

        uint256 userCollateral = s_userCollateral[msg.sender];
        if (amount > userCollateral) {
            revert Lending__InvalidAmount();
        }

        s_userCollateral[msg.sender] -= amount;
        // Ensure the withdrawal does not make the position undercollateralized (below the minimum collateral ratio)
        if (s_userBorrowed[msg.sender] > 0) {
            _validatePosition(msg.sender);
        }

        (bool success, ) = payable(msg.sender).call{ value: amount }("");
        if (!success) {
            revert Lending__TransferFailed();
        }
        emit CollateralWithdrawn(msg.sender, amount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Calculates the value of a user's deposited collateral expressed in CORN tokens
     * @dev
     * - The user's collateral is stored as an ETH amount in wei (1e18)
     * - `currentPrice()` returns the ETH price denominated in CORN, scaled by 1e18
     * - The result is the total collateral value denominated in CORN (1e18 decimals)
     *
     * @param user The address of the user to calculate the collateral value for
     * @return uint256 The total collateral value denominated in CORN (1e18 decimals)
     */
    function calculateCollateralValue(address user) public view returns (uint256) {
        uint256 userCollateral = s_userCollateral[user];
        return (userCollateral * i_cornDEX.currentPrice()) / 1e18; // 1e18 represents CORN decimals
    }

    /**
     * @notice Calculates the collateralization (position) ratio of a user.
     * @dev The ratio is returned as a fixed-point number scaled by 1e18 to preserve precision.
     *      positionRatio = (collateralValue / borrowedAmount) * 1e18
     *
     *      Example:
     *      - If the collateral ratio is 133% (i.e. 1.33),
     *        this function returns:
     *        1.33 * 1e18 = 1330000000000000000
     *
     *      If the user has no outstanding debt (borrowedAmount == 0),
     *      the function returns type(uint256).max to represent an infinite ratio.
     *
     * @param user The address of the user whose position ratio is being calculated.
     * @return positionRatio The collateralization ratio scaled by 1e18.
     */
    function _calculatePositionRatio(address user) internal view returns (uint256) {
        // Collateral value denominated in CORN
        uint256 collateralValue = calculateCollateralValue(user);
        // This is the amount of CORN the user has borrowed
        uint256 borrowedAmount = s_userBorrowed[user];

        if (borrowedAmount == 0) {
            // Infinite ratio when no debt exists
            return type(uint256).max;
        }

        return (collateralValue * 1e18) / borrowedAmount;
    }

    /**
     * @notice Checks if a user's position can be liquidated
     * @param user The address of the user to check
     * @return bool True if the position is liquidatable, false otherwise
     */
    function isLiquidatable(address user) public view returns (bool) {
        uint256 positionRatio = _calculatePositionRatio(user);
        // positionRation must be multiplied to 100 to convert it to percentage so that we can compare it with COLLATERAL_RATIO
        return (positionRatio * 100) < COLLATERAL_RATIO * 1e18;
    }

    /**
     * @notice Internal view method that reverts if a user's position is unsafe
     * @param user The address of the user to validate
     */
    function _validatePosition(address user) internal view {
        if (isLiquidatable(user)) {
            revert Lending__UnsafePositionRatio();
        }
    }

    /**
     * @notice Allows users to borrow CORN based on their deposited collateral.
     *
     * Since a 120% overcollateralization is required, the maximum borrowable amount is:
     *   maxBorrow = collateralValue * 100 / 120
     *
     * Example:
     * - If a user deposits 0.1 ETH, the collateral value calculated via
     *   `calculateCollateralValue` is:
     *     99.9999000000999999 CORN (18 decimals)
     *
     * - The maximum amount that can be borrowed is therefore:
     *     99999900000099999900 * 100 / 120
     *     = 83333250000083333250 ≈ 83.33 CORN
     *
     * - If the user attempts to borrow:
     *     83333250000083333251 (1 wei more than the maximum),
     *   the transaction will revert.
     *
     * @param borrowAmount The amount of CORN to borrow (18 decimals).
     */
    function borrowCorn(uint256 borrowAmount) public {
        if (borrowAmount == 0) {
            revert Lending__InvalidAmount();
        }

        s_userBorrowed[msg.sender] += borrowAmount;
        _validatePosition(msg.sender);

        bool success = i_corn.transfer(msg.sender, borrowAmount);
        if (!success) {
            revert Lending__BorrowingFailed();
        }
        emit AssetBorrowed(msg.sender, borrowAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to repay corn and reduce their debt
     * @param repayAmount The amount of corn to repay
     */
    function repayCorn(uint256 repayAmount) public {
        if (repayAmount == 0 || s_userBorrowed[msg.sender] < repayAmount) {
            revert Lending__InvalidAmount();
        }
        s_userBorrowed[msg.sender] -= repayAmount;

        uint256 allowance = i_corn.allowance(msg.sender, address(this));
        if (repayAmount > allowance) {
            revert Lending__InsufficientAllowance();
        }

        bool success = i_corn.transferFrom(msg.sender, address(this), repayAmount);
        if (!success) {
            revert Lending__RepayingFailed();
        }
        emit AssetRepaid(msg.sender, repayAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows a third party (liquidator) to liquidate an unsafe borrowing position.
     *
     * @dev A position is liquidatable when its collateralization ratio falls
     *      below the minimum required threshold.
     *
     * @dev The liquidator repays the user's debt in CORN and receives
     *      a portion of the user's ETH collateral (plus a liquidation reward).
     *
     * @dev Requirements for the liquidator:
     *      - Must hold enough CORN to fully repay the user's outstanding debt
     *      - Must have approved this contract to transfer the required CORN amount
     *
     * @param user The address of the user whose position is being liquidated.
     */
    function liquidate(address user) public {
        // Revert if the user's position is still safe
        if (!isLiquidatable(user)) {
            revert Lending__NotLiquidatable();
        }
        // Total outstanding debt of the user, denominated in CORN (18 decimals)
        uint256 userDebt = s_userBorrowed[user];

        // Ensure the liquidator owns enough CORN to repay the user's full debt
        if (i_corn.balanceOf(msg.sender) < userDebt) {
            revert Lending__InsufficientLiquidatorCorn();
        }
        // Ensure this contract is approved to transfer the CORN needed for liquidation
        uint256 allowance = i_corn.allowance(msg.sender, address(this));
        if (userDebt > allowance) {
            revert Lending__InsufficientAllowance();
        }

        // Transfer CORN from the liquidator to this contract to repay the user's debt
        bool success = i_corn.transferFrom(msg.sender, address(this), userDebt);
        if (!success) {
            revert Lending__LiquidationFailed();
        }

        // Clear the user's outstanding debt after successful repayment
        s_userBorrowed[user] = 0;

        // User's deposited ETH collateral (denominated in wei)
        uint256 userCollateral = s_userCollateral[user];
        // Current value of the user's collateral expressed in CORN (18 decimals)
        uint256 collateralValue = calculateCollateralValue(user);

        /**
         * Calculate how much ETH collateral corresponds to the repaid CORN debt.
         *
         * Formula:
         *   collateralPurchased = (userDebt / collateralValue) * userCollateral
         *
         * Units:
         *   userDebt         -> CORN (18 decimals)
         *   collateralValue  -> CORN (18 decimals)
         *   userCollateral   -> ETH (wei)
         *
         * Result:
         *   collateralPurchased -> ETH (wei)
         */
        uint256 collateralPurchased = (userDebt /* CORN */ * userCollateral /* ETH */) / collateralValue /* CORN */;

        // Additional ETH reward paid to the liquidator as an incentive (percentage-based)
        uint256 liquidatorReward = (collateralPurchased * LIQUIDATOR_REWARD) / 100;
        // Total ETH sent to the liquidator (collateral + reward)
        uint256 amountForLiquidator = collateralPurchased + liquidatorReward;
        // Cap the payout to the user's remaining collateral to prevent over-withdrawal
        amountForLiquidator = amountForLiquidator > userCollateral ? userCollateral : amountForLiquidator; // Ensure we don't exceed user's collateral
        // Reduce the user's collateral by the amount paid to the liquidator
        s_userCollateral[user] -= amountForLiquidator;
        // Transfer ETH collateral to the liquidator
        (bool sent, ) = payable(msg.sender).call{ value: amountForLiquidator }("");
        if (!sent) {
            revert Lending__TransferFailed();
        }
        // Emit liquidation event with price reference used during liquidation
        emit Liquidation(user, msg.sender, amountForLiquidator, userDebt, i_cornDEX.currentPrice());
    }
    /**
     * @notice Issues a flash loan of CORN that must be repaid within the same transaction.
     *
     * @dev No collateral is required because the borrowed amount must be returned
     *      before the transaction completes. If any step fails, the entire transaction
     *      reverts and no CORN is permanently transferred.
     *
     * @dev The recipient MUST be a contract implementing the `IFlashLoanRecipient`
     *      interface. EOAs are not supported.
     *
     * @param _recipient The contract receiving the flash-loaned CORN.
     * @param _amount The amount of CORN to flash-loan (18 decimals).
     * @param _extraParam The address of the borrower to liquidate.
     */
    function flashLoan(IFlashLoanRecipient _recipient, uint256 _amount, address _extraParam) public {
        // Transfer CORN to the recipient contract
        // No collateral is needed since repayment happens within the same transaction
        bool sentToRecipient = i_corn.transfer(address(_recipient), _amount);
        if (!sentToRecipient) {
            revert Lending__FlashloanFailed();
        }

        // Execute the recipient's custom flash-loan logic
        // The recipient is expected to use the funds and prepare repayment
        bool executionSucceeded = _recipient.executeOperation(_amount, msg.sender, _extraParam);
        if (!executionSucceeded) {
            revert Lending__FlashloanExecuteOperationFailed();
        }

        // Pull the borrowed CORN back from the recipient
        // This will revert if the recipient did not approve or lacks sufficient balance
        bool repaid = i_corn.transferFrom(address(_recipient), address(this), _amount);
        if (!repaid) {
            revert Lending__FlashloanFailed();
        }
    }
    /**
     * @notice Computes the maximum amount of CORN that can be borrowed
     *         for a given amount of ETH collateral.
     *
     * @dev The ETH amount is first converted to its CORN value using the
     *      current price from the DEX. The result is then discounted by
     *      the required collateral ratio (e.g. 120%) to determine the
     *      maximum safe borrowable amount.
     *
     *      Formula:
     *        collateralValueInCORN = ethCollateralAmount * price / 1e18
     *        maxBorrow = collateralValueInCORN * 100 / COLLATERAL_RATIO
     *
     * @param ethCollateralAmount Amount of ETH provided as collateral (wei).
     * @return maxBorrow The maximum CORN amount that can be safely borrowed (18 decimals).
     */
    function getMaxBorrowAmount(uint256 ethCollateralAmount) public view returns (uint256) {
        if (ethCollateralAmount == 0) {
            return 0;
        }

        // Convert ETH collateral (wei) to its value in CORN (18 decimals)
        uint256 collateralValue = (ethCollateralAmount * i_cornDEX.currentPrice()) / 1e18;

        // Apply the collateralization constraint to compute the max borrowable CORN
        return (collateralValue * 100) / COLLATERAL_RATIO;
    }

    /**
     * @notice Returns the amount of ETH the account has deposited as collateral that is OK to withdrawn
     * Without putting the position in a liquidatable state.
     * @param user the address we want to query
     */
    function getMaxWithdrawableCollateral(address user) public view returns (uint256) {
        // How much CORN the user borrowed
        uint256 borrowedAmount = s_userBorrowed[user];
        // How much ETH they deposited
        uint256 userCollateral = s_userCollateral[user];
        // If the user borrowed nothing, withdraw 100% of ETH
        if (borrowedAmount == 0) {
            return userCollateral;
        }
        //Compute how much CORN this collateral could support at the collateral ratio
        // Given my current ETH collateral, what is the maximum CORN debt I’m allowed to have at the liquidation threshold?
        // This is a borrow limit, not a withdraw limit
        uint256 maxBorrowedAmount = getMaxBorrowAmount(userCollateral);
        // If you are already maxed out you can't withdraw anything
        if (borrowedAmount == maxBorrowedAmount) {
            return 0;
        }
        // Compute how much borrowing headroom you still have.
        //This is unused borrowing capacity measured in CORN
        // How much additional CORN could I still borrow before liquidation?
        uint256 potentialBorrowingAmount = maxBorrowedAmount - borrowedAmount;
        // Convert that CORN headroom into ETH value. We convert CORN to ETH using the current DEX price
        // This ETH value is the collateral REQUIRED to support that extra borrow, not collateral you are free to withdraw.
        uint256 ethValueOfPotentialBorrowingAmount = (potentialBorrowingAmount * 1e18) / i_cornDEX.currentPrice();
        // How much ETH can I remove while still respecting the collateral ratio?
        return (ethValueOfPotentialBorrowingAmount * COLLATERAL_RATIO) / 100;
    }
}

interface IFlashLoanRecipient {
    function executeOperation(uint256 amount, address initiator, address extraParam) external returns (bool);
}

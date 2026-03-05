// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./MyUSD.sol";
import "./Oracle.sol";
import "./MyUSDStaking.sol";

error Engine__InvalidAmount();
error Engine__UnsafePositionRatio();
error Engine__NotLiquidatable();
error Engine__InvalidBorrowRate();
error Engine__NotRateController();
error Engine__InsufficientCollateral();
error Engine__TransferFailed();

contract MyUSDEngine is Ownable {
    uint256 private constant COLLATERAL_RATIO = 150; // 150% collateralization required
    uint256 private constant LIQUIDATOR_REWARD = 10; // 10% reward for liquidators
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant PRECISION = 1e18;

    MyUSD private i_myUSD;
    Oracle private i_oracle;
    MyUSDStaking private i_staking;
    address private i_rateController;

    // Annual interest rate for borrowers in basis points (1% = 100)
    uint256 public borrowRate;

    /**
     * @notice Total number of debt shares in the system.
     * @dev Represents the sum of all user debt shares.
     *
     *      - Increases when users borrow (mint MyUSD)
     *      - Decreases when users repay
     *      - Does NOT change when interest accrues
     *
     *      Interest is applied by increasing `debtExchangeRate`,
     *      not by modifying shares.
     */
    uint256 public totalDebtShares;

    /**
     * @notice Exchange rate between debt shares and MyUSD (scaled by 1e18).
     * @dev Defines how much MyUSD one debt share represents.
     *
     *      User debt is calculated as:
     *          userDebt = userDebtShares * debtExchangeRate / 1e18
     *
     *      - Initialized to 1e18 (1 share = 1 MyUSD)
     *      - Increases over time as interest accrues
     *      - Updating this variable applies interest to all borrowers
     *
     *      Why it only increases:
     *      If total debt grows due to interest while shares remain constant,
     *      the exchange rate must increase to reflect the higher debt.
     *
     *      Example:
     *      - Yesterday total debt = 100 MyUSD
     *      - After interest total debt = 110 MyUSD
     *      - Since totalDebtShares is unchanged,
     *        `debtExchangeRate` increases so each share is worth more.
     */
    uint256 public debtExchangeRate;

    /**
     * @notice Timestamp of the last global interest accrual update.
     * @dev Used to calculate how much time has passed since interest
     *      was last applied to the system.
     *
     *      Interest is accrued lazily:
     *      - The exchange rate is only updated when needed
     *      - The elapsed time since this timestamp determines the
     *        amount of interest to apply
     */
    uint256 public lastUpdateTime;

    /**
     * @notice Amount of ETH collateral deposited by each user.
     * @dev Tracks the raw ETH value supplied as collateral.
     *
     *      - Used to determine borrowing power
     *      - Used in liquidation checks
     *      - Does NOT include price conversions (handled separately via oracle)
     */
    mapping(address => uint256) public s_userCollateral;

    /**
     * @notice Debt shares owned by each user.
     * @dev Represents a user's proportional share of the total system debt.
     *
     *      - Users do NOT store raw debt amounts
     *      - Debt is calculated dynamically using the exchange rate:
     *          userDebt = userDebtShares × debtExchangeRate
     *
     *      - Shares remain constant unless the user borrows or repays
     *      - Interest is applied globally by increasing `debtExchangeRate`
     */
    mapping(address => uint256) public s_userDebtShares;

    event CollateralAdded(address indexed user, uint256 indexed amount, uint256 price);
    event CollateralWithdrawn(address indexed withdrawer, uint256 indexed amount, uint256 price);
    event BorrowRateUpdated(uint256 newRate);
    event DebtSharesMinted(address indexed user, uint256 amount, uint256 shares);
    event DebtSharesBurned(address indexed user, uint256 amount, uint256 shares);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 amountForLiquidator,
        uint256 liquidatedUserDebt,
        uint256 price
    );

    modifier onlyRateController() {
        if (msg.sender != i_rateController) revert Engine__NotRateController();
        _;
    }

    constructor(
        address _oracle,
        address _myUSDAddress,
        address _stakingAddress,
        address _rateController
    ) Ownable(msg.sender) {
        i_oracle = Oracle(_oracle);
        i_myUSD = MyUSD(_myUSDAddress);
        i_staking = MyUSDStaking(_stakingAddress);
        i_rateController = _rateController;
        lastUpdateTime = block.timestamp;
        debtExchangeRate = PRECISION; // 1:1 initially
    }

    // Checkpoint 2: Depositing Collateral & Understanding Value
    /**
     * @notice Allows a user to deposit ETH as collateral into the system.
     */
    function addCollateral() public payable {
        if (msg.value == 0) {
            revert Engine__InvalidAmount();
        }
        s_userCollateral[msg.sender] += msg.value;
        emit CollateralAdded(msg.sender, msg.value, i_oracle.getETHMyUSDPrice());
    }

    /**
     * @notice Returns the MyUSD value of a user's deposited ETH collateral.
     * @dev Converts the user's raw ETH collateral (in wei) into MyUSD using
     *      the current ETH/MyUSD oracle price.
     *
     *      Formula:
     *          collateralValue = collateralAmount * ethPrice / PRECISION
     *
     *      Assumptions:
     *      - `ethPrice` is returned in MyUSD with `PRECISION` scaling (e.g. 1e18)
     *      - Result is denominated in MyUSD (scaled by PRECISION)
     *
     * @param user The address of the user to evaluate.
     * @return The value of the user's ETH collateral expressed in MyUSD.
     */
    function calculateCollateralValue(address user) public view returns (uint256) {
        // Get current ETH price in MyUSD (scaled by PRECISION)
        uint256 ethPrice = i_oracle.getETHMyUSDPrice();

        // Load the user's deposited ETH amount (in wei)
        uint256 collateralAmount = s_userCollateral[user];

        // Convert ETH amount to MyUSD value using the oracle price
        // (collateralAmount * ethPrice) / PRECISION keeps scaling consistent
        return (collateralAmount * ethPrice) / PRECISION;
    }

    // Checkpoint 3: Interest Calculation System
    /**
     * @notice Returns the up-to-date debt exchange rate, including any interest accrued since `lastUpdateTime`.
     * @dev This is a pure accounting helper for the share-based debt model. It does NOT write to storage.
     *
     *      In this system, user debt is tracked in shares and converted to MyUSD using an exchange rate:
     *          userDebtMyUSD = userDebtShares * debtExchangeRate / PRECISION
     *
     *      Interest accrues globally by increasing the exchange rate (MyUSD per share), not by updating users.
     *      This function "previews" what `debtExchangeRate` should be right now by:
     *      1) reconstructing total debt from shares
     *      2) computing simple interest over the elapsed time at `borrowRate`
     *      3) converting that interest into a per-share increase in the exchange rate
     *
     *      Use `_accrueInterest()` to persist the returned value to storage.
     *
     * @return The current debt exchange rate (MyUSD per share), scaled by `PRECISION`.
     */
    function _getCurrentExchangeRate() internal view returns (uint256) {
        // 1) No borrowers -> no interest to accrue.
        //    Also avoids division by zero later when we divide by `totalDebtShares`.
        if (totalDebtShares == 0) {
            return debtExchangeRate;
        }

        // 2) Compute how much time has passed since the last interest update.
        //    Interest depends on time: `timeElapsed` is the number of seconds since `lastUpdateTime`.
        uint256 timeElapsed = block.timestamp - lastUpdateTime;

        // 3) Early exits:
        //    - If no time passed (same block / same timestamp), interest is zero.
        //    - If `borrowRate` is zero, we charge 0% APR, so interest is zero.
        if (timeElapsed == 0 || borrowRate == 0) {
            return debtExchangeRate;
        }

        // 4) Reconstruct the current total system debt in MyUSD using the share model.
        //
        //    Each borrower holds debt shares.
        //    `debtExchangeRate` tells us how much MyUSD 1 share represents.
        //
        //    Formula (scaled):
        //      totalDebtValue = totalDebtShares * debtExchangeRate / PRECISION
        //
        //    Example:
        //      - totalDebtShares   = 100
        //      - debtExchangeRate  = 1.1e18
        //      - PRECISION         = 1e18
        //
        //      totalDebtValue = 100 * 1.1e18 / 1e18 = 110 MyUSD
        //      -> the system currently owes 110 MyUSD in total.
        uint256 totalDebtValue = (totalDebtShares * debtExchangeRate) / PRECISION;

        // 5) Compute simple interest accrued over `timeElapsed`.
        //
        //    Base formula:
        //      interest = principal * annualRate * (time / 1 year)
        //
        //    Integer math details:
        //      - `borrowRate` uses 2-decimal basis points:
        //          125   = 1.25% APR
        //          10000 = 100.00% APR
        //      - `timeElapsed / SECONDS_PER_YEAR` is the fraction of the year
        //
        //    Therefore we divide by:
        //      - SECONDS_PER_YEAR  (time scaling)
        //      - 10000             (rate scaling)
        //
        //    Concrete numbers:
        //      - totalDebtValue = 1,000 MyUSD
        //      - borrowRate     = 125 (1.25% APR)
        //      - timeElapsed    = SECONDS_PER_YEAR (1 year)
        //
        //      interest = 1000 * 125 * 1year / (1year * 10000)
        //               = 1000 * 125 / 10000
        //               = 12.5 MyUSD
        uint256 interest = (totalDebtValue * borrowRate * timeElapsed) / (SECONDS_PER_YEAR * 10000);

        // 6) Convert the newly accrued interest into an increase in the exchange rate (value per share).
        //
        //    Goal:
        //      newTotalDebt = oldTotalDebt + interest
        //
        //    We know:
        //      totalDebt = totalDebtShares * exchangeRate / PRECISION
        //
        //    Solve for the required exchange rate increase (ΔexchangeRate):
        //      ΔexchangeRate = interest * PRECISION / totalDebtShares
        //
        //    This makes each share worth slightly more MyUSD, so every borrower's debt increases
        //    without updating per-user storage.
        //
        //    Example continuing:
        //      totalDebtShares = 100
        //      interest        = 10 MyUSD
        //      PRECISION       = 1e18
        //
        //      ΔexchangeRate = 10 * 1e18 / 100 = 0.1e18
        //
        //      If old exchangeRate = 1.1e18, new exchangeRate = 1.2e18
        //      New total debt:
        //        100 * 1.2e18 / 1e18 = 120 MyUSD
        //      Which equals 110 + 10 interest.
        return debtExchangeRate + (interest * PRECISION) / totalDebtShares;
    }

    /**
     * @notice Accrues interest on outstanding debt by updating the global `debtExchangeRate`.
     * @dev “Accruing interest” means:
     *      - computing how much interest accumulated since `lastUpdateTime`
     *      - updating protocol accounting so all debts reflect that interest
     *
     *      This system uses a share-based model:
     *          userDebt = userDebtShares * debtExchangeRate / PRECISION
     *
     *      Instead of updating every user's debt, we increase `debtExchangeRate`.
     *      When the exchange rate goes up, every borrower’s debt increases automatically.
     *
     *      Conceptually, this function:
     *      1) Calculates the up-to-date exchange rate (including interest since last update)
     *      2) Stores it in `debtExchangeRate`
     *      3) Updates `lastUpdateTime` to checkpoint the accrual
     */
    function _accrueInterest() internal {
        // If no one has borrowed, there is no debt to accrue interest on.
        // We still update `lastUpdateTime` to avoid charging "retroactive" interest later.
        if (totalDebtShares == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }

        // Compute the exchange rate as of now (adds interest to the global debt pool),
        // then store it so future calculations start from this updated rate.
        debtExchangeRate = _getCurrentExchangeRate();

        // Move the checkpoint forward: future interest accrues from this timestamp.
        lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Converts a MyUSD amount into the equivalent number of debt shares.
     * @dev Shares represent a proportional claim on the total system debt.
     *      The conversion uses the current exchange rate so new borrowers
     *      do not pay previously accrued interest.
     *
     *      Formula:
     *          shares = amount * PRECISION / exchangeRate
     *
     *      Example:
     *      - exchangeRate = 1.1 MyUSD per share
     *      - amount = 100 MyUSD
     *      - shares = 100 / 1.1 = 90.91 shares
     *
     * @param amount The amount of MyUSD to convert into debt shares.
     * @return The number of debt shares corresponding to `amount`.
     */
    function _getMyUSDToShares(uint256 amount) internal view returns (uint256) {
        uint256 currentExchangeRate = _getCurrentExchangeRate();
        uint256 currentDebtShares = (amount * PRECISION) / currentExchangeRate;
        return currentDebtShares;
    }

    // Checkpoint 4: Minting MyUSD & Position Health
    /**
     * @notice Returns the user's current debt in MyUSD, including accrued interest.
     * @dev Debt is tracked in shares and converted to MyUSD using the current exchange rate:
     *      debtMyUSD = userDebtShares * currentExchangeRate / PRECISION.
     * @param user The address of the user to query.
     * @return The user's current debt denominated in MyUSD.
     */
    function getCurrentDebtValue(address user) public view returns (uint256) {
        if (s_userDebtShares[user] == 0) {
            return 0;
        }
        uint256 currentExchangeRate = _getCurrentExchangeRate();
        return (s_userDebtShares[user] * currentExchangeRate) / PRECISION;
    }

    /**
     * @notice Calculates a user's collateralization ratio.
     * @dev The ratio is defined as:
     *      collateralValue / debtValue
     *      and is returned using `PRECISION` fixed-point scaling.
     *
     *      If the user has no outstanding debt, the position is treated
     *      as infinitely collateralized and returns `type(uint256).max`.
     *
     * @param user The address of the user to query.
     * @return The user's collateralization ratio, scaled by `PRECISION`.
     */
    function calculatePositionRatio(address user) public view returns (uint256) {
        // Get the user's current debt (including accrued interest)
        uint256 debtValue = getCurrentDebtValue(user);
        if (debtValue == 0) {
            // Infinite collateralization (no debt)
            return type(uint256).max;
        }
        // Get the user's collateral value in MyUSD
        uint256 collateralValue = calculateCollateralValue(user);

        // collateralizationRatio = collateralValue / debtValue
        return (collateralValue * PRECISION) / debtValue;
    }
    /**
     * @notice Reverts if a user's position is below the minimum collateral ratio.
     * @dev `calculatePositionRatio(user)` returns (collateralValue / debtValue) scaled by `PRECISION`.
     *      We compare it against `COLLATERAL_RATIO` (a percentage, e.g. 150 = 150%).
     * @param user The address of the user whose position is being validated.
     */
    function _validatePosition(address user) internal view {
        // Returns the user’s collateralization ratio scaled by PRECISION.
        //
        // Example:
        //   collateral = 150 MyUSD
        //   debt       = 100 MyUSD
        //   positionRatio = (150 / 100) * 1e18 = 1.5e18
        uint256 positionRatio = calculatePositionRatio(user);

        // `positionRatio` is a decimal ratio (scaled by PRECISION), e.g. 1.5e18 for 150%.
        // `COLLATERAL_RATIO` is a percentage integer, e.g. 150 for 150% (not 1.5).
        //
        // We need both sides in the same unit.
        //
        // Start from the intended safety condition:
        //   collateral / debt >= COLLATERAL_RATIO / 100
        //
        // Multiply both sides by 100:
        //   (collateral / debt) * 100 >= COLLATERAL_RATIO
        //
        // Since `positionRatio = (collateral / debt) * PRECISION`, substitute:
        //   (positionRatio * 100) / PRECISION >= COLLATERAL_RATIO
        //
        // Rearranged to avoid division (and keep precision):
        //   positionRatio * 100 >= COLLATERAL_RATIO * PRECISION
        //
        // Example (safe):
        //   collateral = 150, debt = 100
        //   positionRatio = 1.5e18
        //   LHS = 1.5e18 * 100 = 150e18
        //   RHS = 150 * 1e18   = 150e18  ✅
        //
        // Example (unsafe):
        //   collateral = 140, debt = 100
        //   positionRatio = 1.4e18
        //   LHS = 140e18
        //   RHS = 150e18  ❌
        bool isPositionSafe = (positionRatio * 100) >= (COLLATERAL_RATIO * PRECISION);

        if (!isPositionSafe) {
            revert Engine__UnsafePositionRatio();
        }
    }

    /**
     * @notice Mints MyUSD stablecoins against the caller's collateral.
     * @dev This function performs the full borrow flow using the share-based debt model:
     *      1. Converts the MyUSD amount into debt shares using the current exchange rate
     *      2. Updates the user's debt shares and the total system debt shares
     *      3. Validates that the position remains safely collateralized
     *      4. Mints the actual MyUSD tokens to the user
     *
     *      Reverts if the mint amount is zero or if the resulting position
     *      falls below the minimum collateral ratio.
     *
     * @param mintAmount The amount of MyUSD to mint.
     */
    function mintMyUSD(uint256 mintAmount) public {
        // Disallow minting zero MyUSD (no-op and potential edge case)
        if (mintAmount == 0) {
            revert Engine__InvalidAmount();
        }

        // Convert the MyUSD amount into debt shares using the current exchange rate.
        // This ensures the user does NOT pay interest accrued before this mint.
        uint256 shares = _getMyUSDToShares(mintAmount);

        // Increase the caller's debt shares.
        // Shares represent the user's proportional claim on total system debt.
        s_userDebtShares[msg.sender] += shares;

        // Increase the total debt shares in the system.
        // Interest accrual works by increasing the exchange rate, not shares.
        totalDebtShares += shares;

        // Validate that the user's position is still safely collateralized
        // after taking on the new debt.
        _validatePosition(msg.sender);

        // Mint the actual MyUSD tokens to the user.
        // At this point, the debt has already been accounted for via shares.
        i_myUSD.mintTo(msg.sender, mintAmount);

        // Emit an event for off-chain indexing and accounting
        emit DebtSharesMinted(msg.sender, mintAmount, shares);
    }

    // Checkpoint 5: Accruing Interest & Managing Borrow Rates
    /**
     * @notice Updates the borrow rate used for interest accrual.
     * @dev Can only be called by the rate controller.
     *
     *      Before applying the new rate, the contract accrues all pending interest
     *      using the current rate to ensure correct accounting:
     *      - past debt is finalized under the old rate
     *      - future debt accrues under the new rate
     *
     *      Additionally enforces: `newRate >= savingsRate`.
     *      This ensures the system can always cover the yield paid to stakers.
     *
     *      Reverts with `Engine__InvalidBorrowRate` if `newRate < savingsRate`.
     *
     * @param newRate The new borrow rate (2-decimal basis points, where 10000 = 100.00% APR).
     */
    function setBorrowRate(uint256 newRate) external onlyRateController {
        uint256 savingsRate = i_staking.savingsRate();
        if (newRate < savingsRate) {
            revert Engine__InvalidBorrowRate();
        }

        _accrueInterest();
        borrowRate = newRate;
        emit BorrowRateUpdated(newRate);
    }

    // Checkpoint 6: Repaying Debt & Withdrawing Collateral
    /**
     * @notice Repays up to `amount` of the caller's MyUSD debt.
     * @dev Debt is tracked in shares. The requested MyUSD amount is first converted to shares
     *      using the current exchange rate. If the caller requests to repay more than their
     *      outstanding debt, the function caps the repayment to the user's full debt.
     *
     *      Requirements:
     *      - Caller must have enough MyUSD balance
     *      - Caller must approve this contract to spend/burn the MyUSD
     *
     *      Effects:
     *      - Decreases the caller's debt shares and total system debt shares
     *      - Burns the repaid MyUSD from the caller
     *
     * @param amount The maximum amount of MyUSD debt to repay.
     */
    function repayUpTo(uint256 amount) public {
        // Convert the requested MyUSD repayment amount into debt shares at the current exchange rate.
        // This determines how many shares to burn from the caller's debt position.
        uint256 amountInShares = _getMyUSDToShares(amount);

        // Load the caller's current debt shares (how much debt they own in share terms).
        uint256 shares = s_userDebtShares[msg.sender];

        // If the user tries to repay more shares than they owe, cap the repayment to full repayment.
        // We set:
        // - amountInShares to all their shares (repay entire position)
        // - amount to the current total debt value in MyUSD (so we burn exactly what they owe)
        if (amountInShares > shares) {
            amountInShares = shares;
            amount = getCurrentDebtValue(msg.sender);
        }

        // Ensure the repayment is non-zero and the caller has enough MyUSD to repay.
        // Note: `amount` may have been adjusted above if we capped to full repayment.
        uint256 myUsdBalance = i_myUSD.balanceOf(msg.sender);
        if (amount == 0 || myUsdBalance < amount) {
            revert MyUSD__InsufficientBalance();
        }

        // Ensure this contract is allowed to burn `amount` MyUSD from the caller.
        // burnFrom typically checks allowance, but we fail early with a clear custom error.
        uint256 myUsdAllowance = i_myUSD.allowance(msg.sender, address(this));
        if (myUsdAllowance < amount) {
            revert MyUSD__InsufficientAllowance();
        }

        // Reduce the caller's debt shares by the number of shares being repaid.
        s_userDebtShares[msg.sender] -= amountInShares;

        // Reduce the total debt shares in the system by the same amount.
        // This keeps the global accounting consistent.
        totalDebtShares -= amountInShares;

        // Burn the repaid MyUSD tokens from the caller, reducing token supply and outstanding debt.
        i_myUSD.burnFrom(msg.sender, amount);

        // Emit the repayment details (who repaid, how much MyUSD was burned, and how many shares were removed).
        emit DebtSharesBurned(msg.sender, amount, amountInShares);
    }

    /**
     * @notice Withdraws ETH collateral from the system back to the caller.
     * @dev Decreases the caller's recorded collateral balance and, if the caller has debt,
     *      validates that the position remains safely collateralized after the withdrawal.
     *
     *      Flow:
     *      1) Check input and available collateral
     *      2) Decrease stored collateral (effects)
     *      3) If debt exists, validate collateral ratio (may revert)
     *      4) Transfer ETH to the caller (interaction)
     *
     *      Reverts if:
     *      - `amount` is zero
     *      - caller does not have enough collateral
     *      - withdrawal would make the position unsafe (when debt > 0)
     *
     * @param amount The amount of ETH collateral to withdraw (in wei).
     */
    function withdrawCollateral(uint256 amount) external {
        // Disallow withdrawing zero collateral.
        if (amount == 0) {
            revert Engine__InvalidAmount();
        }

        // Ensure the caller has enough deposited collateral to withdraw.
        if (s_userCollateral[msg.sender] < amount) {
            revert Engine__InsufficientCollateral();
        }

        // Effects: optimistically reduce collateral in storage.
        // If validation fails later, the revert will roll back this change.
        s_userCollateral[msg.sender] -= amount;

        // If the user has outstanding debt, ensure they remain safely collateralized
        // after reducing their collateral.
        if (s_userDebtShares[msg.sender] > 0) {
            _validatePosition(msg.sender);
        }

        // Interaction: transfer ETH after all checks/updates are done.
        // (Optional improvement: revert if `success` is false.)
        (bool success, ) = payable(msg.sender).call{ value: amount }("");
        if (!success) {
            revert Engine__TransferFailed();
        }
        // Emit event with withdrawal amount and the current ETH/USD price used for UI/indexing.
        emit CollateralWithdrawn(msg.sender, amount, i_oracle.getETHMyUSDPrice());
    }

    // Checkpoint 7: Liquidation - Enforcing System Stability
    /**
     * @notice Returns whether a user's position is eligible for liquidation.
     * @dev A position becomes liquidatable when its collateralization ratio
     *      falls below the minimum required `COLLATERAL_RATIO`.
     *
     *      The collateralization ratio is defined as:
     *          collateralValue / debtValue
     *      and is scaled by `PRECISION`.
     *
     *      Liquidation can happen if:
     *      - The value of collateral (ETH) decreases, or
     *      - The user increases their debt beyond safe limits.
     *
     * @param user The address of the user to evaluate.
     * @return True if the user's position is below the required collateral ratio.
     */
    function isLiquidatable(address user) public view returns (bool) {
        // Compute the user's current collateralization ratio:
        // positionRatio = (collateralValue / debtValue) * PRECISION
        uint256 positionRatio = calculatePositionRatio(user);

        // A position is liquidatable if:
        //   collateral / debt < COLLATERAL_RATIO / 100
        //
        // Since:
        //   positionRatio = (collateral / debt) * PRECISION
        // and COLLATERAL_RATIO is expressed as a percentage (e.g. 150 for 150%),
        // we compare scaled values:
        //
        //   positionRatio * 100 < COLLATERAL_RATIO * PRECISION
        //
        // If true → the position is undercollateralized and can be liquidated.
        return (positionRatio * 100) < (COLLATERAL_RATIO * PRECISION);
    }

    /**
     * @notice Liquidates an undercollateralized position by repaying the user's debt in MyUSD
     *         and seizing the user's ETH collateral (plus a liquidation bonus).
     * @dev Anyone can call this function. The caller (`msg.sender`) is the liquidator.
     *
     *      High-level flow:
     *      1) Verify the user's position is liquidatable
     *      2) Compute the user's current debt (including accrued interest) and collateral
     *      3) Burn MyUSD from the liquidator equal to the user's debt (debt repayment)
     *      4) Clear the user's debt shares
     *      5) Transfer to the liquidator enough ETH to cover the debt value + bonus
     *
     *      This mechanism:
     *      - Removes risky debt from the system
     *      - Incentivizes third parties to keep the protocol solvent
     *
     * @param user The address of the borrower to liquidate.
     */
    function liquidate(address user) external {
        // 1) Ensure the user's position is below the minimum collateral ratio.
        // If not, liquidation is not allowed.
        if (!isLiquidatable(user)) {
            revert Engine__NotLiquidatable();
        }

        // 2) Fetch the user's debt in MyUSD including any accrued interest.
        uint256 userDebtValue = getCurrentDebtValue(user);

        // 3) Fetch the user's collateral amount in ETH (wei).
        uint256 userCollateral = s_userCollateral[user];

        // 4) Convert the user's ETH collateral into its MyUSD value using the oracle.
        // This is used to compute how much ETH corresponds to `userDebtValue`.
        uint256 collateralValue = calculateCollateralValue(user);

        // 5) The liquidator must have enough MyUSD to repay the user's debt.
        uint256 liquidatorBalance = i_myUSD.balanceOf(msg.sender);
        if (liquidatorBalance < userDebtValue) {
            revert MyUSD__InsufficientBalance();
        }

        // 6) The liquidator must approve this contract to burn their MyUSD.
        uint256 engineAllowance = i_myUSD.allowance(msg.sender, address(this));
        if (engineAllowance < userDebtValue) {
            revert MyUSD__InsufficientAllowance();
        }

        // 7) Repay the user's debt by burning `userDebtValue` MyUSD from the liquidator.
        // This reduces MyUSD supply and removes the equivalent debt from the system.
        i_myUSD.burnFrom(msg.sender, userDebtValue);

        // 8) Clear the user's debt shares (the user's debt is now considered repaid).
        // We must also reduce the global total shares to keep accounting consistent.
        totalDebtShares -= s_userDebtShares[user];
        s_userDebtShares[user] = 0;

        // 9) Compute how much ETH collateral corresponds to the debt value.
        //
        // `collateralValue` is the MyUSD value of the *entire* collateral.
        // So (userDebtValue / collateralValue) gives the fraction of collateral needed to cover the debt.
        // Multiply by `userCollateral` to convert that fraction back into an ETH amount (wei).
        uint256 collateralToCoverDebt = (userDebtValue * userCollateral) / collateralValue;

        // 10) Add the liquidator bonus (e.g. 10%).
        uint256 rewardAmount = (collateralToCoverDebt * LIQUIDATOR_REWARD) / 100;
        uint256 amountForLiquidator = collateralToCoverDebt + rewardAmount;

        // 11) Cap seizure to the user's remaining collateral (safety guard).
        if (amountForLiquidator > userCollateral) {
            amountForLiquidator = userCollateral;
        }

        // 12) Decrease the user's collateral by the seized amount.
        s_userCollateral[user] -= amountForLiquidator;

        // 13) Transfer seized ETH collateral to the liquidator.
        (bool sent, ) = payable(msg.sender).call{ value: amountForLiquidator }("");
        if (!sent) {
            revert Engine__TransferFailed();
        }

        // 14) Emit an event for indexing and analytics (who, how much collateral, how much debt, and price).
        emit Liquidation(user, msg.sender, amountForLiquidator, userDebtValue, i_oracle.getETHMyUSDPrice());
    }
}

//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import { PredictionMarketToken } from "./PredictionMarketToken.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PredictionMarket is Ownable {
    /////////////////
    /// Errors //////
    /////////////////

    error PredictionMarket__MustProvideETHForInitialLiquidity();
    error PredictionMarket__InvalidProbability();
    error PredictionMarket__PredictionAlreadyReported();
    error PredictionMarket__OnlyOracleCanReport();
    error PredictionMarket__OwnerCannotCall();
    error PredictionMarket__PredictionNotReported();
    error PredictionMarket__InsufficientWinningTokens();
    error PredictionMarket__AmountMustBeGreaterThanZero();
    error PredictionMarket__MustSendExactETHAmount();
    error PredictionMarket__InsufficientTokenReserve(Outcome _outcome, uint256 _amountToken);
    error PredictionMarket__TokenTransferFailed();
    error PredictionMarket__ETHTransferFailed();
    error PredictionMarket__InsufficientBalance(uint256 _tradingAmount, uint256 _userBalance);
    error PredictionMarket__InsufficientAllowance(uint256 _tradingAmount, uint256 _allowance);
    error PredictionMarket__InsufficientLiquidity();
    error PredictionMarket__InvalidPercentageToLock();

    //////////////////////////
    /// State Variables //////
    //////////////////////////

    enum Outcome {
        YES,
        NO
    }

    uint256 private constant PRECISION = 1e18;

    /// Checkpoint 2 ///
    address public immutable i_oracle;

    /*
        Represents the maximum payout value of a winning outcome token.

        If you hold a token corresponding to the correct outcome,
        you can redeem it for `i_initialTokenValue` ETH (e.g. 0.01 ETH).

        Tokens on the losing side are worth 0 ETH.

        Therefore, during trading the price of an outcome token
        will always be between:
        - 0, if the outcome is expected to lose
        - i_initialTokenValue, if the outcome is certain to win
    */
    uint256 public immutable i_initialTokenValue;

    /*
        Defines what percentage of the total tokens will be locked
        in the liquidity pool when the market is created.

        These locked tokens provide the initial AMM liquidity.

        Example:
            percentageLocked = 10
            YES tokens = 100
            NO tokens = 100

            total tokens = 200
            locked tokens = 200 * 10% = 20

        These locked tokens are used to initialize the market price.
    */
    uint256 public immutable i_percentageLocked;

    /*
        Defines the initial probability assigned to the YES outcome
        when the market starts.

        Example:
            i_initialYesProbability = 60

        Meaning:
            YES probability = 60%
            NO probability = 40%

        The contract uses this value to determine how many YES and NO
        tokens should be locked.

        Example:
            lockedYes = 12
            lockedNo = 8

        This creates the starting probability:
            12 / (12 + 8) = 60%
    */
    uint256 public immutable i_initialYesProbability;

    /*
        Stores the question the prediction market is about.
    */
    string public s_question;

    /*
        Tracks the ETH collateral backing the prediction market.

        This ETH is used to pay the winners when the market resolves.

        Example:
            if each winning token pays 0.01 ETH
            and the contract holds 1 ETH,
            then it can support 100 winning tokens.

        This variable therefore keeps track of the total collateral
        deposited in the system.
    */
    uint256 public s_ethCollateral;

    /*
        Tracks the trading fees collected by the market.

        In a prediction market with an AMM, users buy YES or NO tokens
        and a small trading fee is charged on each trade.

        These fees accumulate in `s_lpTradingRevenue` and can later be
        distributed to liquidity providers (LPs).

        Example:
            trade amount = 1 ETH
            trading fee = 1%

            fee collected = 0.01 ETH

        Over time, LPs earn revenue from these trading fees.
    */
    uint256 public s_lpTradingRevenue;

    /// Checkpoint 3 ///
    PredictionMarketToken public immutable i_yesToken;
    PredictionMarketToken public immutable i_noToken;

    /// Checkpoint 5 ///
    // Token representing the winning outcome once the market is resolved
    PredictionMarketToken public s_winningToken;
    // True if the oracle has reported the market outcome
    bool public s_isReported;

    /////////////////////////
    /// Events //////
    /////////////////////////

    event TokensPurchased(address indexed buyer, Outcome outcome, uint256 amount, uint256 ethAmount);
    event TokensSold(address indexed seller, Outcome outcome, uint256 amount, uint256 ethAmount);
    event WinningTokensRedeemed(address indexed redeemer, uint256 amount, uint256 ethAmount);
    event MarketReported(address indexed oracle, Outcome winningOutcome, address winningToken);
    event MarketResolved(address indexed resolver, uint256 totalEthToSend);
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 tokensAmount);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 tokensAmount);

    /////////////////
    /// Modifiers ///
    /////////////////

    /// Checkpoint 5 ///
    modifier predictionNotReported() {
        if (s_isReported) {
            revert PredictionMarket__PredictionAlreadyReported();
        }
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != i_oracle) {
            revert PredictionMarket__OnlyOracleCanReport();
        }
        _;
    }

    /// Checkpoint 6 ///
    modifier predictionReported() {
        if (!s_isReported) {
            revert PredictionMarket__PredictionNotReported();
        }
        _;
    }

    /// Checkpoint 8 ///
    modifier notOwner() {
        if (msg.sender == owner()) {
            revert PredictionMarket__OwnerCannotCall();
        }
        _;
    }

    modifier amountGreaterThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }
        _;
    }

    //////////////////
    ////Constructor///
    //////////////////

    constructor(
        address _liquidityProvider,
        address _oracle,
        string memory _question,
        uint256 _initialTokenValue,
        uint8 _initialYesProbability,
        uint8 _percentageToLock
    ) payable Ownable(_liquidityProvider) {
        /// Checkpoint 2 ////
        if (msg.value == 0) {
            revert PredictionMarket__MustProvideETHForInitialLiquidity();
        }

        if (_initialYesProbability == 0 || _initialYesProbability >= 100) {
            revert PredictionMarket__InvalidProbability();
        }

        if (_percentageToLock == 0 || _percentageToLock >= 100) {
            revert PredictionMarket__InvalidPercentageToLock();
        }

        i_oracle = _oracle;
        i_initialTokenValue = _initialTokenValue;
        i_initialYesProbability = _initialYesProbability;
        i_percentageLocked = _percentageToLock;

        s_question = _question;
        s_ethCollateral = msg.value;

        /// Checkpoint 3 ////
        /*
            The number of outcome tokens that can be safely minted depends on the
            ETH collateral deposited when creating the market.

            If the contract receives 1 ETH (msg.value) and each winning token
            pays 0.01 ETH (_initialTokenValue), the number of tokens that can
            be supported is:

                numberOfTokens = totalCollateral / payoutPerToken

            Example:
                1 / 0.01 = 100 tokens

            Since Solidity uses integer math, a scaling factor (PRECISION = 1e18)
            is used to preserve decimal precision and support fractional values.

            The formula therefore becomes:

                initialTokenAmount = (msg.value * PRECISION) / _initialTokenValue

            Example values:
                msg.value = 1 ETH = 1e18
                _initialTokenValue = 0.01 ETH = 1e16
                PRECISION = 1e18

                initialTokenAmount = (1e18 * 1e18) / 1e16 = 1e20

            This corresponds to 100 tokens with 18 decimals.
        */
        uint256 initialTokenAmount = (msg.value * PRECISION) / _initialTokenValue;
        // Depolying the yes and no ERC20 tokens
        i_yesToken = new PredictionMarketToken("Yes", "Y", msg.sender, initialTokenAmount);
        i_noToken = new PredictionMarketToken("No", "N", msg.sender, initialTokenAmount);

        /*
            Compute how many YES tokens must be locked in the pool at market creation
            to establish the initial probability and the initial liquidity.

            In a prediction market, the price ratio between YES and NO tokens
            represents the market-implied probability.

            1. initialTokenAmount is the number of tokens minted per outcome.

                Example:
                    YES tokens = 100
                    NO tokens  = 100

                So:
                    initialTokenAmount = 100

            2. _initialYesProbability represents the initial probability of YES,
            expressed as a percentage.

                Example:
                    _initialYesProbability = 60

                Meaning:
                    YES probability = 60%
                    NO probability  = 40%

            3. _percentageToLock determines how much liquidity to lock initially.

                Example:
                    _percentageToLock = 10

                Meaning:
                    10% of the total tokens will be locked in the pool.

            4. Why multiply by 2?

                Because there are two token supplies:

                    YES tokens
                    NO tokens

                Total tokens in the system:
                    initialTokenAmount * 2

                Example:
                    100 YES
                    100 NO
                    total = 200 tokens

            5. Why divide by 10000?

                Because two percentages are multiplied:

                    _initialYesProbability -> %
                    _percentageToLock      -> %

                Example:
                    60 * 10 = 600

                Since percentages are out of 100:

                    100 * 100 = 10000

            Full example:

                initialTokenAmount = 100
                _initialYesProbability = 60
                _percentageToLock = 10

                initialYesAmountLocked = (100 * 60 * 10 * 2) / 10000 = 12

                Result:
                    12 YES tokens are locked in the pool.
        */
        uint256 initialYesAmountLocked = (initialTokenAmount * _initialYesProbability * _percentageToLock * 2) / 10000;
        uint256 initialNoAmountLocked = (initialTokenAmount * (100 - _initialYesProbability) * _percentageToLock * 2) /
            10000;

        bool successYesToken = i_yesToken.transfer(msg.sender, initialYesAmountLocked);
        bool successNoToken = i_noToken.transfer(msg.sender, initialNoAmountLocked);
        if (!successYesToken || !successNoToken) {
            revert PredictionMarket__TokenTransferFailed();
        }
    }

    /////////////////
    /// Functions ///
    /////////////////

    /**
     * @notice Add liquidity to the prediction market and mint outcome tokens
     * @dev Only the owner can add liquidity and only before the market is resolved.
     *      The ETH sent backs the payout of winning tokens.
     */
    function addLiquidity() external payable onlyOwner predictionNotReported {
        //// Checkpoint 4 ////

        // Ensure that some ETH is actually provided as liquidity
        if (msg.value == 0) {
            revert PredictionMarket__InsufficientLiquidity();
        }

        // Increase the ETH collateral backing the market
        // This ETH will later be used to pay the holders of the winning tokens
        s_ethCollateral += msg.value;

        /*
            Calculate how many outcome tokens can be minted from the provided ETH.

            Each winning token is redeemable for `i_initialTokenValue` ETH.

            Example:
                msg.value = 1 ETH
                i_initialTokenValue = 0.01 ETH

                tokensAmount = 1 / 0.01 = 100 tokens

            PRECISION is used to preserve decimal accuracy since Solidity
            uses integer arithmetic.
        */
        uint256 tokensAmount = (msg.value * PRECISION) / i_initialTokenValue;

        // Mint equal amounts of YES and NO tokens to the contract.
        // These tokens will be used as liquidity for trading in the market.
        i_yesToken.mint(address(this), tokensAmount);
        i_noToken.mint(address(this), tokensAmount);

        // Emit an event so off-chain systems can track liquidity additions
        emit LiquidityAdded(msg.sender, msg.value, tokensAmount);
    }

    /**
     * @notice Remove liquidity from the prediction market
     * @dev Only the owner can remove liquidity. ETH withdrawn must be backed
     *      by burning the corresponding amount of YES and NO tokens.
     * @param _ethToWithdraw Amount of ETH to withdraw from liquidity pool
     */
    function removeLiquidity(uint256 _ethToWithdraw) external onlyOwner predictionNotReported {
        //// Checkpoint 4 ////

        // Prevent removing zero liquidity (meaningless operation)
        if (_ethToWithdraw == 0) {
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }

        /*
            Calculate how many outcome tokens must be burned in order
            to withdraw the requested ETH.

            Each winning token corresponds to `i_initialTokenValue` ETH.

            Example:
                _ethToWithdraw = 1 ETH
                i_initialTokenValue = 0.01 ETH

                tokens to burn = 1 / 0.01 = 100 tokens
        */
        uint256 amountTokenToBurn = (_ethToWithdraw * PRECISION) / i_initialTokenValue;

        // Ensure the contract holds enough YES tokens to burn
        if (amountTokenToBurn > i_yesToken.balanceOf(address(this))) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.YES, amountTokenToBurn);
        }

        // Ensure the contract holds enough NO tokens to burn
        if (amountTokenToBurn > i_noToken.balanceOf(address(this))) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.NO, amountTokenToBurn);
        }

        // Reduce the ETH collateral backing the market
        s_ethCollateral -= _ethToWithdraw;

        // Burn equal amounts of YES and NO tokens
        // This maintains the invariant between collateral and token supply
        i_yesToken.burn(address(this), amountTokenToBurn);
        i_noToken.burn(address(this), amountTokenToBurn);

        // Transfer the requested ETH back to the owner
        (bool success, ) = msg.sender.call{ value: _ethToWithdraw }("");
        if (!success) {
            revert PredictionMarket__ETHTransferFailed();
        }

        // Emit event for off-chain tracking
        emit LiquidityRemoved(msg.sender, _ethToWithdraw, amountTokenToBurn);
    }

    /**
     * @notice Report the winning outcome for the prediction
     * @dev Only the oracle can report the winning outcome and only if the prediction is not reported
     * @param _winningOutcome The winning outcome (YES or NO)
     */
    function report(Outcome _winningOutcome) external onlyOracle predictionNotReported {
        //// Checkpoint 5 ////
        s_winningToken = _winningOutcome == Outcome.YES ? i_yesToken : i_noToken;
        s_isReported = true;
        emit MarketReported(msg.sender, _winningOutcome, address(s_winningToken));
    }

    /**
     * @notice Redeems the contract's winning tokens after market resolution and withdraws the corresponding ETH plus LP revenue.
     * @dev Callable only by the owner and only after the market outcome has been reported.
     *      At this stage, `s_winningToken` has already been set to the winning outcome token.
     *      If the contract still holds winning tokens, they can be redeemed for ETH.
     *      The owner also receives any trading fees accumulated in `s_lpTradingRevenue`.
     * @return ethRedeemed The amount of ETH redeemed from the contract's winning tokens.
     */
    function resolveMarketAndWithdraw() external onlyOwner predictionReported returns (uint256 ethRedeemed) {
        /// Checkpoint 6 ////

        // Check how many winning tokens are still held by the contract.
        // Only winning tokens have redeemable value after market resolution.
        uint256 contractWinningTokens = s_winningToken.balanceOf(address(this));

        // If the contract still holds winning tokens, convert them into ETH.
        // The function does not revert when the balance is zero, because the owner
        // may still need to withdraw accumulated LP trading revenue.
        if (contractWinningTokens > 0) {
            /*
                Convert winning tokens into ETH.

                Formula:
                    ethRedeemed = (winningTokens * payoutPerWinningToken) / PRECISION

                Example:
                    contractWinningTokens = 100e18
                    i_initialTokenValue   = 0.01 ether
                    PRECISION             = 1e18

                    ethRedeemed = (100e18 * 0.01e18) / 1e18 = 1 ether
            */
            ethRedeemed = (contractWinningTokens * i_initialTokenValue) / PRECISION;

            // Never redeem more ETH than the collateral currently tracked by the contract.
            if (ethRedeemed > s_ethCollateral) {
                ethRedeemed = s_ethCollateral;
            }

            // Reduce the collateral accounting, since this ETH is about to be withdrawn.
            s_ethCollateral -= ethRedeemed;
        }

        /*
            Total ETH sent to the owner is made of:
            1. ETH redeemed from winning tokens held by the contract
            2. Trading fees accumulated for the liquidity provider
        */
        uint256 totalEthToSend = ethRedeemed + s_lpTradingRevenue;

        // Reset LP revenue before the external call following the CEI pattern.
        s_lpTradingRevenue = 0;

        // Burn the contract's winning tokens after redeeming their value.
        s_winningToken.burn(address(this), contractWinningTokens);

        // Transfer the redeemed ETH and LP revenue to the owner.
        (bool success, ) = msg.sender.call{ value: totalEthToSend }("");
        if (!success) {
            revert PredictionMarket__ETHTransferFailed();
        }

        emit MarketResolved(msg.sender, totalEthToSend);
        return ethRedeemed;
    }

    /**
     * @notice Buy prediction outcome tokens using ETH
     * @dev The user must first call `getBuyPriceInEth` to know the exact ETH required.
     *      The transaction must send exactly that amount of ETH.
     * @param _outcome The outcome token to buy (YES or NO)
     * @param _amountTokenToBuy Number of tokens the user wants to purchase
     */
    function buyTokensWithETH(
        Outcome _outcome,
        uint256 _amountTokenToBuy
    ) external payable predictionNotReported amountGreaterThanZero(_amountTokenToBuy) notOwner {
        /// Checkpoint 8 ////

        // Calculate how much ETH is required for this purchase
        uint256 ethNeeded = getBuyPriceInEth(_outcome, _amountTokenToBuy);

        // Ensure the user sends the exact ETH amount required for the trade
        if (msg.value != ethNeeded) {
            revert PredictionMarket__MustSendExactETHAmount();
        }

        // Select which outcome token contract to interact with (YES or NO)
        PredictionMarketToken outcomeToken = _outcome == Outcome.YES ? i_yesToken : i_noToken;

        // Check how many tokens of that outcome the contract currently holds
        uint256 contractTokenBalance = outcomeToken.balanceOf(address(this));

        // Ensure the contract has enough tokens available to sell
        if (_amountTokenToBuy > contractTokenBalance) {
            revert PredictionMarket__InsufficientTokenReserve(_outcome, _amountTokenToBuy);
        }

        // Add the received ETH to LP trading revenue
        // This represents the fee/revenue generated by the trade
        s_lpTradingRevenue += msg.value;

        // Transfer the purchased tokens from the contract to the buyer
        bool success = outcomeToken.transfer(msg.sender, _amountTokenToBuy);
        if (!success) {
            revert PredictionMarket__TokenTransferFailed();
        }

        // Emit event so off-chain systems can track the trade
        emit TokensPurchased(msg.sender, _outcome, _amountTokenToBuy, msg.value);
    }

    /**
     * @notice Sell prediction outcome tokens for ETH
     * @dev The user should first call `getSellPriceInEth` to know how much ETH they will receive.
     * @param _outcome The outcome token to sell (YES or NO)
     * @param _tradingAmount The amount of tokens the user wants to sell
     */
    function sellTokensForEth(
        Outcome _outcome,
        uint256 _tradingAmount
    ) external predictionNotReported amountGreaterThanZero(_tradingAmount) notOwner {
        /// Checkpoint 8 ////

        // Determine which token contract to interact with (YES or NO)
        PredictionMarketToken outcomeToken = _outcome == Outcome.YES ? i_yesToken : i_noToken;

        // Check that the user actually owns enough tokens to sell
        uint256 userBalance = outcomeToken.balanceOf(msg.sender);
        if (userBalance < _tradingAmount) {
            revert PredictionMarket__InsufficientBalance(_tradingAmount, userBalance);
        }

        // Ensure the contract is approved to transfer the user's tokens
        uint256 allowance = outcomeToken.allowance(msg.sender, address(this));
        if (allowance < _tradingAmount) {
            revert PredictionMarket__InsufficientAllowance(_tradingAmount, allowance);
        }

        // Calculate how much ETH the user should receive for selling the tokens
        uint256 ethToReceive = getSellPriceInEth(_outcome, _tradingAmount);

        // Reduce LP trading revenue since the contract is paying ETH to the seller
        s_lpTradingRevenue -= ethToReceive;

        // Send ETH to the seller
        (bool successEthTransfer, ) = msg.sender.call{ value: ethToReceive }("");
        if (!successEthTransfer) {
            revert PredictionMarket__ETHTransferFailed();
        }

        // Transfer the tokens from the user back to the contract (tokens return to the pool)
        bool successTokenTransfer = outcomeToken.transferFrom(msg.sender, address(this), _tradingAmount);
        if (!successTokenTransfer) {
            revert PredictionMarket__TokenTransferFailed();
        }

        // Emit event so off-chain systems can track the trade
        emit TokensSold(msg.sender, _outcome, _tradingAmount, ethToReceive);
    }

    /**
     * @notice Redeem winning outcome tokens for ETH after the market is resolved
     * @dev Users who hold tokens corresponding to the correct outcome can redeem them.
     *      Each winning token pays `i_initialTokenValue` ETH (e.g. 0.01 ETH).
     *      Redeemed tokens are burned and the corresponding ETH is transferred to the user.
     * @param _amount The amount of winning tokens to redeem
     */
    function redeemWinningTokens(uint256 _amount) external predictionReported amountGreaterThanZero(_amount) notOwner {
        /// Checkpoint 9 ////

        // Check how many winning tokens the user currently holds
        uint256 userTokenBalance = s_winningToken.balanceOf(msg.sender);

        // Ensure the user has enough winning tokens to redeem
        if (userTokenBalance < _amount) {
            revert PredictionMarket__InsufficientWinningTokens();
        }

        // Calculate the ETH payout based on the fixed payout value per token
        uint256 ethToSend = (_amount * i_initialTokenValue) / PRECISION;

        // Reduce the tracked ETH collateral backing the market
        s_ethCollateral -= ethToSend;

        // Burn the redeemed winning tokens to prevent them from being used again
        s_winningToken.burn(msg.sender, _amount);

        // Transfer the corresponding ETH to the user
        (bool sent, ) = msg.sender.call{ value: ethToSend }("");
        if (!sent) {
            revert PredictionMarket__ETHTransferFailed();
        }

        // Emit event so off-chain systems can track redemptions
        emit WinningTokensRedeemed(msg.sender, _amount, ethToSend);
    }

    /**
     * @notice Calculate the total ETH price for buying tokens
     * @param _outcome The possible outcome (YES or NO) to buy tokens for
     * @param _tradingAmount The amount of tokens to buy
     * @return The total ETH price
     */
    function getBuyPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
        return _calculatePriceInEth(_outcome, _tradingAmount, false);
    }

    /**
     * @notice Calculate the total ETH price for selling tokens
     * @param _outcome The possible outcome (YES or NO) to sell tokens for
     * @param _tradingAmount The amount of tokens to sell
     * @return The total ETH price
     */
    function getSellPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
        return _calculatePriceInEth(_outcome, _tradingAmount, true);
    }

    /////////////////////////
    /// Helper Functions ///
    ////////////////////////

    /**
     * @dev Internal helper to calculate the ETH price for buying or selling outcome tokens.
     *
     *      The pricing model works by:
     *      1. Reading the current market state
     *      2. Simulating the market state after the trade
     *      3. Calculating the probability before and after the trade
     *      4. Using the average probability during the trade
     *      5. Converting that average probability into an ETH amount
     *
     *      In this model, the price of a token is:
     *      average probability during the trade × payout value
     *
     * @param _outcome The outcome being traded (YES or NO)
     * @param _tradingAmount The amount of outcome tokens being bought or sold
     * @param _isSelling Whether the trade is a sell or a buy
     *        false => buy
     *        true  => sell
     */
    function _calculatePriceInEth(
        Outcome _outcome,
        uint256 _tradingAmount,
        bool _isSelling
    ) private view returns (uint256) {
        /// Checkpoint 7 ////

        /*
            Get the current reserves for the selected outcome and for the opposite outcome.

            Example:
                YES reserve = 90
                NO reserve  = 90

            If _outcome == YES:
                currentTokenReserve      = YES reserve
                currentOtherTokenReserve = NO reserve

            If _outcome == NO, the order is reversed.

            These reserves represent the liquidity currently available in the contract and available for trading.
        */
        (uint256 currentTokenReserve, uint256 currentOtherTokenReserve) = _getCurrentReserves(_outcome);

        // When buying, the contract must have enough tokens available to sell.
        if (!_isSelling) {
            if (currentTokenReserve < _tradingAmount) {
                revert PredictionMarket__InsufficientLiquidity();
            }
        }

        // YES and NO tokens always have the same total supply.
        uint256 totalTokenSupply = i_yesToken.totalSupply();

        /*
            Compute how many tokens of each type have already been sold before the trade.

            Example:
                totalSupply = 100
                reserve     = 90

                sold = 100 - 90 = 10

            Meaning:
                10 tokens are currently held by traders, not by the contract.
        */
        uint256 currentTokenSoldBefore = totalTokenSupply - currentTokenReserve;
        uint256 currentOtherTokenSold = totalTokenSupply - currentOtherTokenReserve;

        /*
            Compute the total number of tokens sold before the trade.

            Example:
                YES sold = 10
                NO sold  = 10

                total sold = 20
        */
        uint256 totalTokensSoldBefore = currentTokenSoldBefore + currentOtherTokenSold;

        /*
            Compute the probability before the trade.

            The pricing model uses:
                probability = tokensSold / totalTokensSold

            Example:
                YES sold = 10
                total sold = 20

                P(YES) = 10 / 20 = 50%

            This represents the market-implied probability before the trade.
        */
        uint256 probabilityBefore = _calculateProbability(currentTokenSoldBefore, totalTokensSoldBefore);

        /*
            Simulate the reserve after the trade.

            If selling:
                tokens are returned to the pool
                reserve increases

            If buying:
                tokens leave the pool
                reserve decreases

            Example for buying 30 YES:
                reserve before = 90
                reserve after  = 60
        */
        uint256 currentTokenReserveAfter = _isSelling
            ? currentTokenReserve + _tradingAmount
            : currentTokenReserve - _tradingAmount;

        /*
            Recompute how many selected-outcome tokens are sold after the trade.

            Example:
                totalSupply = 100
                reserveAfter = 60

                soldAfter = 100 - 60 = 40
        */
        uint256 currentTokenSoldAfter = totalTokenSupply - currentTokenReserveAfter;

        /*
            Recompute the total number of tokens sold after the trade.

            If buying:
                more tokens are sold

            If selling:
                some sold tokens return to the pool

            Example:
                total sold before = 20
                buy 30
                total sold after = 50
        */
        uint256 totalTokensSoldAfter = _isSelling
            ? totalTokensSoldBefore - _tradingAmount
            : totalTokensSoldBefore + _tradingAmount;

        /*
            Compute the probability after the trade.

            Example:
                YES sold after = 40
                total sold after = 50

                P(YES) = 40 / 50 = 80%

            So the trade moves the probability from 50% to 80%.
        */
        uint256 probabilityAfter = _calculateProbability(currentTokenSoldAfter, totalTokensSoldAfter);

        /*
            Use the average probability during the trade.

            This is needed because the user does not buy or sell all tokens
            at a single fixed price. The probability changes during the trade,
            so the contract approximates the cost using the average of the
            probability before and after the trade.

            Example:
                probBefore = 50%
                probAfter  = 80%

                probAvg = 65%
        */
        uint256 probabilityAvg = (probabilityBefore + probabilityAfter) / 2;

        /*
            Convert the average probability into an ETH price.

            Formula:
                price = payoutValue × averageProbability × tokenAmount

            Example:
                payout per token = 0.01 ETH
                probabilityAvg   = 65%
                tokens           = 30

                price = 0.01 × 0.65 × 30 = 0.195 ETH

            The division by PRECISION is required because probabilities and
            token amounts are handled using fixed-point arithmetic.
        */
        return (i_initialTokenValue * probabilityAvg * _tradingAmount) / (PRECISION * PRECISION);
    }

    /**
     * @dev Internal helper to get the current reserves for the selected outcome
     *      and its opposite outcome.
     *      These reserves represent the liquidity currently available in the contract and available for trading.
     * @param _outcome The outcome to use as the primary reserve (YES or NO)
     * @return outcomeReserve The reserve of the selected outcome token
     * @return oppositeReserve The reserve of the opposite outcome token
     */
    function _getCurrentReserves(Outcome _outcome) private view returns (uint256, uint256) {
        /// Checkpoint 7 ////
        uint256 yesTokenBalance = i_yesToken.balanceOf(address(this));
        uint256 noTokenBalance = i_noToken.balanceOf(address(this));
        if (_outcome == Outcome.YES) {
            return (yesTokenBalance, noTokenBalance);
        }
        return (noTokenBalance, yesTokenBalance);
    }

    /**
     * @dev Internal helper to calculate the probability of the tokens
     * @param tokensSold The number of tokens sold
     * @param totalSold The total number of tokens sold
     * @return The probability of the tokens
     */
    function _calculateProbability(uint256 tokensSold, uint256 totalSold) private pure returns (uint256) {
        /// Checkpoint 7 ////
        return (tokensSold * PRECISION) / totalSold;
    }

    /////////////////////////
    /// Getter Functions ///
    ////////////////////////

    /**
     * @notice Get the prediction details
     */
    function getPrediction()
        external
        view
        returns (
            string memory question,
            string memory outcome1,
            string memory outcome2,
            address oracle,
            uint256 initialTokenValue,
            uint256 yesTokenReserve,
            uint256 noTokenReserve,
            bool isReported,
            address yesToken,
            address noToken,
            address winningToken,
            uint256 ethCollateral,
            uint256 lpTradingRevenue,
            address predictionMarketOwner,
            uint256 initialProbability,
            uint256 percentageLocked
        )
    {
        /// Checkpoint 3 ////
        oracle = i_oracle;
        initialTokenValue = i_initialTokenValue;
        percentageLocked = i_percentageLocked;
        initialProbability = i_initialYesProbability;
        question = s_question;
        ethCollateral = s_ethCollateral;
        lpTradingRevenue = s_lpTradingRevenue;
        predictionMarketOwner = owner();
        yesToken = address(i_yesToken);
        noToken = address(i_noToken);
        outcome1 = i_yesToken.name();
        outcome2 = i_noToken.name();
        yesTokenReserve = i_yesToken.balanceOf(address(this));
        noTokenReserve = i_noToken.balanceOf(address(this));
        /// Checkpoint 5 ////
        isReported = s_isReported;
        winningToken = address(s_winningToken);
    }
}

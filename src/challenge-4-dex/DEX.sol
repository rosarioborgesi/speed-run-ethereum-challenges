// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DEX Template
 * @author stevepham.eth and m00npapi.eth
 * @notice Empty DEX.sol that just outlines what features could be part of the challenge (up to you!)
 * @dev We want to create an automatic market where our contract will hold reserves of both ETH and 🎈 Balloons. These reserves will provide liquidity that allows anyone to swap between the assets.
 * NOTE: functions outlined here are what work with the front end of this challenge. Also return variable names need to be specified exactly may be referenced (It may be helpful to cross reference with front-end code function calls).
 */
contract DEX {
    /* ========== ERRORS ========== */
    error DexAlreadyInitialized(uint256 liquidity);
    error InvalidEthAmount();
    error InsufficientTokenBalance(uint256 requested, uint256 available);
    error EthTransferFailed(address from, address to, uint256 amount);
    error TokenTransferFailed(address from, address to, uint256 amount);
    error InvalidTokenAmount();
    error InsufficientAllowance(address user, uint256 requested, uint256 available);
    error InsufficientLiquidity(address user, uint256 requested, uint256 available);

    /* ========== GLOBAL VARIABLES ========== */
    /// @notice Total supply of LP shares minted by this DEX.
    /// @dev Think of LP tokens as “shares” of the pool. `totalLiquidity` is the denominator:
    ///      - a provider’s ownership fraction is approximately `liquidity[provider] / totalLiquidity`.
    ///      - when users add liquidity, `totalLiquidity` increases (mint).
    ///      - when users withdraw liquidity, `totalLiquidity` decreases (burn).
    ///      This contract does not use an ERC20 LP token; it tracks shares internally via this variable.
    uint256 public totalLiquidity;
    /// @notice LP share balance per liquidity provider.
    /// @dev `liquidity[lp]` is how many LP shares `lp` owns (their claim on the pool).
    ///      It increases on `init()` / `deposit()` and decreases on `withdraw()`.
    ///      A provider’s withdrawable amounts are proportional to their share of the pool:
    ///        ethOut   ≈ ethReserve   * liquidity[lp] / totalLiquidity
    ///        tokenOut ≈ tokenReserve * liquidity[lp] / totalLiquidity
    ///      Note: this mapping is the “LP ledger”. Shares are not transferable because it’s not an ERC20.
    mapping(address => uint256) public liquidity;

    IERC20 token; //instantiates the imported contract

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when ethToToken() swap transacted
     */
    event EthToTokenSwap(address swapper, uint256 tokenOutput, uint256 ethInput);

    /**
     * @notice Emitted when tokenToEth() swap transacted
     */
    event TokenToEthSwap(address swapper, uint256 tokensInput, uint256 ethOutput);

    /**
     * @notice Emitted when liquidity provided to DEX and mints LPTs.
     */
    event LiquidityProvided(address liquidityProvider, uint256 liquidityMinted, uint256 ethInput, uint256 tokensInput);

    /**
     * @notice Emitted when liquidity removed from DEX and decreases LPT count within DEX.
     */
    event LiquidityRemoved(
        address liquidityRemover,
        uint256 liquidityWithdrawn,
        uint256 tokensOutput,
        uint256 ethOutput
    );

    /* ========== CONSTRUCTOR ========== */

    constructor(address tokenAddr) {
        token = IERC20(tokenAddr); //specifies the token address that will hook into the interface and be used through the variable 'token'
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice initializes amount of tokens that will be transferred to the DEX itself from the erc20 contract mintee (and only them based on how Balloons.sol is written). Loads contract up with both ETH and Balloons.
     * @param tokens amount to be transferred to DEX
     * @return totalLiquidity is the number of LPTs minting as a result of deposits made to DEX contract
     * NOTE: since ratio is 1:1, this is fine to initialize the totalLiquidity (wrt to balloons) as equal to eth balance of contract.
     */
    function init(uint256 tokens) public payable returns (uint256) {
        if (totalLiquidity > 0) {
            revert DexAlreadyInitialized(totalLiquidity);
        }
        totalLiquidity = msg.value;
        liquidity[msg.sender] = totalLiquidity;
        bool success = token.transferFrom(msg.sender, address(this), tokens);
        if (!success) {
            revert TokenTransferFailed(msg.sender, address(this), tokens);
        }
        return totalLiquidity;
    }

    /**
     * @notice Returns yOutput (Δy), the amount of Y you get out for an input of X (Δx),
     *         given reserves xReserves (x) and yReserves (y), using the constant-product AMM formula.
     * @dev Derivation:
     *      (x + Δx)(y - Δy) = k  with k = x*y
     *      => Δy = y - k/(x + Δx)
     *      => Δy = (y * Δx) / (x + Δx)
     *
     *      Fee: 0.3% (Uniswap V2 style), so only 99.7% of Δx is effectively added:
     *      Δx_eff = Δx * 0.997 = Δx * 997/1000
     *
     *      To avoid decimals and reduce precision loss, we keep values scaled by 1000:
     *      Δy = (y * (Δx * 997)) / (x * 1000 + (Δx * 997))
     */
    function price(uint256 xInput, uint256 xReserves, uint256 yReserves) public pure returns (uint256 yOutput) {
        // Δx * 997 (still scaled by 1000; we divide implicitly via the denominator)
        uint256 xInputWithFee = xInput * 997;

        // numerator   = y * (Δx * 997)
        uint256 numerator = yReserves * xInputWithFee;

        // denominator = x*1000 + (Δx * 997)
        uint256 denominator = xReserves * 1000 + xInputWithFee;

        // integer division rounds down (like Uniswap V2)
        yOutput = numerator / denominator;
    }

    /**
     * @notice returns liquidity for a user.
     * NOTE: this is not needed typically due to the `liquidity()` mapping variable being public and having a getter as a result. This is left though as it is used within the front end code (App.jsx).
     * NOTE: if you are using a mapping liquidity, then you can use `return liquidity[lp]` to get the liquidity for a user.
     * NOTE: if you will be submitting the challenge make sure to implement this function as it is used in the tests.
     */
    function getLiquidity(address lp) public view returns (uint256) {
        return liquidity[lp];
    }

    /**
     * @notice sends Ether to DEX in exchange for $BAL
     */
    function ethToToken() public payable returns (uint256 tokenOutput) {
        if (msg.value == 0) {
            revert InvalidEthAmount();
        }
        // pre-swap ETH reserve
        uint256 ethReserve = address(this).balance - msg.value;
        uint256 tokenReserve = token.balanceOf(address(this));

        tokenOutput = price(msg.value, ethReserve, tokenReserve);

        bool success = token.transfer(msg.sender, tokenOutput);
        if (!success) {
            revert TokenTransferFailed(address(this), msg.sender, msg.value);
        }

        emit EthToTokenSwap(msg.sender, tokenOutput, msg.value);
        return tokenOutput;
    }

    /**
     * @notice sends $BAL tokens to DEX in exchange for Ether
     */
    function tokenToEth(uint256 tokenInput) public returns (uint256 ethOutput) {
        if (tokenInput == 0) {
            revert InvalidTokenAmount();
        }

        uint256 userTokenBalance = token.balanceOf(msg.sender);
        if (userTokenBalance < tokenInput) {
            revert InsufficientTokenBalance(tokenInput, userTokenBalance);
        }

        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < tokenInput) {
            revert InsufficientAllowance(msg.sender, tokenInput, allowance);
        }

        uint256 ethReserve = address(this).balance;
        uint256 tokenReserve = token.balanceOf(address(this));

        ethOutput = price(tokenInput, tokenReserve, ethReserve);

        bool sent = token.transferFrom(msg.sender, address(this), tokenInput);
        if (!sent) {
            revert TokenTransferFailed(msg.sender, address(this), tokenInput);
        }

        (bool success, ) = msg.sender.call{ value: ethOutput }("");
        if (!success) {
            revert EthTransferFailed(address(this), msg.sender, ethOutput);
        }
        emit TokenToEthSwap(msg.sender, tokenInput, ethOutput);
        return ethOutput;
    }

    /**
     * @notice Add liquidity to the pool by depositing ETH (via msg.value) and the matching amount of $BAL.
     *
     * How it works:
     * - You send ETH with the call (msg.value).
     * - The contract computes how many $BAL you must add to keep the pool price unchanged
     *   (i.e., preserve the current reserve ratio).
     * - LP “shares” (liquidity tokens) are minted proportional to your ETH contribution.
     *
     * Requirements:
     * - msg.value must be > 0.
     * - You must have enough $BAL in your wallet.
     * - You must approve the DEX to spend your $BAL before calling deposit().
     *
     * Rounding:
     * - When calculating the required token deposit, we round UP (+1) so the depositor never underpays
     *   due to Solidity integer division.
     * - When minting LP shares, we round DOWN (no +1) to avoid over-minting and diluting existing LPs.
     */
    function deposit() public payable returns (uint256 tokensDeposited) {
        if (msg.value == 0) revert InvalidEthAmount();

        // Reserves *before* this deposit. (address(this).balance already includes msg.value)
        uint256 ethReserve = address(this).balance - msg.value;
        uint256 tokenReserve = token.balanceOf(address(this));

        /**
         * Compute how many tokens the user must deposit to keep the price unchanged.
         *
         * We want to preserve the reserve ratio:
         *   tokensDeposited / ethDeposited = tokenReserve / ethReserve
         *
         * => tokensDeposited = ethDeposited * tokenReserve / ethReserve
         *
         * Solidity rounds DOWN on division; rounding down would let users deposit slightly too few tokens.
         * We add +1 to effectively round UP by 1 wei and protect the pool / existing LPs.
         */
        tokensDeposited = (msg.value * tokenReserve) / ethReserve + 1;

        uint256 userTokenBalance = token.balanceOf(msg.sender);
        if (tokensDeposited > userTokenBalance) {
            revert InsufficientTokenBalance(tokensDeposited, userTokenBalance);
        }

        uint256 allowance = token.allowance(msg.sender, address(this));
        if (allowance < tokensDeposited) {
            revert InsufficientAllowance(msg.sender, tokensDeposited, allowance);
        }

        /**
         * Mint LP shares proportional to the ETH added.
         *
         * LP tokens represent “shares” of the pool. We want the depositor to receive the same fraction
         * of LP supply as the fraction of ETH they contribute:
         *
         *   liquidityMinted / totalLiquidity = ethDeposited / ethReserve
         *
         * => liquidityMinted = ethDeposited * totalLiquidity / ethReserve
         *
         * No +1 here: rounding UP would over-mint LP shares and dilute existing LPs.
         * Rounding DOWN is the conservative choice.
         */
        uint256 liquidityMinted = (msg.value * totalLiquidity) / ethReserve;

        liquidity[msg.sender] += liquidityMinted;
        totalLiquidity += liquidityMinted;

        bool sent = token.transferFrom(msg.sender, address(this), tokensDeposited);
        if (!sent) revert TokenTransferFailed(msg.sender, address(this), tokensDeposited);

        emit LiquidityProvided(msg.sender, liquidityMinted, msg.value, tokensDeposited);
        return tokensDeposited;
    }

    /**
     * @notice Withdraw liquidity from the pool by burning LP shares.
     *
     * The caller specifies how many LP shares (`amount`) they want to burn.
     * In return, they receive their proportional share of the pool’s ETH and $BAL
     * at the current reserves.
     *
     * Important:
     * - `amount` is measured in LP shares (not ETH, not tokens).
     * - The ETH and token amounts received depend on the current pool state
     *   (swaps, fees, and arbitrage may have changed reserves since deposit).
     */
    function withdraw(uint256 amount) public returns (uint256 ethAmount, uint256 tokenAmount) {
        // LP shares owned by the caller
        uint256 userLiquidity = liquidity[msg.sender];

        // User must burn no more LP shares than they own
        if (userLiquidity < amount) {
            revert InsufficientLiquidity(msg.sender, amount, userLiquidity);
        }

        // Current pool reserves
        uint256 ethReserve = address(this).balance;
        uint256 tokenReserve = token.balanceOf(address(this));

        /**
         * Compute withdrawable amounts proportionally.
         *
         * LP shares represent a fraction of the pool:
         *   share = amount / totalLiquidity
         *
         * The user receives that same fraction of each reserve.
         * Asset amounts are derived from shares; shares themselves do not change in value.
         */
        ethAmount = (amount * ethReserve) / totalLiquidity;
        tokenAmount = (amount * tokenReserve) / totalLiquidity;

        /**
         * Burn LP shares.
         *
         * LP shares must be burned in the same unit they were minted.
         * ETH and token values fluctuate over time, but LP share accounting remains stable.
         */
        liquidity[msg.sender] -= amount;
        totalLiquidity -= amount;

        // Transfer ETH to the user
        (bool success, ) = payable(msg.sender).call{ value: ethAmount }("");
        if (!success) {
            revert EthTransferFailed(address(this), msg.sender, ethAmount);
        }

        // Transfer tokens to the user
        bool sent = token.transfer(msg.sender, tokenAmount);
        if (!sent) {
            revert TokenTransferFailed(address(this), msg.sender, tokenAmount);
        }

        emit LiquidityRemoved(msg.sender, amount, tokenAmount, ethAmount);
        return (ethAmount, tokenAmount);
    }
}

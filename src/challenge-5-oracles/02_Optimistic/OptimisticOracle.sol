// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

contract OptimisticOracle {
    ////////////////
    /// Enums //////
    ////////////////

    enum State {
        Invalid,
        Asserted,
        Proposed,
        Disputed,
        Settled,
        Expired
    }

    /////////////////
    /// Errors //////
    /////////////////

    error AssertionNotFound();
    error AssertionProposed();
    error InvalidValue();
    error InvalidTime();
    error ProposalDisputed();
    error NotProposedAssertion();
    error AlreadyClaimed();
    error AlreadySettled();
    error AwaitingDecider();
    error NotDisputedAssertion();
    error OnlyDecider();
    error OnlyOwner();
    error TransferFailed();

    //////////////////////
    /// State Variables //
    //////////////////////

    struct EventAssertion {
        address asserter;
        address proposer;
        address disputer;
        bool proposedOutcome;
        bool resolvedOutcome;
        uint256 reward;
        uint256 bond;
        uint256 startTime;
        uint256 endTime;
        bool claimed;
        address winner;
        string description;
    }

    uint256 public constant MINIMUM_ASSERTION_WINDOW = 3 minutes;
    uint256 public constant DISPUTE_WINDOW = 3 minutes;
    address public decider;
    address public owner;
    uint256 public nextAssertionId = 1;
    mapping(uint256 => EventAssertion) public assertions;

    ////////////////
    /// Events /////
    ////////////////

    event EventAsserted(uint256 assertionId, address asserter, string description, uint256 reward);
    event OutcomeProposed(uint256 assertionId, address proposer, bool outcome);
    event OutcomeDisputed(uint256 assertionId, address disputer);
    event AssertionSettled(uint256 assertionId, bool outcome, address winner);
    event DeciderUpdated(address oldDecider, address newDecider);
    event RewardClaimed(uint256 assertionId, address winner, uint256 amount);
    event RefundClaimed(uint256 assertionId, address asserter, uint256 amount);

    ///////////////////
    /// Modifiers /////
    ///////////////////

    /**
     * @notice Modifier to restrict function access to the designated decider
     * @dev Ensures only the decider can settle disputed assertions
     */
    modifier onlyDecider() {
        if (msg.sender != decider) revert OnlyDecider();
        _;
    }

    /**
     * @notice Modifier to restrict function access to the contract owner
     * @dev Ensures only the owner can update critical contract parameters
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    ///////////////////
    /// Constructor ///
    ///////////////////

    constructor(address _decider) {
        decider = _decider;
        owner = msg.sender;
    }

    ///////////////////
    /// Functions /////
    ///////////////////

    /**
     * @notice Updates the decider address (only contract owner)
     * @dev Changes the address authorized to settle disputed assertions.
     *      Emits DeciderUpdated event with old and new addresses.
     * @param _decider The new address that will act as decider for disputed assertions
     */
    function setDecider(address _decider) external onlyOwner {
        address oldDecider = address(decider);
        decider = _decider;
        emit DeciderUpdated(oldDecider, _decider);
    }

    /**
     * @notice Returns the complete assertion details for a given assertion ID
     * @dev Provides access to all fields of the EventAssertion struct
     * @param assertionId The unique identifier of the assertion to retrieve
     * @return The complete EventAssertion struct containing all assertion data
     */
    function getAssertion(uint256 assertionId) external view returns (EventAssertion memory) {
        return assertions[assertionId];
    }

    /**
     * @notice Creates a new assertion about an event with a true/false outcome
     * @dev Requires ETH payment as reward for correct proposers. Bond requirement is 2x the reward.
     *      Sets default timestamps if not provided. Validates timing requirements.
     * @param description Human-readable description of the event (e.g. "Did X happen by time Y?")
     * @param startTime When proposals can begin (0 for current block timestamp)
     * @param endTime When the assertion expires (0 for startTime + minimum window)
     * @return The unique assertion ID for the newly created assertion
     */
    function assertEvent(
        string memory description,
        uint256 startTime,
        uint256 endTime
    ) external payable returns (uint256) {
        if (msg.value == 0) {
            revert InvalidValue();
        }

        // Set default times if not provided
        if (startTime == 0) {
            startTime = block.timestamp;
        }
        if (endTime == 0) {
            endTime = startTime + MINIMUM_ASSERTION_WINDOW;
        }

        if (startTime < block.timestamp) {
            revert InvalidTime();
        }
        if (endTime < MINIMUM_ASSERTION_WINDOW + startTime) {
            revert InvalidTime();
        }

        uint256 assertionId = nextAssertionId;
        nextAssertionId++;

        assertions[assertionId] = EventAssertion({
            asserter: msg.sender,
            proposer: address(0),
            disputer: address(0),
            proposedOutcome: false,
            resolvedOutcome: false,
            reward: msg.value,
            bond: 2 * msg.value,
            startTime: startTime,
            endTime: endTime,
            claimed: false,
            winner: address(0),
            description: description
        });

        emit EventAsserted(assertionId, msg.sender, description, msg.value);
        return assertionId;
    }

    /**
     * @notice Proposes the outcome (true or false) for an asserted event
     * @dev Requires bonding ETH equal to 2x the original reward. Sets dispute window deadline.
     *      Can only be called once per assertion and within the assertion time window.
     * @param assertionId The unique identifier of the assertion to propose an outcome for
     * @param outcome The proposed boolean outcome (true or false) for the event
     */
    function proposeOutcome(uint256 assertionId, bool outcome) external payable {
        EventAssertion storage assertion = assertions[assertionId];

        // Check that the assertion exists
        if (assertion.asserter == address(0)) {
            revert AssertionNotFound();
        }
        // Check that the assertion hasn't been proposed yet
        if (assertion.proposer != address(0)) {
            revert AssertionProposed();
        }

        // Validate the timing constraints
        if (block.timestamp < assertion.startTime || block.timestamp > assertion.endTime) {
            revert InvalidTime();
        }

        // Enforce the correct bond amount
        if (msg.value != assertion.bond) {
            revert InvalidValue();
        }

        // Update the assertion with the proposal
        assertion.endTime = block.timestamp + DISPUTE_WINDOW;
        assertion.proposer = msg.sender;
        assertion.proposedOutcome = outcome;

        emit OutcomeProposed(assertionId, msg.sender, outcome);
    }

    /**
     * @notice Disputes a proposed outcome by bonding ETH
     * @dev Requires bonding ETH equal to the bond amount. Can only dispute once per assertion
     *      and must be within the dispute window after proposal.
     * @param assertionId The unique identifier of the assertion to dispute
     */
    function disputeOutcome(uint256 assertionId) external payable {
        EventAssertion storage assertion = assertions[assertionId];

        // Check that the proposal exists
        if (assertion.proposer == address(0)) {
            revert NotProposedAssertion();
        }

        // Check that the proposal has not been disputed yet
        if (assertion.disputer != address(0)) {
            revert ProposalDisputed();
        }

        // Validate the timing constraints
        if (block.timestamp > assertion.endTime) {
            revert InvalidTime();
        }

        // Require the correct bond amount
        if (msg.value != assertion.bond) {
            revert InvalidValue();
        }

        // Record the disputer
        assertion.disputer = msg.sender;

        emit OutcomeDisputed(assertionId, msg.sender);
    }

    /**
     * @notice Claims reward for undisputed assertions after dispute window expires
     * @dev Anyone can trigger this function. Transfers reward + bond to the proposer.
     *      Can only be called after dispute window has passed without disputes.
     * @param assertionId The unique identifier of the assertion to claim rewards for
     */
    function claimUndisputedReward(uint256 assertionId) external {
        EventAssertion storage assertion = assertions[assertionId];

        address proposer = assertion.proposer;
        // Check that the proposal exists
        if (proposer == address(0)) {
            revert NotProposedAssertion();
        }

        // Check that no dispute has been raised
        if (assertion.disputer != address(0)) {
            revert ProposalDisputed();
        }

        if (block.timestamp <= assertion.endTime) {
            revert InvalidTime();
        }

        if (assertion.claimed) {
            revert AlreadyClaimed();
        }

        // To avoid re-entrancy
        assertion.claimed = true;
        assertion.resolvedOutcome = assertion.proposedOutcome;
        assertion.winner = proposer;

        uint256 totalReward = assertion.reward + assertion.bond;
        (bool success, ) = payable(proposer).call{ value: totalReward }("");
        if (!success) {
            revert TransferFailed();
        }
        emit RewardClaimed(assertionId, proposer, totalReward);
    }

    /**
     * @notice Claims reward for disputed assertions after decider settlement
     * @dev Anyone can trigger this function. Pays decider fee and transfers remaining rewards to winner.
     *      Can only be called after decider has settled the dispute.
     * @param assertionId The unique identifier of the disputed assertion to claim rewards for
     */
    function claimDisputedReward(uint256 assertionId) external {
        EventAssertion storage assertion = assertions[assertionId];

        // Check that the proposal exists
        if (assertion.proposer == address(0)) {
            revert NotProposedAssertion();
        }

        // Check that a dispute exists
        if (assertion.disputer == address(0)) {
            revert NotDisputedAssertion();
        }

        // The decider has set a winner
        if (assertion.winner == address(0)) {
            revert AwaitingDecider();
        }

        if (assertion.claimed) {
            revert AlreadyClaimed();
        }
        // To avoid re-entrancy
        assertion.claimed = true;

        uint256 bond = assertion.bond;
        (bool deciderSuccess, ) = payable(decider).call{ value: bond }("");
        if (!deciderSuccess) {
            revert TransferFailed();
        }

        address winner = assertion.winner;
        uint256 winnerReward = bond + assertion.reward;
        (bool winnerSuccess, ) = payable(winner).call{ value: winnerReward }("");
        if (!winnerSuccess) {
            revert TransferFailed();
        }
        emit RewardClaimed(assertionId, winner, winnerReward);
    }

    /**
     * @notice Claims refund for assertions that receive no proposals before deadline
     * @dev Anyone can trigger this function. Returns the original reward to the asserter.
     *      Can only be called after assertion deadline has passed without any proposals.
     * @param assertionId The unique identifier of the expired assertion to claim refund for
     */
    function claimRefund(uint256 assertionId) external {
        EventAssertion storage assertion = assertions[assertionId];

        // Check that the proposal exists
        if (assertion.proposer != address(0)) {
            revert AssertionProposed();
        }

        if (block.timestamp <= assertion.endTime) {
            revert InvalidTime();
        }

        if (assertion.claimed) {
            revert AlreadyClaimed();
        }

        // To avoid re-entrancy
        assertion.claimed = true;

        address asserter = assertion.asserter;
        uint256 reward = assertion.reward;
        (bool success, ) = payable(asserter).call{ value: reward }("");
        if (!success) {
            revert TransferFailed();
        }
        emit RefundClaimed(assertionId, asserter, reward);
    }

    /**
     * @notice Resolves disputed assertions by determining the correct outcome (only decider)
     * @dev Sets the resolved outcome and determines winner based on proposal accuracy.
     * @param assertionId The unique identifier of the disputed assertion to settle
     * @param resolvedOutcome The decider's determination of the true outcome
     */
    function settleAssertion(uint256 assertionId, bool resolvedOutcome) external onlyDecider {
        EventAssertion storage assertion = assertions[assertionId];

        // Check that the proposal exists
        if (assertion.proposer == address(0)) {
            revert NotProposedAssertion();
        }

        if (assertion.disputer == address(0)) {
            revert NotDisputedAssertion();
        }

        if (assertion.winner != address(0)) {
            revert AlreadySettled();
        }

        assertion.resolvedOutcome = resolvedOutcome;

        assertion.winner = (resolvedOutcome == assertion.proposedOutcome) ? assertion.proposer : assertion.disputer;

        emit AssertionSettled(assertionId, resolvedOutcome, assertion.winner);
    }

    /**
     * @notice Returns the current state of an assertion based on its lifecycle stage
     * @dev Evaluates assertion progress through states: Invalid, Asserted, Proposed, Disputed, Settled, Expired
     * @param assertionId The unique identifier of the assertion to check state for
     * @return The current State enum value representing the assertion's status
     */
    function getState(uint256 assertionId) external view returns (State) {
        EventAssertion storage assertion = assertions[assertionId];

        if (assertion.asserter == address(0)) {
            return State.Invalid;
        }

        // If there's a winner, it's settled
        if (assertion.winner != address(0)) {
            return State.Settled;
        }

        // If there's a dispute, it's disputed
        if (assertion.disputer != address(0)) {
            return State.Disputed;
        }

        // If no proposal yet, check if deadline has passed
        if (assertion.proposer == address(0)) {
            if (block.timestamp > assertion.endTime) {
                return State.Expired;
            }
            return State.Asserted;
        }

        // If no dispute and deadline passed, it's settled (can be claimed)
        if (block.timestamp > assertion.endTime) {
            return State.Settled;
        }

        // Otherwise it's proposed
        return State.Proposed;
    }

    /**
     * @notice Returns the final resolved outcome of a settled assertion
     * @dev For undisputed assertions, returns the proposed outcome after dispute window.
     *      For disputed assertions, returns the decider's resolved outcome.
     * @param assertionId The unique identifier of the assertion to get resolution for
     * @return The final boolean outcome of the assertion
     */
    function getResolution(uint256 assertionId) external view returns (bool) {
        EventAssertion storage assertion = assertions[assertionId];

        if (assertion.asserter == address(0)) {
            revert AssertionNotFound();
        }

        if (assertion.proposer == address(0)) {
            revert NotProposedAssertion();
        }

        if (assertion.disputer == address(0)) {
            if (block.timestamp <= assertion.endTime) {
                revert InvalidTime();
            }
            return assertion.proposedOutcome;
        } else {
            if (assertion.winner == address(0)) {
                revert AwaitingDecider();
            }
            return assertion.resolvedOutcome;
        }
    }
}

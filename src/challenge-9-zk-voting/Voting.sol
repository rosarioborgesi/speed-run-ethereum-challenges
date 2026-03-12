//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import { LeanIMT, LeanIMTData } from "@zk-kit/lean-imt.sol/LeanIMT.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
/// Checkpoint 6 //////
import { IVerifier } from "./Verifier.sol";

contract Voting is Ownable {
    using LeanIMT for LeanIMTData;

    //////////////////
    /// Errors //////
    /////////////////

    error Voting__CommitmentAlreadyAdded(uint256 commitment);
    error Voting__NullifierHashAlreadyUsed(bytes32 nullifierHash);
    error Voting__InvalidProof();
    error Voting__NotAllowedToVote();
    error Voting__EmptyTree();
    error Voting__InvalidRoot();

    ///////////////////////
    /// State Variables ///
    ///////////////////////

    // The question being voted on (e.g., "Should we upgrade the protocol?")
    string private s_question;

    // Mapping of allowlisted addresses.
    // Only addresses marked as true are allowed to register and participate in the vote.
    mapping(address => bool) private s_voters;

    // Counter for the number of YES votes submitted.
    uint256 private s_yesVotes;

    // Counter for the number of NO votes submitted.
    uint256 private s_noVotes;

    /// Checkpoint 2 //////

    // Tracks whether an allowlisted address has already registered a commitment.
    // Prevents the same address from registering multiple times.
    mapping(address => bool) private s_hasRegistered;

    // Tracks whether a commitment has already been inserted into the Merkle tree.
    // Ensures each commitment is unique and prevents duplicates.
    mapping(uint256 => bool) private s_commitments;

    // Incremental Merkle Tree storing all voter commitments.
    // This tree is used later in the zero-knowledge proof to prove
    // that a voter is part of the registered set without revealing which one.
    LeanIMTData private s_tree;

    /// Checkpoint 6 //////
    IVerifier private immutable i_verifier;
    mapping(bytes32 => bool) private s_nullifierHashes;

    //////////////
    /// Events ///
    //////////////

    event VoterAdded(address indexed voter);
    event NewLeaf(uint256 index, uint256 value);
    event VoteCast(
        bytes32 indexed nullifierHash,
        address indexed voter,
        bool vote,
        uint256 timestamp,
        uint256 totalYes,
        uint256 totalNo
    );

    //////////////////
    ////Constructor///
    //////////////////

    constructor(address _owner, address _verifier, string memory _question) Ownable(_owner) {
        s_question = _question;
        /// Checkpoint 6 //////
        i_verifier = IVerifier(_verifier);
    }

    //////////////////
    /// Functions ///
    //////////////////

    /**
     * @notice Batch updates the allowlist of voter EOAs
     * @dev Only the contract owner can call this function. Emits `VoterAdded` for each updated entry.
     * @param voters Addresses to update in the allowlist
     * @param statuses True to allow, false to revoke
     */
    function addVoters(address[] calldata voters, bool[] calldata statuses) public onlyOwner {
        require(voters.length == statuses.length, "Voters and statuses length mismatch");

        for (uint256 i = 0; i < voters.length; i++) {
            s_voters[voters[i]] = statuses[i];
            emit VoterAdded(voters[i]);
        }
    }

    /**
     * @notice Registers a commitment leaf for an allowlisted address
     * @dev A given allowlisted address can register exactly once.
     *      Reverts if the caller is not allowlisted, already registered,
     *      or if the same commitment was already inserted.
     *      Emits `NewLeaf` when the commitment is added to the Merkle tree.
     *
     *      What is a commitment?
     *      Think of it as the user's anonymous identity in the voting system.
     *
     *      Each voter creates:
     *      - a nullifier (used later to prevent double voting)
     *      - a secret (a private value only they know)
     *
     *      These two values are hashed together:
     *          commitment = hash(nullifier, secret)
     *
     *      The commitment is the only thing stored on-chain and becomes
     *      a leaf in the Merkle tree of registered voters.
     *
     *      Later the voter proves in zero-knowledge that their commitment
     *      is in this tree, without revealing their identity.
     *
     * @param _commitment The Poseidon-based commitment to insert into the IMT
     */
    function register(uint256 _commitment) public {
        /// Checkpoint 2 //////

        // Ensure the caller is allowed to vote AND has not already registered.
        // s_voters[msg.sender] -> true if the address is allowlisted
        // s_hasRegistered[msg.sender] -> prevents the same address from registering twice
        if (!s_voters[msg.sender] || s_hasRegistered[msg.sender]) {
            revert Voting__NotAllowedToVote();
        }

        // Prevent inserting the same commitment twice.
        // This ensures each commitment (derived from a secret) is unique in the system.
        if (s_commitments[_commitment]) {
            revert Voting__CommitmentAlreadyAdded(_commitment);
        }

        // Mark this commitment as used so it cannot be registered again.
        s_commitments[_commitment] = true;

        // Mark that this address has completed the registration step.
        // This prevents the same address from registering multiple commitments.
        s_hasRegistered[msg.sender] = true;

        // Insert the commitment into the Merkle tree.
        // This tree stores all voter commitments and will later be used
        // in the zero-knowledge proof to prove membership anonymously.
        s_tree.insert(_commitment);

        // Emit the index of the new leaf and the commitment value.
        // Off-chain systems use this event to track tree updates and compute Merkle proofs.
        emit NewLeaf(s_tree.size - 1, _commitment);
    }

    /**
     * @notice Casts a vote using a zero-knowledge proof
     * @dev Enforces one-time voting through `s_nullifierHashes`.
     *      The order of `publicInputs` must exactly match the order expected
     *      by the verifier circuit. The `_vote` value is interpreted as:
     *      1 => yes, anything else => no.
     * @param _proof UltraHonk proof bytes
     * @param _nullifierHash Public nullifier hash used to prevent double voting
     * @param _root Merkle root of the registered commitments tree
     * @param _vote Encoded vote value
     * @param _depth Tree depth used in the circuit
     */
    function vote(bytes memory _proof, bytes32 _nullifierHash, bytes32 _root, bytes32 _vote, bytes32 _depth) public {
        /// Checkpoint 6 //////

        // Prevent voting before any commitment has been registered.
        // An empty root means the registration tree has not been initialized.
        if (_root == bytes32(0)) {
            revert Voting__EmptyTree();
        }

        // Ensure the submitted root matches the current on-chain Merkle root.
        // This binds the proof to the real voter registration tree.
        if (uint256(_root) != s_tree.root()) {
            revert Voting__InvalidRoot();
        }

        // Build the array of public inputs expected by the verifier.
        // Their order must exactly match the order defined in the circuit.
        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = _nullifierHash;
        publicInputs[1] = _root;
        publicInputs[2] = _vote;
        publicInputs[3] = _depth;

        // Verify the zero-knowledge proof.
        // If valid, the proof shows that the voter is registered in the tree
        // and knows the private inputs required by the circuit.
        if (!i_verifier.verify(_proof, publicInputs)) {
            revert Voting__InvalidProof();
        }

        // Reject reused nullifier hashes.
        // This prevents the same voter from using the same identity proof twice.
        if (s_nullifierHashes[_nullifierHash]) {
            revert Voting__NullifierHashAlreadyUsed(_nullifierHash);
        }

        // Mark the nullifier hash as used before counting the vote.
        s_nullifierHashes[_nullifierHash] = true;

        // Count the vote:
        // bytes32(1) => yes
        // any other value => no
        if (_vote == bytes32(uint256(1))) {
            s_yesVotes++;
        } else {
            s_noVotes++;
        }

        // Emit the vote result and updated counters.
        emit VoteCast(_nullifierHash, msg.sender, _vote == bytes32(uint256(1)), block.timestamp, s_yesVotes, s_noVotes);
    }

    /////////////////////////
    /// Getter Functions ///
    ////////////////////////

    function getVotingData()
        public
        view
        returns (
            string memory question,
            address contractOwner,
            uint256 yesVotes,
            uint256 noVotes,
            uint256 size,
            uint256 depth,
            uint256 root
        )
    {
        question = s_question;
        contractOwner = owner();
        yesVotes = s_yesVotes;
        noVotes = s_noVotes;
        /// Checkpoint 2 //////
        size = s_tree.size;
        depth = s_tree.depth;
        root = s_tree.root();
    }

    function getVoterData(address _voter) public view returns (bool voter, bool registered) {
        voter = s_voters[_voter];
        // /// Checkpoint 2 //////
        registered = s_hasRegistered[_voter];
    }
}

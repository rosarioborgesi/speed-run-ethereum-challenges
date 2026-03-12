use std::hash::poseidon::bn254::hash_1;
use std::hash::poseidon::bn254::hash_2;
////// Checkpoint 4 //////
use binary_merkle_root::binary_merkle_root;

fn main(
    // Public input: hash of the private nullifier.
    // This value is exposed on-chain and used to prevent double voting.
    // If the same nullifier hash is used twice, the second vote is rejected.
    nullifier_hash: pub Field,

    // Private input: unique secret value known only by the voter.
    // It is used to derive the public nullifier_hash and also contributes
    // to the commitment stored in the Merkle tree.
    nullifier: Field,

    // Private input: additional secret combined with the nullifier
    // to build the commitment registered in the Merkle tree.
    secret: Field,

    ////// Checkpoint 4 //////

    // Public input: Merkle root of the commitment tree stored on-chain.
    // The circuit recomputes a root from the private leaf and Merkle path
    // and checks that it matches this public root.
    root: pub Field,

    // Public input: the selected vote option.
    // This binds the proof to a specific choice.
    // Since it is public, anyone can see whether this proof is for YES or NO,
    // but not which voter submitted it.
    vote: pub bool,

    // Public input: claimed depth of the Merkle proof.
    depth: pub u32,

    // Private input: index of the leaf inside the Merkle tree.
    // This must remain private, otherwise the proof could reveal
    // which commitment belongs to the voter.
    index: Field,

    // Private input: sibling nodes needed to reconstruct the path
    // from the leaf to the Merkle root.
    // The array has fixed length 16 because Noir does not support
    // dynamic arrays here, so this circuit supports up to 2^16 leaves.
    siblings: [Field; 16],
) {
    ////// Checkpoint 3 //////

    // Recompute the nullifier hash from the private nullifier.
    let computed_nullifier_hash: Field = hash_1([nullifier]);

    // Check that the prover's private nullifier matches the public nullifier hash.
    // This proves knowledge of the nullifier without revealing it.
    assert(computed_nullifier_hash == nullifier_hash);

    /*
        Build the commitment from the private nullifier and secret.

        This commitment is the value that was registered on-chain
        and inserted as a leaf in the Merkle tree.
    */
    let commitment: Field = hash_2([nullifier, secret]);

    ////// Checkpoint 4 //////

    /*
        Count how many sibling entries are actually used in the Merkle path.

        The siblings array always has length 16, but a given proof may use
        only the first `siblings_num` elements. Unused entries are expected to be 0.
    */
    let mut siblings_num = 0;
    for i in 0..siblings.len() {
        if siblings[i] != 0 {
            siblings_num += 1;
        }
    }

    // Safety check: the claimed depth cannot exceed the fixed sibling array length.
    assert(depth <= siblings.len());

    // Convert the leaf index into little-endian bits.
    // These bits tell the circuit at each level whether the current node
    // is a left child or a right child when reconstructing the root.
    let index_bits: [u1; 16] = index.to_le_bits();

    // Recompute the Merkle root from:
    // - the private commitment leaf
    // - the sibling path
    // - the leaf position in the tree
    let computed_root = binary_merkle_root(hash_2, commitment, siblings_num, index_bits, siblings);

    // Ensure the reconstructed root matches the public on-chain root.
    // If this holds, the circuit has proven that the commitment is part of the tree.
    assert(computed_root == root);

    /*
        Bind the vote value to the proof.

        The vote is already a public boolean, but we still use it in a constraint
        so the compiler does not treat it as an unused input.
        The equation x^2 = x holds only for 0 and 1.
    */
    let vote_field = vote as Field;
    assert((vote_field * vote_field) == vote_field);
}
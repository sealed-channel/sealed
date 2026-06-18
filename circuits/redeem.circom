pragma circom 2.1.6;

// Sealed redeem circuit — on-chain MiMC Tornado (user-generated secret).
//
// Proves: caller knows a `preimage` (the user's locally-generated secret) whose
// `leaf = MiMCHash(preimage)` belongs to the Merkle tree rooted at the public
// `root`, derives a deterministic `nullifier`, and binds the proof to
// `recipient` (hash of Txn.sender pubkey, enforced on-chain).
//
// HASH = MiMC over BN254 (mimc_bn254.circom), byte-for-byte identical to the AVM
// `mimc BN254Mp110` opcode — so the on-chain incremental Merkle tree built with
// the `mimc` opcode and this circuit's tree agree. (Replaces the legacy Poseidon
// construction; the Poseidon `redeemWithProof` path stays live separately.)
//
// Public inputs:
//   root         : Fr   — on-chain Merkle root (maintained by `deposit`)
//   nullifier    : Fr   — MiMCHash(preimage, NULL_TAG)
//   recipient    : Fr   — hash of senderPubkey; on-chain verifier asserts equality
//   denomination : Fr   — bound per-root (fixed v1)
//
// Private inputs:
//   preimage      : Fr      — the 16-byte secret packed as one field element
//   pathElements  : Fr[16]  — sibling hashes from leaf to root
//   pathIndices   : bit[16] — 0=cur is left child, 1=cur is right child
//
// Locked constants:
//   HASH       = MiMC BN254Mp110 (Miyaguchi-Preneel, 110 rounds, x^5).
//   HEIGHT     = 16.
//   NULL_TAG   = 0x5345414c45445f4e554c4c5f56315f5f (ASCII "SEALED_NULL_V1__" as Fr).
//   LEAF_HASH  = MiMCHash(preimage). Submitted on-chain as the deposit leaf;
//                always canonical (< p) since it is itself a field element.

include "mimc_bn254.circom";
include "circomlib/circuits/mux1.circom";

template MerkleLevel() {
    signal input  cur;
    signal input  sibling;
    signal input  index;       // bit
    signal output next;

    // Constrain index to {0,1}.
    index * (index - 1) === 0;

    component leftMux  = Mux1();
    component rightMux = Mux1();
    leftMux.c[0]  <== cur;
    leftMux.c[1]  <== sibling;
    leftMux.s     <== index;
    rightMux.c[0] <== sibling;
    rightMux.c[1] <== cur;
    rightMux.s    <== index;

    // node = mimc(left || right) — matches the on-chain 2-block mimc per level.
    component h = MiMCHash(2);
    h.blocks[0] <== leftMux.out;
    h.blocks[1] <== rightMux.out;
    next <== h.out;
}

template Redeem(height) {
    // Public
    signal input  root;
    signal input  nullifier;
    signal input  recipient;
    signal input  denomination;

    // Private
    signal input  preimage;
    signal input  pathElements[height];
    signal input  pathIndices[height];

    // 1. leaf := MiMCHash(preimage)   (single-block mimc, == on-chain deposit leaf)
    component leafH = MiMCHash(1);
    leafH.blocks[0] <== preimage;

    // 2. Merkle verify (leaf, path, indices) → root
    signal cur[height + 1];
    cur[0] <== leafH.out;
    component levels[height];
    for (var i = 0; i < height; i++) {
        levels[i] = MerkleLevel();
        levels[i].cur     <== cur[i];
        levels[i].sibling <== pathElements[i];
        levels[i].index   <== pathIndices[i];
        cur[i + 1] <== levels[i].next;
    }
    cur[height] === root;

    // 3. nullifier := MiMCHash(preimage, NULL_TAG)
    //    NULL_TAG = bytes("SEALED_NULL_V1__") interpreted as Fr (big-endian).
    //    0x5345414c45445f4e554c4c5f56315f5f
    component nullH = MiMCHash(2);
    nullH.blocks[0] <== preimage;
    nullH.blocks[1] <== 110815058874449983093867477470989876063;
    nullifier === nullH.out;

    // 4. Recipient binding.
    //    The circuit only proves `recipient` was bound into the proof. The
    //    on-chain contract enforces `recipient == hash(Txn.sender_pubkey)`.
    //    Defensive: reject Fr=0.
    signal recipientNonZeroInv;
    recipientNonZeroInv <-- recipient != 0 ? 1 / recipient : 0;
    recipient * recipientNonZeroInv === 1;

    // 5. Denomination guard. Same non-zero constraint.
    signal denomNonZeroInv;
    denomNonZeroInv <-- denomination != 0 ? 1 / denomination : 0;
    denomination * denomNonZeroInv === 1;
}

component main { public [root, nullifier, recipient, denomination] } = Redeem(16);

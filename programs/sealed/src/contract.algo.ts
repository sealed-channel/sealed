/**
 * Sealed — Algorand TypeScript smart contract.
 *
 * Per-wallet message-send credits + username for Sealed.
 * Tornado.cash-like commitment scheme for minting credits via trust-minimized off-chain KYC providers.
 * AFTER I FINISH TESTING, SNARK PROOFS for post-quantum privacy-preserving messaging on Algorand. TM!
 *
 *
 * Box layout (SPEC §5.1):
 *   w:<addr>  → UserState (version + username + batches + pubkeys hash anchor + bio)
 *   c:<hash>  → Commitment  (denomination + postedAtRound)
 *   n:<hash>  → Address     (username reverse-index)
 *
 * Global state:
 *   treasuryAddress  — funded LogicSig escrow address
 *   adminAddress     — posts commitments
 *   roundsPerYear    — 9_500_000 (~3.3s rounds)
 *   maxBatches       — 12
 *
 * Escrow group policy (Phase 3b):
 *   USER-MUTATING methods — `redeem`, `sendMessage`, `publishKeys`,
 *   `claimUsername`, `releaseUsername`, `setBio` — MUST be Txn 1 of a 2-txn
 *   group `[escrowSelfPay, appCall]`. Treasury LogicSig pays the network fee,
 *   user wallet pays zero ALGO. All identity-mutating ops
 *   (`publishKeys`, `claimUsername`, `releaseUsername`, `setBio`, `sendMessage`)
 *   also spend 1 credit via `spendOneCredit`. `redeem` grants credits and
 *   does NOT spend.
 *
 *   ADMIN-FACING methods — `createApplication`, `registerCommitment`,
 *   `withdrawTreasury`, `setTreasury`, `pruneExpired`, `update` — bypass
 *   the escrow group. Admin/creator/keeper pays own fee.
 */

import {
  arc4,
  assert,
  BigUint,
  Box,
  Bytes,
  BoxMap,
  clone,
  Contract,
  emit,
  GlobalState,
  Global,
  gtxn,
  itxn,
  log,
  op,
  MimcConfigurations,
  Txn,
  ensureBudget,
  OpUpFeeSource,
} from "@algorandfoundation/algorand-typescript";
import type {
  bytes,
  biguint,
  uint64,
} from "@algorandfoundation/algorand-typescript";

import { verifyGroth16, ensureSnarkBudget } from "./snark_verifier.algo";

/**
 * ARC4 struct stored at `c:<sha256(preimage)>`.
 *
 * `soldAtRound` is 0 for admin-direct (promo / test) commitments — those have
 * no shelf life. `purchaseCodes` stamps `soldAtRound = Global.round` when a
 * commitment is popped from the sale pool; `redeem` then enforces the 1-year
 * expiry fuse (`Global.round <= soldAtRound + roundsPerYear`).
 * Field order = wire layout — do not reorder.
 */
class Commitment extends arc4.Struct<{
  denomination: arc4.Uint64;
  postedAtRound: arc4.Uint64;
  soldAtRound: arc4.Uint64;
}> {}

/**
 * ARC4 struct stored at `nb:<nullifier>` (SPEC-snark-redeem-B §4.2). Marks a
 * preimage as spent. Existence = double-spend → revert.
 */
class NullifierState extends arc4.Struct<{
  spentRound: arc4.Uint64;
}> {}

/** Single FIFO batch within a wallet's UserState. */
class Batch extends arc4.Struct<{
  amount: arc4.Uint64;
  expiryRound: arc4.Uint64;
}> {}

/**
 * ARC4 struct stored at `w:<wallet-addr>`. Replaces legacy `CreditState`.
 *
 * Hash-anchor model: full pq pubkey (800B) is NOT stored on-chain.
 * Only `sha256(pqPubkey)` is anchored here; full pq pubkey is emitted in
 * `KeysPublished` event log for indexer cache. Clients fetch from indexer
 * and verify hash against this on-chain anchor before use.
 *
 * Field order is wire layout — never reorder without bumping `version`.
 */
class UserState extends arc4.Struct<{
  version: arc4.Uint8;
  username: arc4.DynamicBytes;
  batchCount: arc4.Uint8;
  batches: arc4.DynamicArray<Batch>;
  encryptionPubkey: arc4.StaticBytes<32>;
  scanPubkey: arc4.StaticBytes<32>;
  pqPubkeyHash: arc4.StaticBytes<32>;
  /** v3: public profile bio, free-form UTF-8, ≤ BIO_MAX bytes. Empty = unset. */
  bio: arc4.DynamicBytes;
}> {}

/** ARC28 event emitted on `registerCommitment`. */
class CommitmentRegistered extends arc4.Struct<{
  commitment: arc4.StaticBytes<32>;
  denomination: arc4.Uint64;
  postedAtRound: arc4.Uint64;
}> {}

/** ARC28 event emitted on `seedSalePool`. */
class PoolSeeded extends arc4.Struct<{
  count: arc4.Uint64;
  newTail: arc4.Uint64;
}> {}

/** ARC28 event emitted on `unseedSalePool`. */
class PoolUnseeded extends arc4.Struct<{
  count: arc4.Uint64;
  newTail: arc4.Uint64;
}> {}

/** ARC28 event emitted on `reclaimExpired` — admin frees `c:` box MBR. */
class ExpiredReclaimed extends arc4.Struct<{
  count: arc4.Uint64;
}> {}

/** ARC28 event emitted on `setPrice`. */
class PriceChanged extends arc4.Struct<{
  oldPrice: arc4.Uint64;
  newPrice: arc4.Uint64;
}> {}

/**
 * ARC28 event emitted on `purchaseCodes` — the wire to the off-chain
 * preimage-server. Server watches this stream, decrypts the matching
 * preimages to `deliveryPubkey`, and posts ciphertext for buyer retrieval.
 */
class CommitmentsSold extends arc4.Struct<{
  buyer: arc4.Address;
  deliveryPubkey: arc4.StaticBytes<32>;
  commitments: arc4.DynamicArray<arc4.StaticBytes<32>>;
  purchasedAtRound: arc4.Uint64;
}> {}

/** ARC28 event emitted on `redeem`. */
class Redeemed extends arc4.Struct<{
  commitment: arc4.StaticBytes<32>;
  denomination: arc4.Uint64;
  wallet: arc4.Address;
  username: arc4.DynamicBytes;
}> {}

/** ARC28 event emitted on `redeemWithProof` (SPEC-snark-redeem-B §4). */
class RedeemedWithProof extends arc4.Struct<{
  root: arc4.StaticBytes<32>;
  nullifier: arc4.StaticBytes<32>;
  denomination: arc4.Uint64;
  wallet: arc4.Address;
  username: arc4.DynamicBytes;
}> {}

/** ARC28 event emitted on `deposit` (SPEC-onchain-mimc-tornado). */
class Deposited extends arc4.Struct<{
  leaf: arc4.StaticBytes<32>;
  leafIndex: arc4.Uint64;
  root: arc4.StaticBytes<32>;
}> {}

/**
 * ARC28 event emitted on `publishKeys`.
 *
 * Carries the full pq pubkey (up to 2048 bytes) in the event log so indexer
 * can cache it. On-chain box stores only `pqPubkeyHash` (32 bytes). Clients
 * verify indexer-served pq pubkey hashes against this anchor before use.
 */
class KeysPublished extends arc4.Struct<{
  wallet: arc4.Address;
  encryptionPubkey: arc4.StaticBytes<32>;
  scanPubkey: arc4.StaticBytes<32>;
  pqPubkey: arc4.DynamicBytes;
  pqPubkeyHash: arc4.StaticBytes<32>;
}> {}

/** ARC28 event emitted on first claim or rename of a username. */
class UsernameClaimed extends arc4.Struct<{
  wallet: arc4.Address;
  oldName: arc4.DynamicBytes;
  newName: arc4.DynamicBytes;
}> {}

/** ARC28 event emitted on release of a username. */
class UsernameReleased extends arc4.Struct<{
  wallet: arc4.Address;
  name: arc4.DynamicBytes;
}> {}

/** ARC28 event emitted on `setBio`. Empty `bio` = cleared. */
class BioChanged extends arc4.Struct<{
  wallet: arc4.Address;
  bio: arc4.DynamicBytes;
}> {}

/**
 * ARC28 event emitted whenever an identity-mutating op spends 1 credit
 * (`publishKeys`, `claimUsername`, `releaseUsername`, `sendMessage`).
 * `remaining` is the post-spend live credit total for the wallet, computed
 * from the kept batches in the same `spendOneCredit` walk — zero extra
 * box reads. Indexer uses this as a cheap running balance signal.
 */
class CreditSpent extends arc4.Struct<{
  wallet: arc4.Address;
  remaining: arc4.Uint64;
}> {}

/** Readonly return shape for `getUserKeys`. */
class UserKeys extends arc4.Struct<{
  encryptionPubkey: arc4.StaticBytes<32>;
  scanPubkey: arc4.StaticBytes<32>;
  pqPubkeyHash: arc4.StaticBytes<32>;
}> {}

const ROUNDS_PER_YEAR: uint64 = 9_500_000;
const MAX_BATCHES: uint64 = 12;
const HASH_LEN: uint64 = 32;
const PREIMAGE_LEN: uint64 = 16;
const ACCOUNT_MBR_MIN: uint64 = 100_000;
const GROUP_FEE_MIN: uint64 = 2000;
const GROUP_SIZE_EXPECTED: uint64 = 2;
const FEE_TXN_INDEX: uint64 = 0;
const APP_CALL_INDEX: uint64 = 1;
const NAME_MIN: uint64 = 3;
const NAME_MAX: uint64 = 20;

/**
 * Max bio length in BYTES (UTF-8 encoded; multibyte chars count as encoded
 * width). Contract validates length only — content policy (control chars)
 * is client-side. Mirrored in `lib/bio.ts`, the Dart bio validator, and the
 * indexer user-watcher decode schema.
 */
const BIO_MAX: uint64 = 160;

/** Lower bound on `setPrice` — 1 ALGO floor guards against fat-finger zeroing. */
const PRICE_FLOOR: uint64 = 1_000_000;
/** Upper bound on `setPrice` — 1M ALGO ceiling guards against fat-finger overflow. */
const PRICE_CEILING: uint64 = 1_000_000_000_000;

/**
 * Max commitments accepted by `seedSalePool` / `unseedSalePool` per call.
 * AVM box-ref budget is 8 per txn for a solo admin call; each seed entry
 * consumes 2 refs (`c:<hash>` read + `p:<idx>` write); each unseed entry
 * consumes 2 refs (`p:<idx>` read+delete + `c:<hash>` read+delete). Cap = 4.
 *
 * Deviation from spec (LP-INTEGRATION.md §2.1, which states 8) — spec author
 * assumed 8 refs without accounting for the per-entry 2-ref cost. Admin
 * batches across calls for larger seeds: a 200-code pool needs 50 seed calls
 * @ ~1000 µA each = 0.05 ALGO total. Acceptable.
 */
const MAX_POOL_BATCH: uint64 = 4;

/**
 * Max codes a buyer can purchase in a single `purchaseCodes` call.
 *
 * The 2-txn group is [Pay, AppCall]. AVM allows 8 box refs per txn pooled
 * across the group, BUT only application-call txns can carry box refs —
 * payment txns have no `boxes` field. So the AppCall is the only ref-bearer
 * → 8 refs per group. Each code consumes 2 refs (`p:<idx>` read+delete +
 * `c:<hash>` stamp). Effective cap = 4.
 *
 * Deviation from LP-INTEGRATION.md §2.1 (which states 8) — spec author
 * assumed refs could be parked on the Pay txn. To raise this cap in v2,
 * extend the group to [Pay, AppCall, ExtraNoOpAppCall] (extra app-call's
 * sole purpose is ref budget). Buyer pays 1 extra `minFee` per call.
 */
const MAX_PURCHASE_QTY: uint64 = 4;

/** Group shape constants for `purchaseCodes` — distinct from escrow group. */
const PURCHASE_PAY_INDEX: uint64 = 0;
const PURCHASE_APPCALL_INDEX: uint64 = 1;

/**
 * Max commitments accepted by `reclaimExpired` per call. Each entry consumes
 * only one box ref (`c:<hash>` read+delete) — pool box is long gone by the
 * time reclaim runs. Cap = 8 (AVM per-txn box-ref limit).
 */
const MAX_RECLAIM_BATCH: uint64 = 8;

/**
 * MBR (in µALGO) the app account must hold to create a fresh `w:` UserState
 * box. The app account pre-funds new-box MBR for every `redeem` (which creates
 * the box). Pre-funding model documented in deploy.ts. Not referenced in
 * contract code anymore — kept here for documentation alignment with the
 * deploy script's headroom formula.
 *
 * Conservative ceiling: w: prefix (2) + addr (32) = 34B key,
 * UserState v3 worst-case value ≈ 1 (version) + 2+32 (username header+max) +
 * 1 (batchCount) + 2+12*16 (batches header+max) + 96 (3×32 keys) +
 * 2+160 (bio header+max) + 2 (bio head offset slot) ≈ 490B.
 * MBR = 2500 + 400*(34 + 490) = 212_100. Round up.
 */
// const MBR_NEW_USER_BOX: uint64 = 215_000;

/**
 * UserState wire-layout version. Bump on any field reorder/add.
 * v2 → v3 (2026-06-12): appended `bio` dynamic field. v2 boxes are upgraded
 * lazily by `loadUser` on read; every write persists v3.
 */
const USER_STATE_VERSION: uint64 = 3;

const BYTE_UNDERSCORE: uint64 = 0x5f;
const BYTE_DIGIT_LO: uint64 = 0x30;
const BYTE_DIGIT_HI: uint64 = 0x39;
const BYTE_ALPHA_LO: uint64 = 0x61;
const BYTE_ALPHA_HI: uint64 = 0x7a;

/**
 * BN254 Fr scalar field modulus. Used by `redeemWithProof` to derive
 * `recipient = uint(Txn.sender) mod Fr_MOD` (Tornado-style binding, §3.5).
 */
const FR_MOD: biguint = BigUint(
  Bytes.fromHex(
    "30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001",
  ),
);

/** Left-pad bytes with zeros to a fixed 32-byte width. */
function padLeft32(b: bytes): bytes {
  if (b.length === 32) return b;
  assert(b.length < 32, "OVERFLOW_32");
  return op.bzero(32 - b.length).concat(b);
}

/** Encode a uint64 as 2-byte big-endian (ARC4 u16 offset/length slot). */
function u16be(x: uint64): bytes {
  return op.extract(op.itob(x), 6, 2);
}

/**
 * On-chain MiMC incremental Merkle tree (height 16) over the AVM
 * `mimc BN254Mp110` opcode — byte-identical to circuits/mimc_bn254.circom, so
 * the on-chain root matches the SNARK's tree (SPEC-onchain-mimc-tornado).
 */
const MIMC_TREE_HEIGHT: uint64 = 16;
// Max leaves = 2^16. Reverts further deposits once full.
const MIMC_MAX_LEAVES: uint64 = 65536;
// Recent-roots window: a redeemer's proof may target any of the last K roots,
// since the root advances on every deposit (SPEC-onchain-mimc-tornado §3).
const MIMC_ROOT_HISTORY: uint64 = 32;

// Precomputed zero ladder, 17 × 32B concatenated. zeros[0]=0;
// zeros[i+1]=mimc(zeros[i] || zeros[i]); zeros[16] = empty-tree root.
// Generated from circuits/test/mimc-bn254-ref.mjs (== AVM mimc).
const MIMC_ZEROS: bytes = Bytes.fromHex(
  "0000000000000000000000000000000000000000000000000000000000000000" +
    "29a1ce46748dd1f268a52b64670d2dd170487b0eabfdf8e3280c52996af03561" +
    "173028dc3fc24d89b918ab4952f667ec2f8ea5341ce6c3202b0fefee6cf76041" +
    "07cd5828f4e95899b5539065896b855b7684478e6cf2f9e1162ea9a031471846" +
    "2e924806f112e278db1694edc2d6b7127053bcddfb24c55c9c47d578c47f0ec8" +
    "29c27f9d279e3f52b51787e2a648a66f7a60e62497209bf986faa59419a91daa" +
    "1fc412ce46c3b2d344fec6237ac75033da3211884966dedd2b1a685b014f2d13" +
    "1aa56b9fb75c97d91fa20c2ce17e86dc0c34b65836c9ba22107318b74634ec22" +
    "2b04d6771aa832c8ac1d79a952ae8bacafaf093f023d4c83309995d0abe5e8b9" +
    "0ac75ef3e6cdfbe1c105f179df08bb61224350a619390c7d0ae0a49c567bdd47" +
    "214dc26f4b6f38c484cb304fdf042bc7b9402640a2f1fc6c7cfb1b006c17c390" +
    "1c26c9e8963ed1d3e8e18eb36672186cfbda944795465db9496780a13e0b082d" +
    "0df1496ebc60b806f4f712155ae3953493b54d911386b03033a075d8550813e1" +
    "26afa3a82762a461a8895be815960a9a61acdd641223176789263c79f20654eb" +
    "0e6038b3d33f66cf8bd05e0511862e165ce79afbd2b03a6d6a0a0818148316bd" +
    "0b36746bc15c76db06d9b0a3b399ce9372403f1b928431dd544059238e9e1d15" +
    "2b44e255c63ae690467e1541623c37ac9e2d06bb95b794debbb40dc69973a445",
);

/** zeros[level] (0..16) — empty-subtree root at the given level. */
function mimcZero(level: uint64): bytes {
  return op.extract(MIMC_ZEROS, level * 32, 32);
}

/** One Merkle node: mimc(left || right) — matches MiMCHash(2) in the circuit. */
function mimcNode(left: bytes, right: bytes): bytes {
  return op.mimc(MimcConfigurations.BN254Mp110, left.concat(right));
}

export class Sealed extends Contract {
  treasuryAddress = GlobalState<arc4.Address>({ key: "t" });
  adminAddress = GlobalState<arc4.Address>({ key: "a" });
  roundsPerYear = GlobalState<uint64>({ key: "r" });
  maxBatches = GlobalState<uint64>({ key: "m" });

  /** Per-code price in µAlgos. Set via `createApplication`/`setPrice`. */
  priceMicroAlgos = GlobalState<uint64>({ key: "pr" });
  /** FIFO sale-pool head index. Incremented by `purchaseCodes`. */
  poolHead = GlobalState<uint64>({ key: "ph" });
  /** FIFO sale-pool tail index. Incremented by `seedSalePool`, decremented by `unseedSalePool`. */
  poolTail = GlobalState<uint64>({ key: "pt" });

  // key body = sha256(preimage), exact 32 bytes. Prefix 'c:' per SPEC.
  commitments = BoxMap<bytes, Commitment>({ keyPrefix: "c:" });

  // key body = nullifier, exact 32 bytes. Prefix 'nb:'.
  // Written by `redeemWithProofMimc`. Existence ⇒ DOUBLE_SPEND.
  nullifiers = BoxMap<bytes, NullifierState>({ keyPrefix: "nb:" });

  // On-chain MiMC incremental Merkle tree (SPEC-onchain-mimc-tornado).
  // Current root (32B); empty tree = zeros[16].
  mimcRoot = GlobalState<bytes>({ key: "mR" });
  // Next free leaf index (0 .. 2^16-1).
  mimcNextIndex = GlobalState<uint64>({ key: "mN" });
  // Credit denomination granted per redeem (fixed per tree, Tornado-style).
  mimcDenom = GlobalState<uint64>({ key: "mD" });
  // filledSubtrees packed into ONE 512B box (16 × 32B) — fs[level] at offset
  // level*32. Single box keeps deposit within the 8-box-ref/txn limit (a
  // per-level BoxMap would need 17 refs). Init = zeros[0..15] ladder.
  mimcFilled = Box<bytes>({ key: "mfs" });
  // Recent-roots ring packed into ONE box (K × 32B) — slot at offset
  // (leafIndex mod K)*32. Single box so `redeemWithProofMimc` can scan all K
  // slots with ONE box ref (a per-slot BoxMap would need K refs to read).
  // Empty slots are zero (no real root is 0). Init = K×32 zero bytes.
  mimcRecentRoots = Box<bytes>({ key: "mqr" });

  // key body = wallet address (32 bytes). Prefix 'w:' per SPEC.
  users = BoxMap<bytes, UserState>({ keyPrefix: "w:" });

  // key body = sha256(name), exact 32 bytes. Prefix 'n:' per SPEC.
  // Value = wallet address that owns the name.
  names = BoxMap<bytes, arc4.Address>({ keyPrefix: "n:" });

  // key body = 8B big-endian uint64 queue index. Prefix 'p:' per
  // LP-INTEGRATION.md §2.4. Value = 32B commitment hash. FIFO sale pool —
  // `seedSalePool` appends at `poolTail`, `purchaseCodes` consumes from
  // `poolHead`, `unseedSalePool` pops from `poolTail`.
  salePool = BoxMap<bytes, arc4.StaticBytes<32>>({ keyPrefix: "p:" });

  /**
   * Creator init: seed globals. Must be called as the create txn.
   * `treasuryAddress` may be the zero address at create time and rotated later
   * via `setTreasury` once the LogicSig escrow has been compiled + funded.
   * `roundsPerYear` is configurable to allow LocalNet expiry tests; pass
   * `9_500_000` for TestNet/MainNet (≈1 year at ~3.3s rounds).
   * `initialPrice` seeds the per-code µAlgo sale price (spec v1: 10_000_000 =
   * 10 ALGO). Mutable post-create via `setPrice`.
   */
  @arc4.abimethod({ onCreate: "require" })
  createApplication(
    treasury: arc4.Address,
    admin: arc4.Address,
    roundsPerYear: arc4.Uint64,
    initialPrice: arc4.Uint64,
  ): void {
    this.treasuryAddress.value = treasury;
    this.adminAddress.value = admin;
    this.roundsPerYear.value = roundsPerYear.asUint64();
    this.maxBatches.value = MAX_BATCHES;
    this.priceMicroAlgos.value = initialPrice.asUint64();
    this.poolHead.value = 0;
    this.poolTail.value = 0;
  }

  /**
   * Initialize the MiMC tree (SPEC-onchain-mimc-tornado). Must be called once,
   * admin-only, AFTER the app account is funded — it creates the 512B
   * filledSubtrees + recent-roots boxes (MBR) which a fresh create txn can't
   * pay for. Covers both fresh deploys and the live in-place ApplicationUpdate
   * path. `denomination` = credits granted per redeem (fixed per tree).
   * Idempotent guard refuses re-init once the root is set.
   */
  @arc4.abimethod()
  initMimcTree(denomination: arc4.Uint64): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    assert(!this.mimcRoot.hasValue, "ALREADY_INIT");
    assert(denomination.asUint64() > 0, "BAD_DENOM");
    this.mimcRoot.value = mimcZero(MIMC_TREE_HEIGHT);
    this.mimcNextIndex.value = 0;
    this.mimcDenom.value = denomination.asUint64();
    this.mimcFilled.value = op.extract(MIMC_ZEROS, 0, 512);
    this.mimcRecentRoots.value = op.bzero(MIMC_ROOT_HISTORY * 32);
  }

  /**
   * User-generated-secret deposit (SPEC-onchain-mimc-tornado). 2-txn group
   * `[pay price → app, this appcall]`, both signed by the buyer. Inserts the
   * client-computed `leaf = MiMCHash(secret)` into the on-chain incremental
   * MiMC Merkle tree, advances the root, and records the new root in the
   * recent-roots window so a redeemer can later prove membership from a fresh,
   * unlinked wallet via `redeemWithProofMimc`.
   *
   * No credit is granted here — buyer↔redeemer unlinkability is the whole point.
   * `leaf` must be a canonical Fr element (< p): the AVM `mimc` opcode rejects
   * non-canonical 32-byte blocks. (A real leaf = MiMCHash(secret) always is.)
   */
  @arc4.abimethod()
  deposit(leaf: arc4.StaticBytes<32>): void {
    this.assertPurchaseGroupShape(1);

    // Canonical leaf < FR_MOD (mimc rejects ≥ p; fail early + clearly).
    const leafBig: biguint = BigUint(leaf.bytes);
    assert(leafBig < FR_MOD, "BAD_LEAF_NONCANON");

    const index: uint64 = this.mimcNextIndex.value;
    assert(index < MIMC_MAX_LEAVES, "TREE_FULL");

    // Pool budget for 16 mimc (≈1119 each) + box ops. Paid from the app
    // account, which just received the deposit price in Txn 0.
    ensureBudget(20000, OpUpFeeSource.AppAccount);

    // Incremental insert: walk leaf→root over the packed filledSubtrees box
    // (fs[level] at offset level*32), splicing in memory and writing once.
    let fs: bytes = this.mimcFilled.value;
    let cur: bytes = leaf.bytes;
    let idx: uint64 = index;
    for (let level: uint64 = 0; level < MIMC_TREE_HEIGHT; level++) {
      const off: uint64 = level * 32;
      if ((idx & 1) === 0) {
        // current node is a left child: cache it; right sibling is empty (zero).
        fs = op.replace(fs, off, cur);
        cur = mimcNode(cur, mimcZero(level));
      } else {
        // current node is a right child: left sibling is the cached subtree.
        cur = mimcNode(op.extract(fs, off, 32), cur);
      }
      idx = idx >> 1;
    }

    this.mimcFilled.value = fs;
    this.mimcRoot.value = cur;
    this.mimcNextIndex.value = index + 1;

    // Record the post-insert root in the packed ring (slot = index mod K).
    const slot: uint64 = index % MIMC_ROOT_HISTORY;
    this.mimcRecentRoots.value = op.replace(
      this.mimcRecentRoots.value,
      slot * 32,
      cur,
    );

    emit(
      new Deposited({
        leaf,
        leafIndex: new arc4.Uint64(index),
        root: new arc4.StaticBytes<32>(cur),
      }),
    );
  }

  /**
   * Anonymous redeem against the on-chain MiMC tree (SPEC-onchain-mimc-tornado).
   * Called from a FRESH wallet, unlinked to the deposit. The Groth16 proof shows
   * the caller knows a secret whose leaf is in the tree at one of the recent
   * roots; the proof is bound to `Txn.sender` (front-run safe) and grants the
   * fixed `mimcDenom` credits.
   *
   * publicInputs (4×32B): [root, nullifier, recipient, denomination].
   * Escrow group: Txn 1 of [escrowSelfPay, appCall] — user pays 0 ALGO.
   *
   * Errors: STALE_ROOT (root not in window), DOUBLE_SPEND, BAD_RECIPIENT,
   * BAD_DENOM, BAD_PROOF.
   */
  @arc4.abimethod()
  redeemWithProofMimc(
    rootRef: arc4.StaticBytes<32>,
    nullifier: arc4.StaticBytes<32>,
    proof: bytes,
    publicInputs: bytes,
    username: bytes,
  ): void {
    this.assertEscrowGroupShape();
    assert(proof.length === 256, "BAD_PROOF_LEN");
    assert(publicInputs.length === 128, "BAD_PUB_LEN");

    // Pool opcode budget FIRST — the 32-slot ring scan + public-input checks +
    // accumulateVkX + pairing all run on it. Pooling later (e.g. just before
    // verifyGroth16) lets the ring scan exhaust the flat 700-op base before
    // OpUp ever fires → "dynamic cost budget exceeded".
    ensureSnarkBudget();

    // 1. rootRef must be a recent on-chain root — scan the packed ring (1 box
    //    read, K slots in memory; empty slots are zero, no real root is 0).
    const ring: bytes = this.mimcRecentRoots.value;
    let known: uint64 = 0;
    for (let slot: uint64 = 0; slot < MIMC_ROOT_HISTORY; slot++) {
      if (op.extract(ring, slot * 32, 32).equals(rootRef.bytes)) {
        known = 1;
      }
    }
    assert(known === 1, "STALE_ROOT");

    // 2. Double-spend guard.
    const nBox = this.nullifiers(nullifier.bytes);
    assert(!nBox.exists, "DOUBLE_SPEND");

    // 3. Public inputs must match the trusted args + sender binding + denom.
    const pubRoot = publicInputs.slice(0, 32);
    const pubNullifier = publicInputs.slice(32, 64);
    const pubRecipient = publicInputs.slice(64, 96);
    const pubDenom = publicInputs.slice(96, 128);
    assert(pubRoot.equals(rootRef.bytes), "BAD_ROOT");
    assert(pubNullifier.equals(nullifier.bytes), "BAD_NULLIFIER");

    const senderAsBig: biguint = BigUint(Txn.sender.bytes);
    const expectedRecipientBig: biguint = senderAsBig % FR_MOD;
    const expectedRecipientBytes: bytes = padLeft32(
      Bytes(expectedRecipientBig),
    );
    assert(pubRecipient.equals(expectedRecipientBytes), "BAD_RECIPIENT");

    const denomination = new arc4.Uint64(this.mimcDenom.value);
    const denomBig: biguint = BigUint(denomination.bytes);
    const expectedDenomBytes: bytes = padLeft32(Bytes(denomBig));
    assert(pubDenom.equals(expectedDenomBytes), "BAD_DENOM");

    // 4. Pairing check (MiMC vk). Budget already pooled at the top.
    const ok = verifyGroth16(proof, publicInputs);
    assert(ok, "BAD_PROOF");

    // 5. Mark spent BEFORE granting (defensive vs inner-txn reentry).
    nBox.value = new NullifierState({
      spentRound: new arc4.Uint64(Global.round),
    });

    // 6. Username co-claim (parity with legacy redeem).
    if (username.length > 0) {
      this.validateNameFormat(username);
      const nameKey = op.sha256(username);
      const namesBox = this.names(nameKey);
      assert(!namesBox.exists, "TAKEN");
      namesBox.value = new arc4.Address(Txn.sender);
    }

    // 7. Grant credits — same FIFO append as `redeem`.
    const walletKey = Txn.sender.bytes;
    const cs = this.users(walletKey);
    const newBatch = new Batch({
      amount: denomination,
      expiryRound: new arc4.Uint64(Global.round + this.roundsPerYear.value),
    });

    if (cs.exists) {
      const prev = this.loadUser(walletKey);
      const prevCount: uint64 = prev.batchCount.asUint64();
      assert(prevCount < this.maxBatches.value, "TOO_MANY_BATCHES");
      prev.batches.push(newBatch);
      let nextName = prev.username;
      if (username.length > 0) {
        assert(prev.username.length === 0, "USERNAME_SET");
        nextName = new arc4.DynamicBytes(username);
      }
      cs.value = new UserState({
        version: new arc4.Uint8(USER_STATE_VERSION),
        username: nextName,
        batchCount: new arc4.Uint8(prevCount + 1),
        batches: prev.batches,
        encryptionPubkey: prev.encryptionPubkey,
        scanPubkey: prev.scanPubkey,
        pqPubkeyHash: prev.pqPubkeyHash,
        bio: prev.bio,
      });
    } else {
      const batches = new arc4.DynamicArray<Batch>();
      batches.push(newBatch);
      cs.value = new UserState({
        version: new arc4.Uint8(USER_STATE_VERSION),
        username: new arc4.DynamicBytes(username),
        batchCount: new arc4.Uint8(1),
        batches,
        encryptionPubkey: new arc4.StaticBytes<32>(op.bzero(32)),
        scanPubkey: new arc4.StaticBytes<32>(op.bzero(32)),
        pqPubkeyHash: new arc4.StaticBytes<32>(op.bzero(32)),
        bio: new arc4.DynamicBytes(),
      });
    }

    // 8. Account-MBR seed for fresh wallets (mirrors legacy `redeem`).
    const balance: uint64 = op.balance(Txn.sender);
    if (balance < ACCOUNT_MBR_MIN) {
      const seedAmount: uint64 = ACCOUNT_MBR_MIN - balance;
      itxn
        .payment({ receiver: Txn.sender, amount: seedAmount, fee: 0 })
        .submit();
    }

    emit(
      new RedeemedWithProof({
        root: rootRef,
        nullifier,
        denomination,
        wallet: new arc4.Address(Txn.sender),
        username: new arc4.DynamicBytes(username),
      }),
    );
  }

  /**
   * Admin posts a per-code commitment. Body of the key is `sha256(preimage)`.
   * Box MBR is consumed from the contract account balance — top up at deploy.
   * ABI log emits the commitment hash + denomination for off-chain audit.
   */
  @arc4.abimethod()
  registerCommitment(commitment: bytes, denomination: arc4.Uint64): void {
    assert(commitment.length === HASH_LEN, "BAD_HASH");
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");

    const box = this.commitments(commitment);
    assert(!box.exists, "TAKEN");

    const postedAtRound = new arc4.Uint64(Global.round);
    box.value = new Commitment({
      denomination,
      postedAtRound,
      soldAtRound: new arc4.Uint64(0),
    });

    emit(
      new CommitmentRegistered({
        commitment: new arc4.StaticBytes<32>(commitment),
        denomination,
        postedAtRound,
      }),
    );
  }

  /**
   * Admin appends commitments to the FIFO sale pool. Each entry must have a
   * pre-registered `c:<hash>` box (via `registerCommitment`) with
   * `soldAtRound == 0` (not previously sold). Writes a `p:<be_uint64_idx>`
   * box per entry, bumps `poolTail`. MBR for each `p:` box (~19_300 µA)
   * comes from the app account balance — top up at deploy via T8.
   *
   * AVM box-ref budget caps `commitments.length` at `MAX_POOL_BATCH` (4).
   */
  @arc4.abimethod()
  seedSalePool(commitments: arc4.DynamicArray<arc4.StaticBytes<32>>): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    const count: uint64 = commitments.length;
    assert(count > 0, "EMPTY_BATCH");
    assert(count <= MAX_POOL_BATCH, "BATCH_TOO_LARGE");

    let tail: uint64 = this.poolTail.value;
    for (let i: uint64 = 0; i < count; i++) {
      const hash = commitments[i].bytes;
      // Validate underlying commitment box exists + unsold.
      const cBox = this.commitments(hash);
      assert(cBox.exists, "COMMITMENT_MISSING");
      assert(cBox.value.soldAtRound.asUint64() === 0, "ALREADY_SOLD");

      // Append to FIFO queue at `tail + i`.
      const idxKey = op.itob(tail + i);
      const pBox = this.salePool(idxKey);
      assert(!pBox.exists, "POOL_SLOT_TAKEN");
      pBox.value = new arc4.StaticBytes<32>(hash);
    }
    const newTail: uint64 = tail + count;
    this.poolTail.value = newTail;

    emit(
      new PoolSeeded({
        count: new arc4.Uint64(count),
        newTail: new arc4.Uint64(newTail),
      }),
    );
  }

  /**
   * Admin pops `qty` commitments from the tail of the sale pool (FIFO front
   * preserved for in-flight buyers). For each popped entry: delete the
   * `p:<idx>` queue box AND the underlying `c:<hash>` commitment box. Both
   * MBR refunds flow back to the app account. Asserts `soldAtRound == 0` on
   * each `c:` box — sold codes can only be reclaimed via `reclaimExpired`
   * after their 1-year fuse burns out.
   *
   * Capped at `MAX_POOL_BATCH` per call (same AVM ref-budget reason as seed).
   */
  @arc4.abimethod()
  unseedSalePool(qty: arc4.Uint64): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    const count: uint64 = qty.asUint64();
    assert(count > 0, "EMPTY_BATCH");
    assert(count <= MAX_POOL_BATCH, "BATCH_TOO_LARGE");

    const head: uint64 = this.poolHead.value;
    const tail: uint64 = this.poolTail.value;
    assert(tail - head >= count, "POOL_UNDERFLOW");

    for (let i: uint64 = 0; i < count; i++) {
      const popIdx: uint64 = tail - 1 - i;
      const idxKey = op.itob(popIdx);
      const pBox = this.salePool(idxKey);
      assert(pBox.exists, "BAD_STATE");
      const hash = pBox.value.bytes;

      const cBox = this.commitments(hash);
      assert(cBox.exists, "COMMITMENT_MISSING");
      assert(cBox.value.soldAtRound.asUint64() === 0, "ALREADY_SOLD");

      cBox.delete();
      pBox.delete();
    }
    const newTail: uint64 = tail - count;
    this.poolTail.value = newTail;

    emit(
      new PoolUnseeded({
        count: new arc4.Uint64(count),
        newTail: new arc4.Uint64(newTail),
      }),
    );
  }

  /** Readonly: current depth of the sale pool (`poolTail - poolHead`). */
  @arc4.abimethod({ readonly: true })
  getPoolSize(): arc4.Uint64 {
    return new arc4.Uint64(this.poolTail.value - this.poolHead.value);
  }

  /**
   * Admin reclaims `c:<hash>` box MBR for codes that were sold but never
   * redeemed within the 1-year fuse window. Asserts `soldAtRound > 0` (only
   * sold codes — unsold pool entries are reclaimed via `unseedSalePool`) and
   * `Global.round > soldAtRound + roundsPerYear` (fuse must have burned out).
   * No fund refund — the 10 ALGO sale was final at purchase time; this only
   * frees MBR (~22.5k µA per entry) back to the app account.
   *
   * Capped at `MAX_RECLAIM_BATCH` (8) per call.
   */
  @arc4.abimethod()
  reclaimExpired(commitments: arc4.DynamicArray<arc4.StaticBytes<32>>): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    const count: uint64 = commitments.length;
    assert(count > 0, "EMPTY_BATCH");
    assert(count <= MAX_RECLAIM_BATCH, "BATCH_TOO_LARGE");

    const fuseLen: uint64 = this.roundsPerYear.value;
    const currentRound: uint64 = Global.round;

    for (let i: uint64 = 0; i < count; i++) {
      const hash = commitments[i].bytes;
      const cBox = this.commitments(hash);
      assert(cBox.exists, "COMMITMENT_MISSING");
      const sold: uint64 = cBox.value.soldAtRound.asUint64();
      assert(sold > 0, "NOT_SOLD");
      assert(currentRound > sold + fuseLen, "NOT_EXPIRED");
      cBox.delete();
    }

    emit(new ExpiredReclaimed({ count: new arc4.Uint64(count) }));
  }

  /**
   * Admin updates the per-code µAlgo sale price. Bounds `[PRICE_FLOOR,
   * PRICE_CEILING]` guard against fat-finger zeroing or overflow. In-flight
   * purchases signed at the old price will revert `BAD_AMOUNT` once the new
   * price is set — LP should refetch price + offer retry.
   */
  @arc4.abimethod()
  setPrice(newPrice: arc4.Uint64): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    const np: uint64 = newPrice.asUint64();
    assert(np >= PRICE_FLOOR, "BAD_PRICE");
    assert(np <= PRICE_CEILING, "BAD_PRICE");
    const old: uint64 = this.priceMicroAlgos.value;
    this.priceMicroAlgos.value = np;
    emit(
      new PriceChanged({
        oldPrice: new arc4.Uint64(old),
        newPrice: newPrice,
      }),
    );
  }

  /**
   * Buyer-facing sale entry-point. 2-txn group, both signed by buyer:
   *   Txn 0: Pay buyer → `Global.currentApplicationAddress`,
   *          amount = `qty × priceMicroAlgos`.
   *   Txn 1: this app-call.
   *
   * Pops `qty` commitments from the FIFO sale-pool head, stamps each
   * `c:<hash>` with `soldAtRound = Global.round` (lighting the 1-year fuse
   * enforced by `redeem`), and deletes the `p:<idx>` queue boxes (MBR refunds
   * to the app account). Buyer pays own fees — no escrow. No credit spend
   * (buyer typically has no `w:` box yet; codes are bearer and redeemed by
   * whichever wallet later calls `redeem`).
   *
   * Emits ARC28 `CommitmentsSold{buyer, deliveryPubkey, commitments[],
   * purchasedAtRound}` — this is the wire for the off-chain preimage-server,
   * which encrypts the matching preimages to `deliveryPubkey` and serves
   * them via OHTTP-relayed delivery endpoint.
   */
  @arc4.abimethod()
  purchaseCodes(qty: arc4.Uint64, deliveryPubkey: arc4.StaticBytes<32>): void {
    const count: uint64 = qty.asUint64();
    assert(count > 0, "EMPTY_BATCH");
    assert(count <= MAX_PURCHASE_QTY, "BATCH_TOO_LARGE");

    this.assertPurchaseGroupShape(count);

    // Pool extra opcode budget — 4-code loop + 4×(box read/write/delete) +
    // commitments[] DynamicArray emit can push past the 700-op single-call
    // ceiling. OpUp inner-appls are paid from the app account (which just
    // received `qty × priceMicroAlgos` from the buyer in Txn 0).
    ensureBudget(2400, OpUpFeeSource.AppAccount);

    // Non-zero delivery pubkey — guards against accidental discarded-buy.
    // Cheap byte-OR check across the 32 bytes.
    const dpk = deliveryPubkey.bytes;
    let dpkOr: uint64 = 0;
    for (let i: uint64 = 0; i < 32; i++) {
      dpkOr = dpkOr | op.getByte(dpk, i);
    }
    assert(dpkOr !== 0, "BAD_DELIVERY_PUBKEY");

    const head: uint64 = this.poolHead.value;
    const tail: uint64 = this.poolTail.value;
    assert(tail - head >= count, "POOL_EMPTY");

    const soldList = new arc4.DynamicArray<arc4.StaticBytes<32>>();
    const purchasedAtRound = new arc4.Uint64(Global.round);

    for (let i: uint64 = 0; i < count; i++) {
      const popIdx: uint64 = head + i;
      const idxKey = op.itob(popIdx);
      const pBox = this.salePool(idxKey);
      assert(pBox.exists, "BAD_STATE");
      const hash = pBox.value.bytes;

      const cBox = this.commitments(hash);
      assert(cBox.exists, "COMMITMENT_MISSING");
      const cPrev = clone(cBox.value);
      // Defensive: pool entries should always be unsold; abort if not.
      assert(cPrev.soldAtRound.asUint64() === 0, "ALREADY_SOLD");

      // Stamp the 1-year fuse. `redeem` checks this.
      cBox.value = new Commitment({
        denomination: cPrev.denomination,
        postedAtRound: cPrev.postedAtRound,
        soldAtRound: purchasedAtRound,
      });
      pBox.delete();

      soldList.push(new arc4.StaticBytes<32>(hash));
    }
    this.poolHead.value = head + count;

    emit(
      new CommitmentsSold({
        buyer: new arc4.Address(Txn.sender),
        deliveryPubkey,
        commitments: soldList,
        purchasedAtRound,
      }),
    );
  }

  /**
   * Private: enforce `purchaseCodes` group shape.
   *   - Group size == 2
   *   - This app-call at index 1
   *   - Txn 0 is Pay, sender == this app-call's sender (same buyer signs both)
   *   - Receiver == `Global.currentApplicationAddress` (revenue to app account)
   *   - Amount == `count × priceMicroAlgos`
   *   - closeRemainderTo == zero (no sweep)
   *   - rekeyTo == zero
   *
   * Distinct from `assertEscrowGroupShape` — buyer pays own fees here; no
   * treasury escrow involved. Revenue collects in the contract app account
   * and is swept by admin via the existing `withdrawTreasury` ABI.
   */
  private assertPurchaseGroupShape(count: uint64): void {
    assert(Global.groupSize === GROUP_SIZE_EXPECTED, "NOT_GROUP");
    assert(Txn.groupIndex === PURCHASE_APPCALL_INDEX, "BAD_GROUP_INDEX");
    const payTxn = gtxn.PaymentTxn(PURCHASE_PAY_INDEX);
    assert(payTxn.sender.bytes === Txn.sender.bytes, "BAD_PAYER");
    assert(
      payTxn.receiver.bytes === Global.currentApplicationAddress.bytes,
      "BAD_RECEIVER",
    );
    const expectedAmount: uint64 = count * this.priceMicroAlgos.value;
    assert(payTxn.amount === expectedAmount, "BAD_AMOUNT");
    assert(
      payTxn.closeRemainderTo.bytes === Global.zeroAddress.bytes,
      "BAD_CLOSE",
    );
    assert(payTxn.rekeyTo.bytes === Global.zeroAddress.bytes, "BAD_REKEY");
  }

  /**
   * Redeem a commitment from any wallet. Verifies the preimage hashes to a
   * live commitment box, deletes the box (atomic mark-spent — MBR refunds to
   * the contract account = treasury), grants credits to the caller's
   * UserState box, optionally seeds the caller's account MBR via inner-txn.
   *
   * Username slot is wired in slice S7 (T7.1). For now, any non-empty
   * `username` argument reverts with 'USERNAME_NOT_IMPL' so callers can detect
   * the partial implementation.
   */
  @arc4.abimethod()
  redeem(preimage: bytes, username: bytes): void {
    this.assertEscrowGroupShape();
    assert(preimage.length === PREIMAGE_LEN, "BAD_PREIMAGE");

    // Verify the commitment + mark spent atomically.
    const commitmentHash = op.sha256(preimage);
    const cBox = this.commitments(commitmentHash);
    assert(cBox.exists, "BAD_CODE");
    // 1-year expiry fuse for sale-pool codes. Unsold commitments
    // (`soldAtRound == 0`, admin promo / test path) have no shelf life.
    const sold: uint64 = cBox.value.soldAtRound.asUint64();
    if (sold > 0) {
      assert(Global.round <= sold + this.roundsPerYear.value, "CODE_EXPIRED");
    }
    const denomination = cBox.value.denomination;
    cBox.delete();

    // Username claim wired in slice S7. If username arg non-empty, claim it
    // before credit grant so reverse-index + creditState.username stay in sync.
    if (username.length > 0) {
      this.validateNameFormat(username);
      const nameKey = op.sha256(username);
      const nBox = this.names(nameKey);
      assert(!nBox.exists, "TAKEN");
      nBox.value = new arc4.Address(Txn.sender);
    }

    // Grant credits. Append a fresh batch (or create the credit box).
    const walletKey = Txn.sender.bytes;
    const cs = this.users(walletKey);
    const newBatch = new Batch({
      amount: denomination,
      expiryRound: new arc4.Uint64(Global.round + this.roundsPerYear.value),
    });

    if (cs.exists) {
      const prev = this.loadUser(walletKey);
      const prevCount: uint64 = prev.batchCount.asUint64();
      assert(prevCount < this.maxBatches.value, "TOO_MANY_BATCHES");
      prev.batches.push(newBatch);
      // If username arg non-empty here, caller already has a credit box but
      // may want to claim a name in same call. Only allow if slot empty;
      // renames go through claimUsername.
      let nextName = prev.username;
      if (username.length > 0) {
        assert(prev.username.length === 0, "USERNAME_SET");
        nextName = new arc4.DynamicBytes(username);
      }
      cs.value = new UserState({
        version: new arc4.Uint8(USER_STATE_VERSION),
        username: nextName,
        batchCount: new arc4.Uint8(prevCount + 1),
        batches: prev.batches,
        encryptionPubkey: prev.encryptionPubkey,
        scanPubkey: prev.scanPubkey,
        pqPubkeyHash: prev.pqPubkeyHash,
        bio: prev.bio,
      });
    } else {
      const batches = new arc4.DynamicArray<Batch>();
      batches.push(newBatch);
      cs.value = new UserState({
        version: new arc4.Uint8(USER_STATE_VERSION),
        username: new arc4.DynamicBytes(username),
        batchCount: new arc4.Uint8(1),
        batches,
        encryptionPubkey: new arc4.StaticBytes<32>(op.bzero(32)),
        scanPubkey: new arc4.StaticBytes<32>(op.bzero(32)),
        pqPubkeyHash: new arc4.StaticBytes<32>(op.bzero(32)),
        bio: new arc4.DynamicBytes(),
      });
    }

    // Seed account MBR for fresh wallets only.
    const balance: uint64 = op.balance(Txn.sender);
    if (balance < ACCOUNT_MBR_MIN) {
      const seedAmount: uint64 = ACCOUNT_MBR_MIN - balance;
      itxn
        .payment({
          receiver: Txn.sender,
          amount: seedAmount,
          fee: 0,
        })
        .submit();
    }

    emit(
      new Redeemed({
        commitment: new arc4.StaticBytes<32>(commitmentHash),
        denomination,
        wallet: new arc4.Address(Txn.sender),
        username: new arc4.DynamicBytes(username),
      }),
    );
  }

  /**
   * Spend one credit + emit ciphertext.
   *
   * Must be Txn 1 of a 2-txn group where Txn 0 is a treasury self-pay covering
   * the group fee. All fee accounting is treasury-side — user wallet pays 0.
   *
   * Expired batches are pruned (no MBR refund), then the oldest live batch is
   * decremented by 1 (or removed if the decrement empties it).
   */
  @arc4.abimethod()
  sendMessage(recipient_tag: arc4.StaticBytes<32>, ciphertext: bytes): void {
    this.assertEscrowGroupShape();
    // Discard remaining count — sendMessage skips CreditSpent emit to keep
    // ciphertext under the 1024B log budget.
    this.spendOneCredit(Txn.sender.bytes);
    // Emit ciphertext as raw ABI log. recipient_tag is visible in app args.
    log(ciphertext);
  }

  /**
   * Private: walk batches, prune expired, decrement oldest live batch by 1,
   * and WRITE the updated UserState back to the caller's box. Reverts
   * `NO_CREDITS` if no live batch found or if the user has no box.
   *
   * Preserves existing username + pubkey fields. Other callers that need to
   * additionally overlay their own field changes should read the box again
   * after this call and re-write — see `publishKeys`, `claimUsername`,
   * `releaseUsername`.
   */
  private spendOneCredit(walletKey: bytes): uint64 {
    const cs = this.users(walletKey);
    assert(cs.exists, "NO_CREDITS");

    const prev = this.loadUser(walletKey);
    const currentRound: uint64 = Global.round;
    const kept = new arc4.DynamicArray<Batch>();
    let decremented = false;
    let keptCount: uint64 = 0;
    let remaining: uint64 = 0;
    const prevCount: uint64 = prev.batchCount.asUint64();
    for (let i: uint64 = 0; i < prevCount; i++) {
      const b = clone(prev.batches[i]);
      const expiry: uint64 = b.expiryRound.asUint64();
      if (expiry <= currentRound) continue; // expired — drop
      if (!decremented) {
        const amount: uint64 = b.amount.asUint64();
        if (amount > 1) {
          kept.push(
            new Batch({
              amount: new arc4.Uint64(amount - 1),
              expiryRound: b.expiryRound,
            }),
          );
          keptCount = keptCount + 1;
          remaining = remaining + (amount - 1);
        }
        // amount == 1: skip (batch fully consumed)
        decremented = true;
      } else {
        kept.push(b);
        keptCount = keptCount + 1;
        remaining = remaining + b.amount.asUint64();
      }
    }
    assert(decremented, "NO_CREDITS");

    cs.value = new UserState({
      version: new arc4.Uint8(USER_STATE_VERSION),
      username: prev.username,
      batchCount: new arc4.Uint8(keptCount),
      batches: kept,
      encryptionPubkey: prev.encryptionPubkey,
      scanPubkey: prev.scanPubkey,
      pqPubkeyHash: prev.pqPubkeyHash,
      bio: prev.bio,
    });

    return remaining;
  }

  /**
   * Private: emit `CreditSpent` ARC28 event. Split from `spendOneCredit` so
   * `sendMessage` can skip it — sendMessage's ciphertext log alone can fill
   * the 1024-byte per-app-call log budget; an extra 44B event would push
   * 1KB payloads over the limit. publishKeys/claim/release emit it for the
   * indexer running-balance signal.
   */
  private emitCreditSpent(remaining: uint64): void {
    emit(
      new CreditSpent({
        wallet: new arc4.Address(Txn.sender),
        remaining: new arc4.Uint64(remaining),
      }),
    );
  }

  /**
   * Private: enforce universal escrow-group shape on user-mutating calls.
   *   - Group size == 2
   *   - This app-call sits at index 1
   *   - Txn 0 is a payment from treasury escrow paying >= GROUP_FEE_MIN
   *
   * Used by `redeem`, `sendMessage`, `publishKeys`, `claimUsername`,
   * `releaseUsername`, `setBio`. Admin-only methods (`registerCommitment`,
   * `withdrawTreasury`, `setTreasury`, `pruneExpired`, `update`) bypass this
   * — admins pay their own fee.
   */
  private assertEscrowGroupShape(): void {
    assert(Global.groupSize === GROUP_SIZE_EXPECTED, "NOT_GROUP");
    assert(Txn.groupIndex === APP_CALL_INDEX, "BAD_GROUP_INDEX");
    const feeTxn = gtxn.PaymentTxn(FEE_TXN_INDEX);
    assert(
      feeTxn.sender.bytes === this.treasuryAddress.value.bytes,
      "BAD_FEE_PAYER",
    );
    assert(feeTxn.fee >= GROUP_FEE_MIN, "BAD_FEE");
  }

  /**
   * Read + decode the `w:<addr>` box, lazily upgrading v2 wire bytes to the
   * v3 shape (empty bio). v2 boxes predate the `bio` field; their ARC4 head
   * is 102B (no bio offset slot). Rather than decoding field-by-field, the
   * raw v2 bytes are transformed into a valid v3 encoding — version byte
   * bumped, dynamic offsets shifted by the 2B the head grew, empty bio
   * appended — and reinterpreted. Cheap (a few concats), no loops.
   *
   * Read-only: callers persist v3 on their next box write. Reverts
   * NO_CREDITS when the box does not exist (matches `spendOneCredit`
   * semantics; readonly callers assert existence first with their own code).
   */
  private loadUser(walletKey: bytes): UserState {
    const [raw, exists] = op.Box.get(Bytes("w:").concat(walletKey));
    assert(exists, "NO_CREDITS");
    const version: uint64 = op.getByte(raw, 0);
    if (version === USER_STATE_VERSION) {
      return arc4.convertBytes<UserState>(raw, { strategy: "unsafe-cast" });
    }
    assert(version === 2, "BAD_VERSION");
    // v2 head (102B): ver u8 | unameOff u16 | batchCount u8 | batchesOff u16
    //                 | enc 32B | scan 32B | pqHash 32B
    // v3 head (104B): same + bioOff u16. Dynamic region shifts +2; empty bio
    // (2B zero length) lands after the copied dynamic region.
    const unameOff: uint64 = op.extractUint16(raw, 1);
    const batchesOff: uint64 = op.extractUint16(raw, 4);
    const v3 = Bytes.fromHex("03") // version 3
      .concat(u16be(unameOff + 2))
      .concat(raw.slice(3, 4)) // batchCount
      .concat(u16be(batchesOff + 2))
      .concat(raw.slice(6, 102)) // enc + scan + pqHash
      .concat(u16be(raw.length + 2)) // bioOff = 104 + (rawLen - 102)
      .concat(raw.slice(102, raw.length)) // dynamic region, verbatim
      .concat(u16be(0)); // empty bio
    return arc4.convertBytes<UserState>(v3, { strategy: "unsafe-cast" });
  }

  /**
   * Claim or rename a username for the caller. Caller must already have a
   * credit box (i.e. previously redeemed). If the username slot is empty,
   * this is a first claim; if non-empty, it is a rename that atomically
   * deletes the old reverse-index box and creates the new one (net MBR = 0).
   * v1: no cooldown.
   */
  @arc4.abimethod()
  claimUsername(username: bytes): void {
    this.assertEscrowGroupShape();
    // Pool extra opcode budget via opup inner-appl txns paid from group credit
    // (escrow self-pay overpays fees). Rename path walks batches + name bytes
    // + 2 box ops + sha256, can exceed the 700-op single-call budget.
    ensureBudget(2400, OpUpFeeSource.GroupCredit);
    this.validateNameFormat(username);

    // Spend 1 credit. Reverts NO_CREDITS if caller has no live batches.
    const remaining = this.spendOneCredit(Txn.sender.bytes);

    const walletKey = Txn.sender.bytes;
    const cs = this.users(walletKey);

    const newKey = op.sha256(username);
    const newBox = this.names(newKey);
    assert(!newBox.exists, "TAKEN");

    // Post-spend re-read: spendOneCredit already rewrote the box as v3.
    const prev = this.loadUser(walletKey);
    // Rename: delete old reverse-index box first.
    const oldName = prev.username;
    if (prev.username.length > 0) {
      const oldKey = op.sha256(prev.username.native);
      const oldBox = this.names(oldKey);
      assert(oldBox.exists, "BAD_STATE");
      // Ensure caller owns the old name.
      assert(oldBox.value.bytes === Txn.sender.bytes, "NOT_OWNER");
      oldBox.delete();
    }

    newBox.value = new arc4.Address(Txn.sender);
    cs.value = new UserState({
      version: new arc4.Uint8(USER_STATE_VERSION),
      username: new arc4.DynamicBytes(username),
      batchCount: prev.batchCount,
      batches: prev.batches,
      encryptionPubkey: prev.encryptionPubkey,
      scanPubkey: prev.scanPubkey,
      pqPubkeyHash: prev.pqPubkeyHash,
      bio: prev.bio,
    });

    emit(
      new UsernameClaimed({
        wallet: new arc4.Address(Txn.sender),
        oldName,
        newName: new arc4.DynamicBytes(username),
      }),
    );
    this.emitCreditSpent(remaining);
  }

  /**
   * Clear the caller's username slot. Deletes the reverse-index box (MBR
   * refunds to contract account). Reverts if caller has no name set.
   */
  @arc4.abimethod()
  releaseUsername(): void {
    this.assertEscrowGroupShape();
    // Pool extra opcode budget — release walks batches + decodes username +
    // hashes + 1 box delete. See claimUsername note.
    ensureBudget(2400, OpUpFeeSource.GroupCredit);
    const remaining = this.spendOneCredit(Txn.sender.bytes);

    const walletKey = Txn.sender.bytes;
    const cs = this.users(walletKey);

    // Post-spend re-read: spendOneCredit already rewrote the box as v3.
    const prev = this.loadUser(walletKey);
    assert(prev.username.length > 0, "NO_USERNAME");

    const oldKey = op.sha256(prev.username.native);
    const oldBox = this.names(oldKey);
    assert(oldBox.exists, "BAD_STATE");
    assert(oldBox.value.bytes === Txn.sender.bytes, "NOT_OWNER");
    oldBox.delete();

    const releasedName = prev.username;

    cs.value = new UserState({
      version: new arc4.Uint8(USER_STATE_VERSION),
      username: new arc4.DynamicBytes(),
      batchCount: prev.batchCount,
      batches: prev.batches,
      encryptionPubkey: prev.encryptionPubkey,
      scanPubkey: prev.scanPubkey,
      pqPubkeyHash: prev.pqPubkeyHash,
      bio: prev.bio,
    });

    emit(
      new UsernameReleased({
        wallet: new arc4.Address(Txn.sender),
        name: releasedName,
      }),
    );
    this.emitCreditSpent(remaining);
  }

  /**
   * Set or clear the caller's public profile bio. Free-form UTF-8, length
   * capped at BIO_MAX bytes; empty input clears the field. Content policy
   * (control chars etc.) is client-side — the chain validates length only.
   * Bio is PUBLIC on-chain plaintext, same exposure as username.
   *
   * Universal escrow group: must be Txn 1 of `[escrowSelfPay, appCall]`.
   * Spends 1 credit like the other identity-mutating ops; emits `BioChanged`
   * + `CreditSpent`.
   */
  @arc4.abimethod()
  setBio(bio: bytes): void {
    this.assertEscrowGroupShape();
    // Pool extra opcode budget — credit-spend walk + potential v2→v3
    // transform + full box rewrite. See claimUsername note.
    ensureBudget(2400, OpUpFeeSource.GroupCredit);
    assert(bio.length <= BIO_MAX, "BIO_TOO_LONG");

    // Spend 1 credit. Reverts NO_CREDITS if caller has no live batches.
    const remaining = this.spendOneCredit(Txn.sender.bytes);

    // Post-spend re-read: spendOneCredit already rewrote the box as v3.
    const cs = this.users(Txn.sender.bytes);
    const prev = this.loadUser(Txn.sender.bytes);
    cs.value = new UserState({
      version: new arc4.Uint8(USER_STATE_VERSION),
      username: prev.username,
      batchCount: prev.batchCount,
      batches: prev.batches,
      encryptionPubkey: prev.encryptionPubkey,
      scanPubkey: prev.scanPubkey,
      pqPubkeyHash: prev.pqPubkeyHash,
      bio: new arc4.DynamicBytes(bio),
    });

    emit(
      new BioChanged({
        wallet: new arc4.Address(Txn.sender),
        bio: new arc4.DynamicBytes(bio),
      }),
    );
    this.emitCreditSpent(remaining);
  }

  /** Readonly: resolve a username to its owning wallet. Reverts if unset. */
  @arc4.abimethod({ readonly: true })
  resolveUsername(username: bytes): arc4.Address {
    const key = op.sha256(username);
    const box = this.names(key);
    assert(box.exists, "NOT_FOUND");
    return box.value;
  }

  /** Validate username format. a-z, 0-9, '_'. No leading/trailing underscore. */
  private validateNameFormat(name: bytes): void {
    const len = name.length;
    assert(len >= NAME_MIN, "BAD_LEN");
    assert(len <= NAME_MAX, "BAD_LEN");

    assert(op.getByte(name, 0) !== BYTE_UNDERSCORE, "LEADING_UNDERSCORE");

    assert(
      op.getByte(name, len - 1) !== BYTE_UNDERSCORE,
      "TRAILING_UNDERSCORE",
    );

    for (let i: uint64 = 0; i < len; i++) {
      const b = op.getByte(name, i);
      const isAlpha = b >= BYTE_ALPHA_LO && b <= BYTE_ALPHA_HI;
      const isDigit = b >= BYTE_DIGIT_LO && b <= BYTE_DIGIT_HI;
      const isUnderscore = b === BYTE_UNDERSCORE;
      assert(isAlpha || isDigit || isUnderscore, "BAD_CHAR");
    }
  }

  /**
   * Drop all expired batches from `wallet`'s credit box. Anyone callable; v1
   * has no keeper bounty, treasury cron runs it. Reverts `NO_CREDITS` if the
   * target has no credit box.
   */
  @arc4.abimethod()
  pruneExpired(wallet: arc4.Address): void {
    const walletKey = wallet.bytes;
    const cs = this.users(walletKey);
    assert(cs.exists, "NO_CREDITS");

    const prev = this.loadUser(walletKey);
    const currentRound: uint64 = Global.round;
    const prevCount: uint64 = prev.batchCount.asUint64();

    const kept = new arc4.DynamicArray<Batch>();
    let keptCount: uint64 = 0;
    for (let i: uint64 = 0; i < prevCount; i++) {
      const b = clone(prev.batches[i]);
      const expiry: uint64 = b.expiryRound.asUint64();
      if (expiry <= currentRound) continue;
      kept.push(b);
      keptCount = keptCount + 1;
    }

    cs.value = new UserState({
      version: new arc4.Uint8(USER_STATE_VERSION),
      username: prev.username,
      batchCount: new arc4.Uint8(keptCount),
      batches: kept,
      encryptionPubkey: prev.encryptionPubkey,
      scanPubkey: prev.scanPubkey,
      pqPubkeyHash: prev.pqPubkeyHash,
      bio: prev.bio,
    });
  }

  /**
   * Readonly: sum non-expired batch amounts for `wallet`. Returns 0 if no
   * credit box exists (no revert — read path stays cheap).
   */
  @arc4.abimethod({ readonly: true })
  getCredits(wallet: arc4.Address): arc4.Uint64 {
    const walletKey = wallet.bytes;
    const cs = this.users(walletKey);
    if (!cs.exists) {
      return new arc4.Uint64(0);
    }

    const state = this.loadUser(walletKey);
    const currentRound: uint64 = Global.round;
    const count: uint64 = state.batchCount.asUint64();

    let total: uint64 = 0;
    for (let i: uint64 = 0; i < count; i++) {
      const b = clone(state.batches[i]);
      const expiry: uint64 = b.expiryRound.asUint64();
      if (expiry <= currentRound) continue;
      total = total + b.amount.asUint64();
    }
    return new arc4.Uint64(total);
  }

  /**
   * Admin-only: drain contract account balance to `receiver`. Used to move
   * TestNet treasury funds out, or to top up a redeployed escrow after an
   * Algorand min-fee bump. Inner-txn fee is 0; caller fee-pools.
   */
  @arc4.abimethod()
  withdrawTreasury(amount: arc4.Uint64, receiver: arc4.Address): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    itxn
      .payment({
        receiver: receiver.native,
        amount: amount.asUint64(),
        fee: 0,
      })
      .submit();
  }

  /**
   * Creator-only rotate of `treasuryAddress`. Used when LogicSig escrow is
   * redeployed after a min-fee bump.
   */
  @arc4.abimethod()
  setTreasury(newEscrow: arc4.Address): void {
    assert(Txn.sender.bytes === Global.creatorAddress.bytes, "NOT_CREATOR");
    this.treasuryAddress.value = newEscrow;
  }

  /**
   * Publish all cryptographic keys, anchor `pqPubkeyHash` on-chain, emit full
   * pq pubkey in `KeysPublished` event log (indexer caches it; clients verify
   * hash against on-chain anchor before trusting indexer-served key).
   *
   * Universal escrow group: must be Txn 1 of `[escrowSelfPay, appCall]`.
   * Caller must have prior credits (redeemed first); spends 1 credit.
   */
  @arc4.abimethod()
  publishKeys(
    encryptionPubkey: arc4.StaticBytes<32>,
    scanPubkey: arc4.StaticBytes<32>,
    pqPubkey: bytes,
  ): void {
    this.assertEscrowGroupShape();
    assert(pqPubkey.length >= 32, "PQ_KEY_TOO_SHORT");
    assert(pqPubkey.length <= 2048, "PQ_KEY_TOO_LONG");
    const pqHashBytes = op.sha256(pqPubkey);
    const pqHash = new arc4.StaticBytes<32>(pqHashBytes);

    // Spend a credit (reverts NO_CREDITS if user never redeemed or empty).
    const remaining = this.spendOneCredit(Txn.sender.bytes);

    // Re-read the (post-spend, already-v3) state and overlay key fields.
    const cs = this.users(Txn.sender.bytes);
    const prev = this.loadUser(Txn.sender.bytes);
    cs.value = new UserState({
      version: new arc4.Uint8(USER_STATE_VERSION),
      username: prev.username,
      batchCount: prev.batchCount,
      batches: prev.batches,
      encryptionPubkey,
      scanPubkey,
      pqPubkeyHash: pqHash,
      bio: prev.bio,
    });

    emit(
      new KeysPublished({
        wallet: new arc4.Address(Txn.sender),
        encryptionPubkey,
        scanPubkey,
        pqPubkey: new arc4.DynamicBytes(pqPubkey),
        pqPubkeyHash: pqHash,
      }),
    );
    this.emitCreditSpent(remaining);
  }

  /**
   * Sponsored onboarding: redeem a code AND publish keys in one atomic call,
   * without spending a credit on the publish leg. Caller ends up with exactly
   * `denomination` credits (500 for sale-pool codes) plus all three key
   * fields set — single signature, no "you have 499 credits" surprise.
   *
   * Same escrow-group shape as `redeem` (Txn 0 = treasury self-pay covering
   * fee pool, Txn 1 = this app-call). Recommended escrow fee pool = 5×minFee
   * to cover commitment delete + UserState write + KeysPublished log (up to
   * 2048B pqPub) + sha256 + optional MBR-seed inner-txn for 0-ALGO wallets.
   *
   * Existing `redeem` + `publishKeys` ABIs are untouched — used by tests,
   * admin promo, and key-rotation (re-key) flows where credits already exist.
   *
   * Always claims no username (empty); use `claimUsername` separately.
   */
  @arc4.abimethod()
  redeemAndPublish(
    preimage: bytes,
    encryptionPubkey: arc4.StaticBytes<32>,
    scanPubkey: arc4.StaticBytes<32>,
    pqPubkey: bytes,
  ): void {
    this.assertEscrowGroupShape();
    assert(preimage.length === PREIMAGE_LEN, "BAD_PREIMAGE");
    assert(pqPubkey.length >= 32, "PQ_KEY_TOO_SHORT");
    assert(pqPubkey.length <= 2048, "PQ_KEY_TOO_LONG");

    // Verify commitment + expiry fuse + grab denomination.
    const commitmentHash = op.sha256(preimage);
    const cBox = this.commitments(commitmentHash);
    assert(cBox.exists, "BAD_CODE");
    const sold: uint64 = cBox.value.soldAtRound.asUint64();
    if (sold > 0) {
      assert(Global.round <= sold + this.roundsPerYear.value, "CODE_EXPIRED");
    }
    const denomination = cBox.value.denomination;
    cBox.delete();

    const pqHashBytes = op.sha256(pqPubkey);
    const pqHash = new arc4.StaticBytes<32>(pqHashBytes);

    // Mint credit batch + set keys in one UserState write.
    const walletKey = Txn.sender.bytes;
    const cs = this.users(walletKey);
    const newBatch = new Batch({
      amount: denomination,
      expiryRound: new arc4.Uint64(Global.round + this.roundsPerYear.value),
    });

    if (cs.exists) {
      const prev = this.loadUser(walletKey);
      const prevCount: uint64 = prev.batchCount.asUint64();
      assert(prevCount < this.maxBatches.value, "TOO_MANY_BATCHES");
      prev.batches.push(newBatch);
      cs.value = new UserState({
        version: new arc4.Uint8(USER_STATE_VERSION),
        username: prev.username,
        batchCount: new arc4.Uint8(prevCount + 1),
        batches: prev.batches,
        encryptionPubkey,
        scanPubkey,
        pqPubkeyHash: pqHash,
        bio: prev.bio,
      });
    } else {
      const batches = new arc4.DynamicArray<Batch>();
      batches.push(newBatch);
      cs.value = new UserState({
        version: new arc4.Uint8(USER_STATE_VERSION),
        username: new arc4.DynamicBytes(),
        batchCount: new arc4.Uint8(1),
        batches,
        encryptionPubkey,
        scanPubkey,
        pqPubkeyHash: pqHash,
        bio: new arc4.DynamicBytes(),
      });
    }

    // MBR seed for 0-ALGO wallets — mirrors `redeem`.
    const balance: uint64 = op.balance(Txn.sender);
    if (balance < ACCOUNT_MBR_MIN) {
      const seedAmount: uint64 = ACCOUNT_MBR_MIN - balance;
      itxn
        .payment({
          receiver: Txn.sender,
          amount: seedAmount,
          fee: 0,
        })
        .submit();
    }

    emit(
      new Redeemed({
        commitment: new arc4.StaticBytes<32>(commitmentHash),
        denomination,
        wallet: new arc4.Address(Txn.sender),
        username: new arc4.DynamicBytes(),
      }),
    );
    emit(
      new KeysPublished({
        wallet: new arc4.Address(Txn.sender),
        encryptionPubkey,
        scanPubkey,
        pqPubkey: new arc4.DynamicBytes(pqPubkey),
        pqPubkeyHash: pqHash,
      }),
    );
  }

  /**
   * Readonly: return full UserState struct for `wallet`. Reverts if no box.
   * Off-chain callers prefer reading the box directly via algod; this method
   * exists for ABI completeness + on-chain composability (other contracts).
   */
  @arc4.abimethod({ readonly: true })
  getUserProfile(wallet: arc4.Address): UserState {
    const cs = this.users(wallet.bytes);
    assert(cs.exists, "NOT_FOUND");
    return this.loadUser(wallet.bytes);
  }

  /**
   * Readonly: return only the key triple for `wallet`. Cheaper return shape
   * than full profile when caller only needs pubkeys for an envelope. Reverts
   * if no box.
   */
  @arc4.abimethod({ readonly: true })
  getUserKeys(wallet: arc4.Address): UserKeys {
    const cs = this.users(wallet.bytes);
    assert(cs.exists, "NOT_FOUND");
    const state = this.loadUser(wallet.bytes);
    return new UserKeys({
      encryptionPubkey: state.encryptionPubkey,
      scanPubkey: state.scanPubkey,
      pqPubkeyHash: state.pqPubkeyHash,
    });
  }

  @arc4.baremethod({ allowActions: ["UpdateApplication"] })
  update(): void {
    assert(Txn.sender.bytes === Global.creatorAddress.bytes, "NOT_CREATOR");
  }

  /**
   * One-shot post-`update()` migration for an existing v1 app upgraded to v2
   * monetization wire layout. `update` does NOT re-run `createApplication`,
   * so the three new globals (`priceMicroAlgos`, `poolHead`, `poolTail`) are
   * left unset. Reading them via the v2 approval program before they're
   * written can revert. Admin calls `migrate_v2(initialPrice)` immediately
   * after `update()` to seed them.
   *
   * Sets `priceMicroAlgos = initialPrice`, `poolHead = 0`, `poolTail = 0`.
   * No idempotency guard — admin's responsibility to call once. A duplicate
   * call with the same `initialPrice` is a no-op write; with a different
   * price it acts like `setPrice` (still admin-gated, still bounds-checked).
   *
   * Bounds-check matches `setPrice` to guard against fat-finger.
   */
  @arc4.abimethod()
  migrate_v2(initialPrice: arc4.Uint64): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    const np: uint64 = initialPrice.asUint64();
    assert(np >= PRICE_FLOOR, "BAD_PRICE");
    assert(np <= PRICE_CEILING, "BAD_PRICE");
    this.priceMicroAlgos.value = np;
    this.poolHead.value = 0;
    this.poolTail.value = 0;
  }

  /**
   * Admin force-deletes `c:<hash>` commitment boxes by key, WITHOUT reading
   * the box value. Safe for v1-layout (16B value) boxes that the v2 ARC4
   * deserializer would reject — `box_del` only takes the key. Used to drain
   * stale pre-`migrate_v2` commitments so MBR refunds to the app account
   * and the pool/redeem paths stop tripping over old entries.
   *
   * Capped at 8 per call (one box ref per entry, AVM cap).
   */
  @arc4.abimethod()
  forceDeleteCommitment(
    commitments: arc4.DynamicArray<arc4.StaticBytes<32>>,
  ): void {
    assert(Txn.sender.bytes === this.adminAddress.value.bytes, "NOT_ADMIN");
    const count: uint64 = commitments.length;
    assert(count > 0, "EMPTY_BATCH");
    assert(count <= MAX_RECLAIM_BATCH, "BATCH_TOO_LARGE");
    for (let i: uint64 = 0; i < count; i++) {
      const hash = commitments[i].bytes;
      const cBox = this.commitments(hash);
      if (cBox.exists) {
        cBox.delete();
      }
    }
  }

  /**
   * Test-only ABI exposing the bare Groth16 verifier. Lets CI drive
   * `verifyGroth16` against committed golden vectors without the surrounding
   * `redeemWithProof` flow (which lands in T5). Returns `true`/`false` so a
   * failing proof does NOT revert here — the caller asserts on the return
   * value.
   *
   * Safe to ship: leaks no state, takes no side effects, and only validates
   * proofs against the embedded vk. Production callers (`redeemWithProof`)
   * should depend on the underlying `verifyGroth16` import directly, not on
   * this wrapper.
   */
  @arc4.abimethod({ readonly: false })
  _verifyProofForTest(proof: bytes, publicInputs: bytes): boolean {
    ensureSnarkBudget();
    return verifyGroth16(proof, publicInputs);
  }
}

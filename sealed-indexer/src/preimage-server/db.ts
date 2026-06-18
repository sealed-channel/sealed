/**
 * Sqlite persistence for the monetization-v1 preimage-server sidecar.
 *
 * Two tables:
 *
 *  - `preimages`
 *      One row per generated redeem code. Created `available` by the admin
 *      CLI (`generate-batch`). Transitions to `sold` when the watcher sees
 *      the matching `CommitmentsSold` event, then to `delivered` after the
 *      buyer first fetches the ciphertext through the OHTTP relay.
 *
 *      Plaintext `preimage` is cleared on the `sold → delivered` transition;
 *      only `ciphertext` remains so re-fetches stay idempotent.
 *
 *  - `watcher_checkpoint`
 *      Single-row table holding the last round the CommitmentsSold watcher
 *      successfully processed. Mirrors `cursor-store` convention so the
 *      sidecar resumes after restart instead of rescanning from genesis.
 *
 * Round numbers are stored as TEXT to safely round-trip uint64 values that
 * exceed `Number.MAX_SAFE_INTEGER` (matches `cursor-store.ts`).
 *
 * Status transitions are enforced in SQL with `WHERE status = '<prev>'`
 * guards so concurrent watcher writes are idempotent — replaying an event
 * is a no-op, not a corruption.
 */

import Database from 'better-sqlite3';

export type PreimageStatus = 'available' | 'sold' | 'delivered';

export interface PreimageRow {
  commitmentHash: Uint8Array;
  /** Cleared (null) after the `sold → delivered` transition. */
  preimage: Uint8Array | null;
  /**
   * The 16-char normalized Crockford-b32 code (no dashes, no I/L/O). The
   * watcher seals this list into the buyer's ciphertext at the
   * `available → sold` transition; once the buyer fetches and we mark the
   * row `delivered`, both `preimage` and `code` are cleared and only
   * `ciphertext` remains for idempotent refetch.
   */
  code: string | null;
  status: PreimageStatus;
  soldAtRound: bigint | null;
  ciphertext: Uint8Array | null;
  deliveryKeySha256: Uint8Array | null;
  deliveredAtRound: bigint | null;
}

export interface MarkSoldArgs {
  commitmentHash: Uint8Array;
  soldAtRound: bigint;
  deliveryKeySha256: Uint8Array;
  ciphertext: Uint8Array;
}

/** Thrown by `reserveAndPick` when fewer than `qty` rows are `available`. */
export class InsufficientInventoryError extends Error {
  constructor(
    readonly available: number,
    readonly requested: number,
  ) {
    super(`insufficient inventory: ${available} available, ${requested} requested`);
    this.name = 'InsufficientInventoryError';
  }
}

/** Thrown by `reserveAndPick` when the payment txid was already reserved. */
export class DuplicatePaymentError extends Error {
  constructor(readonly txid: string) {
    super(`payment already reserved: ${txid}`);
    this.name = 'DuplicatePaymentError';
  }
}

export interface ReserveAndPickArgs {
  paymentTxid: string;
  deliveryKeySha256: Uint8Array;
  qty: number;
  soldAtRound: bigint;
  round: bigint;
}

export interface RecordUnfulfilledArgs {
  paymentTxid: string;
  sender?: string;
  amount?: bigint;
  reason: string;
  round: bigint;
}

export interface PreimageStore {
  /**
   * Insert a freshly minted code. Throws on duplicate `commitmentHash`.
   *
   * `code` is the 16-char normalized Crockford-b32 form (no dashes,
   * no I/L/O). The watcher will seal this into the buyer's ciphertext;
   * dashed display formatting is re-derived at delivery time.
   */
  insertAvailable(commitmentHash: Uint8Array, preimage: Uint8Array, code: string): void;

  /** Read a single row by commitment hash. */
  getByCommitment(commitmentHash: Uint8Array): PreimageRow | null;

  /**
   * Transition `available → sold`. Returns 1 if the row was updated, 0 if
   * not (already sold, already delivered, or no such row). Replaying the
   * same event is a no-op by design.
   */
  markSold(args: MarkSoldArgs): number;

  /**
   * Transition `sold → delivered` for every row keyed by the given delivery
   * key. Clears `preimage` to NULL. Returns the count of rows updated.
   * Idempotent — already-delivered rows are skipped.
   */
  markDelivered(deliveryKeySha256: Uint8Array, deliveredAtRound: bigint): number;

  /**
   * Look up the ciphertext for a purchase by `sha256(deliveryPubkey)`.
   * Returns `null` if no sold/delivered row matches.
   */
  getCiphertextByDeliveryKey(deliveryKeySha256: Uint8Array): Uint8Array | null;

  /** Count rows still `available` for sale (SNARK-sold inventory / `/stock`). */
  countAvailable(): number;

  /**
   * Atomically reserve `qty` `available` rows for a payment, transitioning
   * them `available → sold` (with `delivery_key_sha256` + `sold_at_round`,
   * `ciphertext` left NULL until `fillCiphertext`). Records the payment txid
   * for idempotency. Returns the reserved code strings (caller seals them).
   *
   * Throws `DuplicatePaymentError` if `paymentTxid` was already reserved, and
   * `InsufficientInventoryError` (rolling back the whole reservation) if fewer
   * than `qty` rows are available. The entire body runs in one sqlite
   * transaction so a crash or shortfall never half-allocates inventory.
   */
  reserveAndPick(args: ReserveAndPickArgs): string[];

  /**
   * Write the sealed `ciphertext` onto the rows reserved under
   * `deliveryKeySha256` (only those still `sold` with NULL ciphertext).
   * Returns rows updated. Re-runnable for crash recovery.
   */
  fillCiphertext(deliveryKeySha256: Uint8Array, ciphertext: Uint8Array): number;

  /** True if any row under this delivery key already has a ciphertext. */
  hasCiphertext(deliveryKeySha256: Uint8Array): boolean;

  /** Code strings of the `sold` rows under this delivery key (for re-seal recovery). */
  getCodesByDeliveryKey(deliveryKeySha256: Uint8Array): string[];

  /** Lookup a prior payment reservation by txid (idempotency / recovery). */
  getPaymentDelivery(
    paymentTxid: string,
  ): { deliveryKeySha256: Uint8Array; qty: number; round: bigint } | null;

  /** Record a payment we could not fulfil (bad amount/note, no stock) for manual refund. */
  recordUnfulfilled(args: RecordUnfulfilledArgs): void;

  getWatcherCheckpoint(): bigint | null;
  setWatcherCheckpoint(round: bigint): void;

  close(): void;
}

const SCHEMA_SQL = `
  CREATE TABLE IF NOT EXISTS preimages (
    commitment_hash      BLOB PRIMARY KEY,
    preimage             BLOB,
    code                 TEXT,
    status               TEXT NOT NULL CHECK (status IN ('available','sold','delivered')),
    sold_at_round        TEXT,
    ciphertext           BLOB,
    delivery_key_sha256  BLOB,
    delivered_at_round   TEXT
  );
  CREATE INDEX IF NOT EXISTS preimages_delivery_key
    ON preimages(delivery_key_sha256);
  CREATE TABLE IF NOT EXISTS watcher_checkpoint (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    last_round  TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS payment_deliveries (
    payment_txid         TEXT PRIMARY KEY,
    delivery_key_sha256  BLOB NOT NULL,
    qty                  INTEGER NOT NULL,
    round                TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS unfulfilled_payments (
    payment_txid  TEXT PRIMARY KEY,
    sender        TEXT,
    amount        TEXT,
    reason        TEXT NOT NULL,
    round         TEXT NOT NULL
  );
`;

interface PreimageDbRow {
  commitment_hash: Buffer;
  preimage: Buffer | null;
  code: string | null;
  status: PreimageStatus;
  sold_at_round: string | null;
  ciphertext: Buffer | null;
  delivery_key_sha256: Buffer | null;
  delivered_at_round: string | null;
}

function toUint8Array(buf: Buffer | null): Uint8Array | null {
  if (buf === null) return null;
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
}

function toBigInt(s: string | null): bigint | null {
  if (s === null) return null;
  try {
    return BigInt(s);
  } catch {
    return null;
  }
}

function rowFromDb(row: PreimageDbRow): PreimageRow {
  return {
    commitmentHash: new Uint8Array(row.commitment_hash),
    preimage: toUint8Array(row.preimage),
    code: row.code,
    status: row.status,
    soldAtRound: toBigInt(row.sold_at_round),
    ciphertext: toUint8Array(row.ciphertext),
    deliveryKeySha256: toUint8Array(row.delivery_key_sha256),
    deliveredAtRound: toBigInt(row.delivered_at_round),
  };
}

function assertNonNegative(round: bigint, label: string): void {
  if (round < 0n) throw new Error(`${label} must be non-negative`);
}

function asBuffer(bytes: Uint8Array): Buffer {
  return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

export function createPreimageStore(dbPath: string): PreimageStore {
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA_SQL);

  const insertStmt = db.prepare(
    `INSERT INTO preimages (commitment_hash, preimage, code, status)
     VALUES (?, ?, ?, 'available')`,
  );

  const getByCommitmentStmt = db.prepare<[Buffer], PreimageDbRow>(
    `SELECT commitment_hash, preimage, code, status, sold_at_round,
            ciphertext, delivery_key_sha256, delivered_at_round
       FROM preimages
      WHERE commitment_hash = ?`,
  );

  const markSoldStmt = db.prepare(
    `UPDATE preimages
        SET status = 'sold',
            sold_at_round = ?,
            delivery_key_sha256 = ?,
            ciphertext = ?
      WHERE commitment_hash = ?
        AND status = 'available'`,
  );

  const markDeliveredStmt = db.prepare(
    `UPDATE preimages
        SET status = 'delivered',
            delivered_at_round = ?,
            preimage = NULL,
            code = NULL
      WHERE delivery_key_sha256 = ?
        AND status = 'sold'`,
  );

  const getCiphertextStmt = db.prepare<[Buffer], { ciphertext: Buffer | null }>(
    `SELECT ciphertext
       FROM preimages
      WHERE delivery_key_sha256 = ?
        AND status IN ('sold','delivered')
      LIMIT 1`,
  );

  const getCheckpointStmt = db.prepare<[], { last_round: string }>(
    `SELECT last_round FROM watcher_checkpoint WHERE id = 1`,
  );
  const upsertCheckpointStmt = db.prepare(
    `INSERT INTO watcher_checkpoint (id, last_round) VALUES (1, ?)
       ON CONFLICT(id) DO UPDATE SET last_round = excluded.last_round`,
  );

  const countAvailableStmt = db.prepare<[], { n: number }>(
    `SELECT COUNT(*) AS n FROM preimages WHERE status = 'available'`,
  );

  const selectAvailableStmt = db.prepare<[number], { commitment_hash: Buffer; code: string }>(
    `SELECT commitment_hash, code FROM preimages
      WHERE status = 'available' ORDER BY rowid LIMIT ?`,
  );

  // Reserve one row: available → sold with delivery key + round, ciphertext
  // left NULL (filled after the async HPKE seal). The status guard makes the
  // per-row claim atomic against any concurrent writer.
  const reserveRowStmt = db.prepare(
    `UPDATE preimages
        SET status = 'sold', sold_at_round = ?, delivery_key_sha256 = ?
      WHERE commitment_hash = ? AND status = 'available'`,
  );

  const insertPaymentDeliveryStmt = db.prepare(
    `INSERT INTO payment_deliveries (payment_txid, delivery_key_sha256, qty, round)
     VALUES (?, ?, ?, ?)`,
  );

  const getPaymentDeliveryStmt = db.prepare<
    [string],
    { delivery_key_sha256: Buffer; qty: number; round: string }
  >(
    `SELECT delivery_key_sha256, qty, round FROM payment_deliveries WHERE payment_txid = ?`,
  );

  const fillCiphertextStmt = db.prepare(
    `UPDATE preimages SET ciphertext = ?
      WHERE delivery_key_sha256 = ? AND status = 'sold' AND ciphertext IS NULL`,
  );

  const hasCiphertextStmt = db.prepare<[Buffer], { one: number }>(
    `SELECT 1 AS one FROM preimages
      WHERE delivery_key_sha256 = ? AND ciphertext IS NOT NULL LIMIT 1`,
  );

  const codesByDeliveryKeyStmt = db.prepare<[Buffer], { code: string | null }>(
    `SELECT code FROM preimages
      WHERE delivery_key_sha256 = ? AND code IS NOT NULL ORDER BY rowid`,
  );

  const recordUnfulfilledStmt = db.prepare(
    `INSERT OR IGNORE INTO unfulfilled_payments
       (payment_txid, sender, amount, reason, round)
     VALUES (?, ?, ?, ?, ?)`,
  );

  // Whole reservation runs in one transaction: claim the txid, lock qty rows,
  // or roll the lot back on shortfall / duplicate.
  const reserveAndPickTxn = db.transaction(
    (paymentTxid: string, deliveryKeyBuf: Buffer, qty: number, soldAtRound: string): string[] => {
      try {
        insertPaymentDeliveryStmt.run(paymentTxid, deliveryKeyBuf, qty, soldAtRound);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (/UNIQUE|PRIMARY KEY/i.test(msg)) throw new DuplicatePaymentError(paymentTxid);
        throw e;
      }
      const avail = selectAvailableStmt.all(qty);
      if (avail.length < qty) throw new InsufficientInventoryError(avail.length, qty);
      const codes: string[] = [];
      for (const r of avail) {
        const info = reserveRowStmt.run(soldAtRound, deliveryKeyBuf, r.commitment_hash);
        if (info.changes !== 1) {
          // Should be impossible inside the txn; abort to avoid a partial claim.
          throw new Error('reservation race: row not available at UPDATE time');
        }
        codes.push(r.code);
      }
      return codes;
    },
  );

  return {
    insertAvailable(commitmentHash, preimage, code) {
      if (commitmentHash.length !== 32) {
        throw new Error(`commitmentHash must be 32 bytes (got ${commitmentHash.length})`);
      }
      if (preimage.length !== 16) {
        throw new Error(`preimage must be 16 bytes (got ${preimage.length})`);
      }
      if (typeof code !== 'string' || code.length !== 16) {
        throw new Error(`code must be a 16-char string (got ${typeof code === 'string' ? code.length : typeof code})`);
      }
      insertStmt.run(asBuffer(commitmentHash), asBuffer(preimage), code);
    },

    getByCommitment(commitmentHash) {
      const row = getByCommitmentStmt.get(asBuffer(commitmentHash));
      return row ? rowFromDb(row) : null;
    },

    markSold({ commitmentHash, soldAtRound, deliveryKeySha256, ciphertext }) {
      assertNonNegative(soldAtRound, 'soldAtRound');
      if (deliveryKeySha256.length !== 32) {
        throw new Error('deliveryKeySha256 must be 32 bytes');
      }
      if (ciphertext.length === 0) {
        throw new Error('ciphertext must be non-empty');
      }
      const info = markSoldStmt.run(
        soldAtRound.toString(),
        asBuffer(deliveryKeySha256),
        asBuffer(ciphertext),
        asBuffer(commitmentHash),
      );
      return info.changes;
    },

    markDelivered(deliveryKeySha256, deliveredAtRound) {
      assertNonNegative(deliveredAtRound, 'deliveredAtRound');
      const info = markDeliveredStmt.run(
        deliveredAtRound.toString(),
        asBuffer(deliveryKeySha256),
      );
      return info.changes;
    },

    getCiphertextByDeliveryKey(deliveryKeySha256) {
      const row = getCiphertextStmt.get(asBuffer(deliveryKeySha256));
      if (!row || !row.ciphertext) return null;
      return new Uint8Array(row.ciphertext);
    },

    countAvailable() {
      return countAvailableStmt.get()?.n ?? 0;
    },

    reserveAndPick({ paymentTxid, deliveryKeySha256, qty, soldAtRound, round }) {
      if (deliveryKeySha256.length !== 32) throw new Error('deliveryKeySha256 must be 32 bytes');
      if (!Number.isInteger(qty) || qty < 1) throw new Error('qty must be a positive integer');
      assertNonNegative(soldAtRound, 'soldAtRound');
      assertNonNegative(round, 'round');
      void round; // reserved for future per-reservation audit; kept in the API for symmetry
      return reserveAndPickTxn(
        paymentTxid,
        asBuffer(deliveryKeySha256),
        qty,
        soldAtRound.toString(),
      );
    },

    fillCiphertext(deliveryKeySha256, ciphertext) {
      if (deliveryKeySha256.length !== 32) throw new Error('deliveryKeySha256 must be 32 bytes');
      if (ciphertext.length === 0) throw new Error('ciphertext must be non-empty');
      return fillCiphertextStmt.run(asBuffer(ciphertext), asBuffer(deliveryKeySha256)).changes;
    },

    hasCiphertext(deliveryKeySha256) {
      return hasCiphertextStmt.get(asBuffer(deliveryKeySha256)) !== undefined;
    },

    getCodesByDeliveryKey(deliveryKeySha256) {
      return codesByDeliveryKeyStmt
        .all(asBuffer(deliveryKeySha256))
        .map((r) => r.code)
        .filter((c): c is string => typeof c === 'string');
    },

    getPaymentDelivery(paymentTxid) {
      const row = getPaymentDeliveryStmt.get(paymentTxid);
      if (!row) return null;
      return {
        deliveryKeySha256: new Uint8Array(row.delivery_key_sha256),
        qty: row.qty,
        round: toBigInt(row.round) ?? 0n,
      };
    },

    recordUnfulfilled({ paymentTxid, sender, amount, reason, round }) {
      assertNonNegative(round, 'round');
      recordUnfulfilledStmt.run(
        paymentTxid,
        sender ?? null,
        amount === undefined ? null : amount.toString(),
        reason,
        round.toString(),
      );
    },

    getWatcherCheckpoint() {
      const row = getCheckpointStmt.get();
      if (!row) return null;
      try {
        return BigInt(row.last_round);
      } catch {
        return null;
      }
    },

    setWatcherCheckpoint(round) {
      assertNonNegative(round, 'round');
      upsertCheckpointStmt.run(round.toString());
    },

    close() {
      db.close();
    },
  };
}

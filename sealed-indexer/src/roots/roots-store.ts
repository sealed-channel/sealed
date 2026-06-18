/**
 * Roots registry store.
 *
 * Backs `GET /roots` and ingestion of `postRoot` on-chain events
 * (SPEC-snark-redeem-B §4 + §6).
 *
 * Two tables, joined by `root`:
 *
 *   roots(root PK, denomination, posted_round)
 *     - One row per on-chain `RootPosted` event; written by the
 *       roots-watcher. Idempotent (chain replays a round on at-least-once
 *       delivery, so ingest must not duplicate).
 *
 *   root_leaves(root, idx, leaf)
 *     - Leaf set uploaded out-of-band by admin via
 *       `POST /admin/roots/:root/leaves`. (root, idx) is the primary key so
 *       a re-upload of the same root replaces the prior set deterministically
 *       (we delete-then-insert under a single transaction).
 *
 * Roots are stored as lowercase hex (64 chars) for stable JSON output that
 * survives byte-for-byte round-trips through OHTTP caches. Leaves are also
 * hex so the API response body is pure ASCII (no base64 padding variants).
 */
import Database from 'better-sqlite3';

export interface RootRecord {
  /** 64-char lowercase hex of the 32-byte Merkle root. */
  root: string;
  /** Denomination posted alongside the root, in cs base units. */
  denomination: number;
  /** Algorand round in which the `postRoot` txn confirmed. */
  postedRound: number;
}

export interface RootWithLeaves extends RootRecord {
  /** Lowercase-hex leaves, in upload-order. Empty array if none uploaded. */
  leaves: string[];
}

export interface RootsStore {
  upsertRoot(rec: RootRecord): void;
  setLeaves(root: string, leaves: string[]): void;
  getRoot(root: string): RootRecord | null;
  list(): RootWithLeaves[];
  count(): number;
  close(): void;
}

const DDL = `
  CREATE TABLE IF NOT EXISTS roots (
    root          TEXT PRIMARY KEY,
    denomination  INTEGER NOT NULL,
    posted_round  INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS root_leaves (
    root  TEXT NOT NULL,
    idx   INTEGER NOT NULL,
    leaf  TEXT NOT NULL,
    PRIMARY KEY (root, idx)
  );
  CREATE INDEX IF NOT EXISTS idx_root_leaves_root ON root_leaves(root);
`;

interface RootRow {
  root: string;
  denomination: number;
  posted_round: number;
}

interface LeafRow {
  root: string;
  idx: number;
  leaf: string;
}

const HEX64 = /^[a-f0-9]{64}$/;

function assertHex64(s: string, label: string): void {
  if (!HEX64.test(s)) {
    throw new Error(`roots-store: ${label} must be 64-char lowercase hex`);
  }
}

export function createRootsStore(dbPath: string): RootsStore {
  const db = new Database(dbPath);
  db.exec(DDL);

  // `INSERT OR IGNORE` keeps ingestion idempotent: the first observation of a
  // root wins, replays of the same round are dropped silently. Denomination
  // and posted_round are immutable on-chain so we never need an UPDATE path.
  const insertRootStmt = db.prepare(`
    INSERT OR IGNORE INTO roots (root, denomination, posted_round)
    VALUES (?, ?, ?)
  `);

  const getRootStmt = db.prepare(`SELECT * FROM roots WHERE root = ?`);

  const listRootsStmt = db.prepare(`
    SELECT * FROM roots ORDER BY posted_round, root
  `);

  const listLeavesStmt = db.prepare(`
    SELECT root, idx, leaf FROM root_leaves
    WHERE root = ?
    ORDER BY idx
  `);

  const deleteLeavesStmt = db.prepare(`DELETE FROM root_leaves WHERE root = ?`);
  const insertLeafStmt = db.prepare(
    `INSERT INTO root_leaves (root, idx, leaf) VALUES (?, ?, ?)`,
  );

  const countStmt = db.prepare(`SELECT COUNT(*) AS n FROM roots`);

  const replaceLeaves = db.transaction((root: string, leaves: string[]) => {
    deleteLeavesStmt.run(root);
    for (let i = 0; i < leaves.length; i++) {
      insertLeafStmt.run(root, i, leaves[i]);
    }
  });

  return {
    upsertRoot(rec) {
      assertHex64(rec.root, 'root');
      if (!Number.isInteger(rec.denomination) || rec.denomination <= 0) {
        throw new Error('roots-store: denomination must be positive integer');
      }
      if (!Number.isInteger(rec.postedRound) || rec.postedRound < 0) {
        throw new Error('roots-store: postedRound must be non-negative integer');
      }
      insertRootStmt.run(rec.root, rec.denomination, rec.postedRound);
    },

    setLeaves(root, leaves) {
      assertHex64(root, 'root');
      for (const leaf of leaves) assertHex64(leaf, 'leaf');
      // Root must exist before leaves attach. Avoids orphan leaf rows for a
      // root the chain never posted (admin typo, racing the watcher, etc.).
      const row = getRootStmt.get(root) as RootRow | undefined;
      if (!row) {
        throw new Error('UNKNOWN_ROOT');
      }
      replaceLeaves(root, leaves);
    },

    getRoot(root) {
      assertHex64(root, 'root');
      const row = getRootStmt.get(root) as RootRow | undefined;
      if (!row) return null;
      return {
        root: row.root,
        denomination: row.denomination,
        postedRound: row.posted_round,
      };
    },

    list() {
      const rows = listRootsStmt.all() as RootRow[];
      return rows.map((row) => {
        const leafRows = listLeavesStmt.all(row.root) as LeafRow[];
        return {
          root: row.root,
          denomination: row.denomination,
          postedRound: row.posted_round,
          leaves: leafRows.map((l) => l.leaf),
        };
      });
    },

    count() {
      const r = countStmt.get() as { n: number };
      return r.n;
    },

    close() {
      db.close();
    },
  };
}

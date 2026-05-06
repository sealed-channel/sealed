import Database from 'better-sqlite3';

/**
 * Legacy username directory.
 *
 * These records were imported from the old indexer-service SQLite
 * (`indexer-service/data/indexer.db -> registered_users`). They were
 * registered before the move to Algorand on-chain `set_username` calls
 * and were never published to the chain. The original wallets are
 * Solana base58 addresses, so users cannot currently message these
 * accounts on Algorand — they're listed only so the names remain
 * discoverable until the original owner re-claims them under the
 * new flow.
 *
 * The endpoints exposing this table mark every result with
 * `legacy: true`. Clients render those entries dimmed / non-selectable
 * for messaging.
 */
export interface LegacyDirectoryEntry {
  username: string;
  ownerPubkey: string;             // Solana base58 (44 chars, NOT Algorand)
  encryptionPubkey: string | null; // base64 or null
  scanPubkey: string | null;       // base64 or null
  registeredAt: number;            // unix seconds
  source: string;                  // e.g. "indexer-service-v1"
}

export interface LegacyDirectoryStore {
  upsert(entry: LegacyDirectoryEntry): void;
  byUsername(username: string): LegacyDirectoryEntry | null;
  byOwner(ownerPubkey: string): LegacyDirectoryEntry[];
  search(query: string, limit?: number): LegacyDirectoryEntry[];
  count(): number;
  close(): void;
}

const DDL = `
  CREATE TABLE IF NOT EXISTS legacy_directory (
    username           TEXT PRIMARY KEY,
    owner_pubkey       TEXT NOT NULL,
    encryption_pubkey  TEXT,
    scan_pubkey        TEXT,
    registered_at      INTEGER NOT NULL,
    source             TEXT NOT NULL DEFAULT 'unknown'
  );
  CREATE INDEX IF NOT EXISTS idx_legacy_owner ON legacy_directory(owner_pubkey);
  CREATE INDEX IF NOT EXISTS idx_legacy_username_lc ON legacy_directory(LOWER(username));
`;

interface Row {
  username: string;
  owner_pubkey: string;
  encryption_pubkey: string | null;
  scan_pubkey: string | null;
  registered_at: number;
  source: string;
}

function toEntry(row: Row): LegacyDirectoryEntry {
  return {
    username: row.username,
    ownerPubkey: row.owner_pubkey,
    encryptionPubkey: row.encryption_pubkey,
    scanPubkey: row.scan_pubkey,
    registeredAt: row.registered_at,
    source: row.source,
  };
}

export function createLegacyDirectoryStore(dbPath: string): LegacyDirectoryStore {
  const db = new Database(dbPath);
  db.exec(DDL);

  const upsertStmt = db.prepare(`
    INSERT INTO legacy_directory
      (username, owner_pubkey, encryption_pubkey, scan_pubkey, registered_at, source)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(username) DO UPDATE SET
      owner_pubkey      = excluded.owner_pubkey,
      encryption_pubkey = excluded.encryption_pubkey,
      scan_pubkey       = excluded.scan_pubkey,
      registered_at     = excluded.registered_at,
      source            = excluded.source
  `);

  const byUsernameStmt = db.prepare(`
    SELECT * FROM legacy_directory WHERE LOWER(username) = LOWER(?)
  `);

  const byOwnerStmt = db.prepare(`
    SELECT * FROM legacy_directory WHERE owner_pubkey = ? ORDER BY registered_at
  `);

  // Prefix-match (case-insensitive). Suffix wildcard only — leading wildcard
  // would force a full table scan and isn't necessary for a search bar.
  const searchStmt = db.prepare(`
    SELECT * FROM legacy_directory
    WHERE LOWER(username) LIKE LOWER(?) || '%'
    ORDER BY registered_at
    LIMIT ?
  `);

  const countStmt = db.prepare(`SELECT COUNT(*) AS n FROM legacy_directory`);

  return {
    upsert(entry) {
      if (!entry.username || entry.username.length > 64) {
        throw new Error('legacy_directory: invalid username');
      }
      if (!entry.ownerPubkey || entry.ownerPubkey.length > 128) {
        throw new Error('legacy_directory: invalid owner_pubkey');
      }
      upsertStmt.run(
        entry.username,
        entry.ownerPubkey,
        entry.encryptionPubkey,
        entry.scanPubkey,
        entry.registeredAt,
        entry.source,
      );
    },

    byUsername(username) {
      const row = byUsernameStmt.get(username) as Row | undefined;
      return row ? toEntry(row) : null;
    },

    byOwner(ownerPubkey) {
      const rows = byOwnerStmt.all(ownerPubkey) as Row[];
      return rows.map(toEntry);
    },

    search(query, limit = 20) {
      const safeLimit = Math.max(1, Math.min(100, limit | 0));
      const rows = searchStmt.all(query, safeLimit) as Row[];
      return rows.map(toEntry);
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

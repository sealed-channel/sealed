/**
 * Persistent watermark for an Algorand watcher.
 *
 * Stores the last successfully processed round in the same SQLite database
 * used by `push/store.ts` so a restart resumes from where we left off rather
 * than rescanning from chain tip. Each watcher gets its own single-row table
 * so that, e.g., rewinding the user backfill cursor does not also rewind the
 * message-event cursor (which would re-fire push notifications).
 *
 * Round numbers are stored as TEXT to safely round-trip uint64 values that
 * exceed JavaScript's `Number.MAX_SAFE_INTEGER` (2^53 - 1).
 *
 * Consumers:
 *  - src/notifications/algorand-watcher.ts (default `algorand_cursor`)
 *  - src/users/user-watcher.ts (uses `user_cursor`)
 *  - src/index.ts (constructs both stores and injects them)
 */

import Database from 'better-sqlite3';

export interface CursorStore {
  getRound(): bigint | null;
  setRound(round: bigint): void;
  close(): void;
}

const DEFAULT_TABLE = 'algorand_cursor';
const TABLE_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

export function createCursorStore(
  dbPath: string,
  tableName: string = DEFAULT_TABLE,
): CursorStore {
  if (!TABLE_NAME_RE.test(tableName)) {
    throw new Error(`Invalid cursor table name: ${tableName}`);
  }
  const db = new Database(dbPath);

  db.exec(`
    CREATE TABLE IF NOT EXISTS ${tableName} (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      round TEXT NOT NULL
    )
  `);

  const getStmt = db.prepare<[], { round: string }>(
    `SELECT round FROM ${tableName} WHERE id = 1`,
  );
  const upsertStmt = db.prepare(`
    INSERT INTO ${tableName} (id, round) VALUES (1, ?)
    ON CONFLICT(id) DO UPDATE SET round = excluded.round
  `);

  return {
    getRound(): bigint | null {
      const row = getStmt.get();
      if (!row) return null;
      try {
        return BigInt(row.round);
      } catch {
        return null;
      }
    },
    setRound(round: bigint): void {
      if (round < 0n) {
        throw new Error('round must be non-negative');
      }
      upsertStmt.run(round.toString());
    },
    close(): void {
      db.close();
    },
  };
}

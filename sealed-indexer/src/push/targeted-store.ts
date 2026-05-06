/**
 * Push Notifications registrations (Task #9).
 *
 * Privacy trade-off (locked, disclosed to users at registration):
 *   When a user opts in to "Push Notifications", the indexer learns their
 *   view_priv. With that, it can determine which chain messages are theirs
 *   and dispatch only one push per matching event — instead of waking every
 *   device on every message (the blinded-fanout privacy default).
 *
 * Schema mirrors the blinded store but adds:
 *   - view_pub (32 bytes, hex)  — derived from view_priv at register time
 *                                 server verifies derivePublicKey(view_priv) == view_pub
 *   - view_priv (32 bytes, hex) — used by the matcher to trial-decrypt
 *
 * `enc_token` is still the dispatcher-sealed device token — Apple/Google get
 * a constant-text wake-up but never see Sealed-level identifiers.
 */
import Database from 'better-sqlite3';

export type TargetedPlatform = 'ios' | 'android';

export interface TargetedRegistration {
  blindedId: string;
  encToken: string;
  platform: TargetedPlatform;
  viewPriv: Buffer;
  viewPub: Buffer;
  createdAt: number;
  updatedAt: number;
}

export interface TargetedRegistrationInput {
  blindedId: string;
  encToken: string;
  platform: TargetedPlatform;
  viewPriv: Buffer;
  viewPub: Buffer;
}

export interface TargetedPushTokenStore {
  register(input: TargetedRegistrationInput): void;
  get(blindedId: string): TargetedRegistration | null;
  listAll(): TargetedRegistration[];
  unregister(blindedId: string): void;
  close(): void;
}

const HEX64 = /^[a-f0-9]{64}$/;
const VALID_PLATFORMS: ReadonlySet<string> = new Set(['ios', 'android']);

export function createTargetedPushTokenStore(dbPath: string): TargetedPushTokenStore {
  const db = new Database(dbPath);

  // Phase B convergence: drop the legacy `push_tokens` and the blinded
  // `blinded_push_tokens` tables if older deployments still carry them.
  // Idempotent — fresh DBs ignore the DROPs.
  db.exec(`
    DROP TABLE IF EXISTS push_tokens;
    DROP TABLE IF EXISTS blinded_push_tokens;
  `);

  db.exec(`
    CREATE TABLE IF NOT EXISTS targeted_push_tokens (
      blinded_id TEXT PRIMARY KEY,
      enc_token  TEXT NOT NULL,
      platform   TEXT NOT NULL,
      view_priv  BLOB NOT NULL,
      view_pub   BLOB NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  `);

  const upsertStmt = db.prepare(`
    INSERT INTO targeted_push_tokens
      (blinded_id, enc_token, platform, view_priv, view_pub, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(blinded_id) DO UPDATE SET
      enc_token  = excluded.enc_token,
      platform   = excluded.platform,
      view_priv  = excluded.view_priv,
      view_pub   = excluded.view_pub,
      updated_at = excluded.updated_at
  `);

  const getStmt = db.prepare(`
    SELECT blinded_id AS blindedId,
           enc_token  AS encToken,
           platform,
           view_priv  AS viewPriv,
           view_pub   AS viewPub,
           created_at AS createdAt,
           updated_at AS updatedAt
    FROM targeted_push_tokens
    WHERE blinded_id = ?
  `);

  const listAllStmt = db.prepare(`
    SELECT blinded_id AS blindedId,
           enc_token  AS encToken,
           platform,
           view_priv  AS viewPriv,
           view_pub   AS viewPub,
           created_at AS createdAt,
           updated_at AS updatedAt
    FROM targeted_push_tokens
  `);

  const getCreatedAtStmt = db.prepare(
    `SELECT created_at AS createdAt FROM targeted_push_tokens WHERE blinded_id = ?`,
  );
  const deleteStmt = db.prepare(`DELETE FROM targeted_push_tokens WHERE blinded_id = ?`);

  function rowToReg(row: unknown): TargetedRegistration {
    const r = row as {
      blindedId: string;
      encToken: string;
      platform: string;
      viewPriv: Buffer;
      viewPub: Buffer;
      createdAt: number;
      updatedAt: number;
    };
    if (!VALID_PLATFORMS.has(r.platform)) {
      throw new Error(`Stored platform invalid: ${r.platform}`);
    }
    return {
      blindedId: r.blindedId,
      encToken: r.encToken,
      platform: r.platform as TargetedPlatform,
      viewPriv: Buffer.from(r.viewPriv),
      viewPub: Buffer.from(r.viewPub),
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    };
  }

  return {
    register(input) {
      if (!HEX64.test(input.blindedId)) {
        throw new Error('Invalid blinded_id: must be 64 lowercase hex characters');
      }
      if (!input.encToken || input.encToken.trim() === '') {
        throw new Error('Invalid enc_token: cannot be empty');
      }
      if (!VALID_PLATFORMS.has(input.platform)) {
        throw new Error('Invalid platform: must be ios or android');
      }
      if (input.viewPriv.length !== 32) {
        throw new Error('Invalid view_priv: must be 32 bytes');
      }
      if (input.viewPub.length !== 32) {
        throw new Error('Invalid view_pub: must be 32 bytes');
      }

      const now = Date.now();
      const existing = getCreatedAtStmt.get(input.blindedId) as
        | { createdAt: number }
        | undefined;
      const createdAt = existing?.createdAt ?? now;

      upsertStmt.run(
        input.blindedId,
        input.encToken,
        input.platform,
        input.viewPriv,
        input.viewPub,
        createdAt,
        now,
      );
    },

    get(blindedId) {
      const row = getStmt.get(blindedId);
      return row ? rowToReg(row) : null;
    },

    listAll() {
      return (listAllStmt.all() as unknown[]).map(rowToReg);
    },

    unregister(blindedId) {
      deleteStmt.run(blindedId);
    },

    close() {
      db.close();
    },
  };
}

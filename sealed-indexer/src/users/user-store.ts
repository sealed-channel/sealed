/**
 * Live user directory.
 *
 * Populated by `user-watcher.ts` from on-chain calls on the unified Sealed app.
 * ABI methods that write into this store:
 *   - claimUsername(byte[])void   → upsertUsername
 *   - publishKeys(byte[32],byte[32],byte[])void → upsertKeys
 *   - releaseUsername()void       → clearUsername
 *   - setBio(byte[])void          → upsertBio (empty arg clears → NULL)
 *
 * One row per owner wallet. All key/username columns are nullable because the
 * two setter methods are independent txns — a row may exist with keys but no
 * username (or vice-versa) until both txns are observed.
 *
 * Pubkeys stored as raw bytes (BLOB); base64-encoded only at API edge.
 *
 * Search: in-memory trigram index for typo-tolerant ranked results (<5ms at
 * <10k rows). Only rows with a non-null username are indexed/searchable.
 */
import Database from 'better-sqlite3';

export interface UserDirectoryEntry {
  ownerPubkey: string;           // Algorand wallet address (base32, 58 chars)
  username: string | null;
  bio: string | null;            // public profile bio, ≤160 UTF-8 bytes; display-only, never searched
  encryptionPubkey: Buffer | null;
  scanPubkey: Buffer | null;
  pqPubkey: Buffer | null;
  pqPublishedRound: number | null; // Algorand round of the publishKeys txn (null for pre-column rows)
  registeredAt: number;          // unix ms (first observation of this owner)
  updatedAt: number;             // unix ms (latest write for this owner)
  // Search-time only
  score?: number;
  matchType?: 'exact' | 'prefix' | 'substring' | 'fuzzy';
}

export interface UserDirectoryStore {
  upsertUsername(ownerPubkey: string, username: string, observedAt: number): void;
  upsertKeys(ownerPubkey: string, encryptionPubkey: Buffer, scanPubkey: Buffer, pqPubkey: Buffer | null, pqPublishedRound: number | null, observedAt: number): void;
  clearUsername(ownerPubkey: string, observedAt: number): void;
  /** Set or clear (null / empty string) the owner's bio. */
  upsertBio(ownerPubkey: string, bio: string | null, observedAt: number): void;
  byOwner(ownerPubkey: string): UserDirectoryEntry | null;
  search(query: string, limit?: number): UserDirectoryEntry[];
  count(): number;
  close(): void;
}

const DDL = `
  CREATE TABLE IF NOT EXISTS users (
    owner_pubkey       TEXT PRIMARY KEY,
    username           TEXT,
    bio                TEXT,
    encryption_pubkey  BLOB,
    scan_pubkey        BLOB,
    pq_pubkey          BLOB,
    pq_published_round INTEGER,
    registered_at      INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_users_username_lc ON users(LOWER(username)) WHERE username IS NOT NULL;
`;

interface Row {
  owner_pubkey: string;
  username: string | null;
  bio: string | null;
  encryption_pubkey: Buffer | null;
  scan_pubkey: Buffer | null;
  pq_pubkey: Buffer | null;
  pq_published_round: number | null;
  registered_at: number;
  updated_at: number;
}

function toEntry(row: Row): UserDirectoryEntry {
  return {
    ownerPubkey: row.owner_pubkey,
    username: row.username,
    bio: row.bio ?? null,
    encryptionPubkey: row.encryption_pubkey,
    scanPubkey: row.scan_pubkey,
    pqPubkey: row.pq_pubkey,
    pqPublishedRound: row.pq_published_round ?? null,
    registeredAt: row.registered_at,
    updatedAt: row.updated_at,
  };
}

// ---------------------------------------------------------------------------
// Fuzzy search helpers (in-memory trigram index + Damerau-Levenshtein rerank)
// ---------------------------------------------------------------------------

function trigramsOf(s: string): string[] {
  const t = `^${s.toLowerCase()}$`;
  if (t.length < 3) return [t];
  const out: string[] = [];
  for (let i = 0; i <= t.length - 3; i++) out.push(t.slice(i, i + 3));
  return out;
}

function damerauLevenshtein(a: string, b: string, max: number): number {
  const al = a.length;
  const bl = b.length;
  if (Math.abs(al - bl) > max) return Infinity;
  if (al === 0) return bl;
  if (bl === 0) return al;

  let prevPrev = new Array<number>(bl + 1).fill(0);
  let prev = new Array<number>(bl + 1);
  let curr = new Array<number>(bl + 1);
  for (let j = 0; j <= bl; j++) prev[j] = j;

  for (let i = 1; i <= al; i++) {
    curr[0] = i;
    let rowMin = curr[0];
    for (let j = 1; j <= bl; j++) {
      const cost = a.charCodeAt(i - 1) === b.charCodeAt(j - 1) ? 0 : 1;
      let v = Math.min(
        prev[j] + 1,
        curr[j - 1] + 1,
        prev[j - 1] + cost,
      );
      if (
        i > 1 &&
        j > 1 &&
        a.charCodeAt(i - 1) === b.charCodeAt(j - 2) &&
        a.charCodeAt(i - 2) === b.charCodeAt(j - 1)
      ) {
        v = Math.min(v, prevPrev[j - 2] + 1);
      }
      curr[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return Infinity;
    [prevPrev, prev, curr] = [prev, curr, prevPrev];
  }
  return prev[bl];
}

export function createUserDirectoryStore(dbPath: string): UserDirectoryStore {
  const db = new Database(dbPath);

  // Create table if absent. Do NOT drop — that wipes the directory on every
  // boot and forces watcher to repopulate from genesis, which is slow and
  // racy. For ABI migrations: set USER_STORE_RESET=1 env var explicitly.
  if (process.env.USER_STORE_RESET === '1') {
    db.exec('DROP TABLE IF EXISTS users');
  }
  db.exec(DDL);

  // Additive migration for pre-bio databases (CREATE IF NOT EXISTS skips the
  // new column on existing tables). Same nullable-column pattern as
  // pq_published_round; no reset required.
  const cols = db.prepare(`PRAGMA table_info(users)`).all() as { name: string }[];
  if (!cols.some((c) => c.name === 'bio')) {
    db.exec('ALTER TABLE users ADD COLUMN bio TEXT');
  }

  // Seed row on first observation (either claimUsername or publishKeys).
  // Use INSERT OR IGNORE so re-observations after a watcher restart don't
  // reset registered_at.
  const seedStmt = db.prepare(`
    INSERT OR IGNORE INTO users (owner_pubkey, registered_at, updated_at)
    VALUES (@ownerPubkey, @observedAt, @observedAt)
  `);

  const updateUsernameStmt = db.prepare(`
    UPDATE users SET username = @username, updated_at = @observedAt
    WHERE owner_pubkey = @ownerPubkey
  `);

  const updateKeysStmt = db.prepare(`
    UPDATE users
    SET encryption_pubkey = @encryptionPubkey,
        scan_pubkey = @scanPubkey,
        pq_pubkey = @pqPubkey,
        pq_published_round = @pqPublishedRound,
        updated_at = @observedAt
    WHERE owner_pubkey = @ownerPubkey
  `);

  const clearUsernameStmt = db.prepare(`
    UPDATE users SET username = NULL, updated_at = @observedAt
    WHERE owner_pubkey = @ownerPubkey
  `);

  const updateBioStmt = db.prepare(`
    UPDATE users SET bio = @bio, updated_at = @observedAt
    WHERE owner_pubkey = @ownerPubkey
  `);

  const byOwnerStmt = db.prepare<[string], Row>(
    'SELECT * FROM users WHERE owner_pubkey = ?',
  );

  const prefixStmt = db.prepare<[string, number], Row>(`
    SELECT * FROM users
    WHERE username IS NOT NULL AND LOWER(username) LIKE ? ESCAPE '\\'
    ORDER BY username COLLATE NOCASE
    LIMIT ?
  `);

  const hydrateStmt = db.prepare<[string], Row>(
    'SELECT * FROM users WHERE owner_pubkey = ?',
  );

  const allWithUsernameStmt = db.prepare<[], Row>(
    'SELECT owner_pubkey, username FROM users WHERE username IS NOT NULL',
  );

  const countStmt = db.prepare<[], { c: number }>('SELECT COUNT(*) AS c FROM users');

  // ---- in-memory trigram index (username-only rows) ----------------------
  const trigramIndex = new Map<string, Set<string>>();
  const indexedName = new Map<string, string>();

  function addToIndex(owner: string, username: string): void {
    const lc = username.toLowerCase();
    indexedName.set(owner, lc);
    for (const tri of trigramsOf(lc)) {
      let set = trigramIndex.get(tri);
      if (!set) { set = new Set(); trigramIndex.set(tri, set); }
      set.add(owner);
    }
  }

  function removeFromIndex(owner: string): void {
    const prev = indexedName.get(owner);
    if (!prev) return;
    for (const tri of trigramsOf(prev)) {
      const set = trigramIndex.get(tri);
      if (!set) continue;
      set.delete(owner);
      if (set.size === 0) trigramIndex.delete(tri);
    }
    indexedName.delete(owner);
  }

  // Boot hydration (table is fresh after DROP+CREATE, so this is a no-op on
  // first run; kept so in-memory index stays warm on hot-reload in dev).
  for (const row of allWithUsernameStmt.all()) {
    if (row.username) addToIndex(row.owner_pubkey, row.username);
  }

  function escapeLike(s: string): string {
    return s.toLowerCase().replace(/\\/g, '\\\\').replace(/%/g, '\\%').replace(/_/g, '\\_');
  }

  function fuzzySearch(rawQuery: string, limit: number): UserDirectoryEntry[] {
    const q = rawQuery.toLowerCase();
    const cap = Math.max(1, Math.min(50, limit));

    if (q.length < 3) {
      const rows = prefixStmt.all(`%${escapeLike(q)}%`, cap);
      return rows.map((row) => {
        const e = toEntry(row);
        e.matchType = 'substring';
        e.score = 1;
        return e;
      });
    }

    const queryTrigrams = trigramsOf(q);
    const hits = new Map<string, number>();
    for (const tri of queryTrigrams) {
      const owners = trigramIndex.get(tri);
      if (!owners) continue;
      for (const owner of owners) hits.set(owner, (hits.get(owner) ?? 0) + 1);
    }
    if (hits.size === 0) return [];

    const candidates = Array.from(hits.entries()).sort((a, b) => b[1] - a[1]).slice(0, 200);

    const maxEdit = Math.min(3, Math.max(1, Math.floor(q.length / 3)));
    type Scored = { owner: string; score: number; matchType: UserDirectoryEntry['matchType']; name: string };
    const scored: Scored[] = [];

    for (const [owner] of candidates) {
      const name = indexedName.get(owner);
      if (!name) continue;
      let matchType: UserDirectoryEntry['matchType'] = 'fuzzy';
      let score = 0;
      if (name === q) { matchType = 'exact'; score = 1000; }
      else if (name.startsWith(q)) { matchType = 'prefix'; score = 500 - (name.length - q.length); }
      else if (name.includes(q)) { matchType = 'substring'; score = 250 - (name.length - q.length); }
      else {
        const dist = damerauLevenshtein(q, name, maxEdit);
        if (!isFinite(dist)) continue;
        score = 100 - dist * 25 - Math.abs(name.length - q.length);
      }
      scored.push({ owner, score, matchType, name });
    }

    scored.sort((a, b) => b.score !== a.score ? b.score - a.score : a.name.localeCompare(b.name));
    const out: UserDirectoryEntry[] = [];
    for (const s of scored.slice(0, cap)) {
      const row = hydrateStmt.get(s.owner);
      if (!row) continue;
      const entry = toEntry(row);
      entry.score = s.score;
      entry.matchType = s.matchType;
      out.push(entry);
    }
    return out;
  }

  return {
    upsertUsername(ownerPubkey: string, username: string, observedAt: number): void {
      if (!ownerPubkey) throw new Error('ownerPubkey must not be empty');
      if (!username) throw new Error('username must not be empty');
      db.transaction(() => {
        seedStmt.run({ ownerPubkey, observedAt });
        updateUsernameStmt.run({ ownerPubkey, username, observedAt });
      })();
      removeFromIndex(ownerPubkey);
      addToIndex(ownerPubkey, username);
    },

    upsertKeys(ownerPubkey: string, encryptionPubkey: Buffer, scanPubkey: Buffer, pqPubkey: Buffer | null, pqPublishedRound: number | null, observedAt: number): void {
      if (!ownerPubkey) throw new Error('ownerPubkey must not be empty');
      if (encryptionPubkey.length !== 32) throw new Error(`encryptionPubkey must be 32 bytes, got ${encryptionPubkey.length}`);
      if (scanPubkey.length !== 32) throw new Error(`scanPubkey must be 32 bytes, got ${scanPubkey.length}`);
      db.transaction(() => {
        seedStmt.run({ ownerPubkey, observedAt });
        updateKeysStmt.run({ ownerPubkey, encryptionPubkey, scanPubkey, pqPubkey: pqPubkey ?? null, pqPublishedRound: pqPublishedRound ?? null, observedAt });
      })();
    },

    clearUsername(ownerPubkey: string, observedAt: number): void {
      if (!ownerPubkey) throw new Error('ownerPubkey must not be empty');
      clearUsernameStmt.run({ ownerPubkey, observedAt });
      removeFromIndex(ownerPubkey);
    },

    upsertBio(ownerPubkey: string, bio: string | null, observedAt: number): void {
      if (!ownerPubkey) throw new Error('ownerPubkey must not be empty');
      const value = bio && bio.length > 0 ? bio : null; // empty = cleared
      db.transaction(() => {
        seedStmt.run({ ownerPubkey, observedAt });
        updateBioStmt.run({ ownerPubkey, bio: value, observedAt });
      })();
      // Bio is display-only — deliberately NOT added to the trigram index.
    },

    byOwner(ownerPubkey: string): UserDirectoryEntry | null {
      const row = byOwnerStmt.get(ownerPubkey);
      return row ? toEntry(row) : null;
    },

    search(query: string, limit: number = 20): UserDirectoryEntry[] {
      return fuzzySearch(query, limit);
    },

    count(): number {
      return countStmt.get()?.c ?? 0;
    },

    close(): void {
      db.close();
    },
  };
}

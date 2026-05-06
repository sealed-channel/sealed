/**
 * Live user directory.
 *
 * Populated by `user-watcher.ts` from on-chain `set_username` app calls on the
 * sealed-message app (`SEALED_MESSAGE_APP_ID`). One row per owner wallet —
 * later set_username calls from the same wallet overwrite earlier ones
 * (last-write-wins, mirrors the chain's authoritative state).
 *
 * Sibling of `legacy-directory.ts` (which holds the imported pre-Algorand
 * registry). The Flutter client looks up new users here via
 * GET /user/by-owner/:owner and GET /user/search.
 *
 * Pubkeys are stored as 32 raw bytes (BLOB) and base64-encoded only at the API
 * edge so the storage format matches the chain's wire format.
 *
 * Search: a tiny in-memory trigram index sits beside SQLite to give typo-
 * tolerant, ranked results in <5ms at the <10k-row scale we operate at.
 * For sub-3-char queries we fall back to the SQL prefix path so single-letter
 * typing still feels instant.
 */
import Database from 'better-sqlite3';

export interface UserDirectoryEntry {
  username: string;
  ownerPubkey: string;          // Algorand wallet address (base32, 58 chars)
  encryptionPubkey: Buffer;     // 32 bytes
  scanPubkey: Buffer;           // 32 bytes
  registeredAt: number;         // unix ms (first observation of this owner)
  updatedAt: number;            // unix ms (latest set_username for this owner)
  // Search-time only — populated by `search()` so the route handler can
  // return them without recomputing. Undefined for byOwner() lookups.
  score?: number;
  matchType?: 'exact' | 'prefix' | 'substring' | 'fuzzy';
}

export interface UserDirectoryUpsertInput {
  username: string;
  ownerPubkey: string;
  encryptionPubkey: Buffer;
  scanPubkey: Buffer;
  observedAt: number;           // unix ms — caller passes Date.now() or txn time
}

export interface UserDirectoryStore {
  upsert(input: UserDirectoryUpsertInput): void;
  byOwner(ownerPubkey: string): UserDirectoryEntry | null;
  search(query: string, limit?: number): UserDirectoryEntry[];
  count(): number;
  close(): void;
}

const DDL = `
  CREATE TABLE IF NOT EXISTS users (
    owner_pubkey       TEXT PRIMARY KEY,
    username           TEXT NOT NULL,
    encryption_pubkey  BLOB NOT NULL,
    scan_pubkey        BLOB NOT NULL,
    registered_at      INTEGER NOT NULL,
    updated_at         INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_users_username_lc ON users(LOWER(username));
`;

interface Row {
  owner_pubkey: string;
  username: string;
  encryption_pubkey: Buffer;
  scan_pubkey: Buffer;
  registered_at: number;
  updated_at: number;
}

function toEntry(row: Row): UserDirectoryEntry {
  return {
    ownerPubkey: row.owner_pubkey,
    username: row.username,
    encryptionPubkey: row.encryption_pubkey,
    scanPubkey: row.scan_pubkey,
    registeredAt: row.registered_at,
    updatedAt: row.updated_at,
  };
}

// ---------------------------------------------------------------------------
// Fuzzy search helpers (in-memory trigram index + Damerau-Levenshtein rerank)
// ---------------------------------------------------------------------------

/**
 * Generate trigrams for a string with start/end markers so prefix queries
 * score higher. "alice" → ["^al", "ali", "lic", "ice", "ce$"].
 * Strings shorter than 3 chars get one bigram-with-markers entry so they
 * still index something — but the search path treats q.length<3 specially.
 */
function trigramsOf(s: string): string[] {
  const t = `^${s.toLowerCase()}$`;
  if (t.length < 3) return [t];
  const out: string[] = [];
  for (let i = 0; i <= t.length - 3; i++) out.push(t.slice(i, i + 3));
  return out;
}

/**
 * Damerau-Levenshtein with adjacent-transposition. Bounded by `max` so we
 * stop early when the candidate is clearly too far. Returns Infinity if the
 * minimum possible distance already exceeds `max`.
 */
function damerauLevenshtein(a: string, b: string, max: number): number {
  const al = a.length;
  const bl = b.length;
  if (Math.abs(al - bl) > max) return Infinity;
  if (al === 0) return bl;
  if (bl === 0) return al;

  // Two-row rolling buffer + previous-prev row for transposition.
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
        prev[j] + 1,        // deletion
        curr[j - 1] + 1,    // insertion
        prev[j - 1] + cost, // substitution
      );
      if (
        i > 1 &&
        j > 1 &&
        a.charCodeAt(i - 1) === b.charCodeAt(j - 2) &&
        a.charCodeAt(i - 2) === b.charCodeAt(j - 1)
      ) {
        v = Math.min(v, prevPrev[j - 2] + 1); // transposition
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
  db.exec(DDL);

  // Upsert: keep the original `registered_at` on conflict so first-seen time
  // is preserved across re-registrations (clients may want to display "joined
  // on" dates that don't jump every time the user re-publishes their key).
  const upsertStmt = db.prepare(`
    INSERT INTO users (
      owner_pubkey, username, encryption_pubkey, scan_pubkey,
      registered_at, updated_at
    ) VALUES (@ownerPubkey, @username, @encryptionPubkey, @scanPubkey,
              @observedAt, @observedAt)
    ON CONFLICT(owner_pubkey) DO UPDATE SET
      username = excluded.username,
      encryption_pubkey = excluded.encryption_pubkey,
      scan_pubkey = excluded.scan_pubkey,
      updated_at = excluded.updated_at
  `);

  const byOwnerStmt = db.prepare<[string], Row>(
    'SELECT * FROM users WHERE owner_pubkey = ?',
  );

  // LIKE-prefix path used for sub-3-char queries (single-letter typing) and
  // as the substring backstop. Wildcard escaped so `q` is a literal substring.
  const prefixStmt = db.prepare<[string, number], Row>(`
    SELECT * FROM users
    WHERE LOWER(username) LIKE ? ESCAPE '\\'
    ORDER BY username COLLATE NOCASE
    LIMIT ?
  `);

  // Hydrate a single row by owner_pubkey (used during reranking).
  const hydrateStmt = db.prepare<[string], Row>(
    'SELECT * FROM users WHERE owner_pubkey = ?',
  );

  const allStmt = db.prepare<[], Row>(
    'SELECT owner_pubkey, username FROM users',
  );

  const countStmt = db.prepare<[], { c: number }>('SELECT COUNT(*) AS c FROM users');

  // ---- in-memory trigram index ------------------------------------------
  // trigram → set of owner_pubkey
  const trigramIndex = new Map<string, Set<string>>();
  // owner_pubkey → lowercased username (the value last indexed)
  const indexedName = new Map<string, string>();

  function addToIndex(owner: string, username: string): void {
    const lc = username.toLowerCase();
    indexedName.set(owner, lc);
    for (const tri of trigramsOf(lc)) {
      let set = trigramIndex.get(tri);
      if (!set) {
        set = new Set();
        trigramIndex.set(tri, set);
      }
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

  // Initial hydration from disk. At <10k rows × ~10 trigrams/name this is
  // sub-50ms and runs once at boot.
  for (const row of allStmt.all()) {
    addToIndex(row.owner_pubkey, row.username);
  }

  function escapeLike(s: string): string {
    return s
      .toLowerCase()
      .replace(/\\/g, '\\\\')
      .replace(/%/g, '\\%')
      .replace(/_/g, '\\_');
  }

  function fuzzySearch(rawQuery: string, limit: number): UserDirectoryEntry[] {
    const q = rawQuery.toLowerCase();
    const cap = Math.max(1, Math.min(50, limit));

    // Sub-3-char queries: trigram coverage is too sparse to be useful.
    // Fall back to the existing SQL substring path so single-letter typing
    // still surfaces results from the indexed `LOWER(username)` column.
    if (q.length < 3) {
      const pattern = `%${escapeLike(q)}%`;
      const rows = prefixStmt.all(pattern, cap);
      return rows.map((row) => {
        const e = toEntry(row);
        e.matchType = 'substring';
        e.score = 1;
        return e;
      });
    }

    // Trigram candidate selection: count trigram overlaps per owner.
    const queryTrigrams = trigramsOf(q);
    const hits = new Map<string, number>();
    for (const tri of queryTrigrams) {
      const owners = trigramIndex.get(tri);
      if (!owners) continue;
      for (const owner of owners) {
        hits.set(owner, (hits.get(owner) ?? 0) + 1);
      }
    }
    if (hits.size === 0) return [];

    // Take top ~200 candidates by raw trigram overlap; reranking is O(|q|*|name|)
    // per candidate, so we keep the rerank pool bounded.
    const candidates = Array.from(hits.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 200);

    // Rerank: edit-distance + boosts for substring/prefix/exact.
    const maxEdit = Math.min(3, Math.max(1, Math.floor(q.length / 3)));
    type Scored = { owner: string; score: number; matchType: UserDirectoryEntry['matchType']; name: string };
    const scored: Scored[] = [];
    for (const [owner] of candidates) {
      const name = indexedName.get(owner);
      if (!name) continue;

      let matchType: UserDirectoryEntry['matchType'] = 'fuzzy';
      let score = 0;

      if (name === q) {
        matchType = 'exact';
        score = 1000;
      } else if (name.startsWith(q)) {
        matchType = 'prefix';
        score = 500 - (name.length - q.length);
      } else if (name.includes(q)) {
        matchType = 'substring';
        score = 250 - (name.length - q.length);
      } else {
        const dist = damerauLevenshtein(q, name, maxEdit);
        if (!isFinite(dist)) continue;
        // Smaller distance = higher score; normalize against query length so
        // a 1-edit typo on a long name doesn't outrank a closer fuzzy match.
        score = 100 - dist * 25 - Math.abs(name.length - q.length);
      }
      scored.push({ owner, score, matchType, name });
    }

    scored.sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      return a.name.localeCompare(b.name);
    });

    const top = scored.slice(0, cap);
    const out: UserDirectoryEntry[] = [];
    for (const s of top) {
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
    upsert(input: UserDirectoryUpsertInput): void {
      if (input.encryptionPubkey.length !== 32) {
        throw new Error(`encryptionPubkey must be 32 bytes, got ${input.encryptionPubkey.length}`);
      }
      if (input.scanPubkey.length !== 32) {
        throw new Error(`scanPubkey must be 32 bytes, got ${input.scanPubkey.length}`);
      }
      if (input.username.length === 0) {
        throw new Error('username must not be empty');
      }
      if (input.ownerPubkey.length === 0) {
        throw new Error('ownerPubkey must not be empty');
      }
      upsertStmt.run({
        ownerPubkey: input.ownerPubkey,
        username: input.username,
        encryptionPubkey: input.encryptionPubkey,
        scanPubkey: input.scanPubkey,
        observedAt: input.observedAt,
      });
      // Keep the in-memory trigram index in sync. Remove the previous name's
      // trigrams (if any) before adding the new ones — usernames change.
      removeFromIndex(input.ownerPubkey);
      addToIndex(input.ownerPubkey, input.username);
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

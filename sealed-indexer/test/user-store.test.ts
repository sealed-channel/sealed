/**
 * Unit tests for the SQLite-backed user directory store.
 */

import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createUserDirectoryStore } from '../src/users/user-store';

// 58-char base32 Algorand addresses
const ALICE = 'ALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BOB =   'BOBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

function buf32(byte: number): Buffer {
  return Buffer.alloc(32, byte);
}

function bufPq(byte: number): Buffer {
  return Buffer.alloc(800, byte); // ML-KEM-512 pubkey size
}

describe('UserDirectoryStore', () => {
  let dir: string;
  let dbPath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'user-store-test-'));
    dbPath = join(dir, 'indexer.db');
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  // ---------------------------------------------------------------------------
  // upsertUsername
  // ---------------------------------------------------------------------------

  it('upsertUsername: inserts and retrieves by owner', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'alice', 1_000);
      const entry = store.byOwner(ALICE);
      expect(entry).not.toBeNull();
      expect(entry!.username).toBe('alice');
      expect(entry!.registeredAt).toBe(1_000);
      expect(entry!.updatedAt).toBe(1_000);
    } finally {
      store.close();
    }
  });

  it('upsertUsername: preserves registeredAt on second call', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'alice', 1_000);
      store.upsertUsername(ALICE, 'alice2', 2_000);
      const entry = store.byOwner(ALICE);
      expect(entry!.username).toBe('alice2');
      expect(entry!.registeredAt).toBe(1_000);
      expect(entry!.updatedAt).toBe(2_000);
    } finally {
      store.close();
    }
  });

  it('upsertUsername: throws on empty ownerPubkey', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() => store.upsertUsername('', 'alice', 1)).toThrow();
    } finally {
      store.close();
    }
  });

  it('upsertUsername: throws on empty username', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() => store.upsertUsername(ALICE, '', 1)).toThrow();
    } finally {
      store.close();
    }
  });

  // ---------------------------------------------------------------------------
  // upsertKeys
  // ---------------------------------------------------------------------------

  it('upsertKeys: persists all key fields', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), bufPq(0xaa), 12345, 1_000);
      const entry = store.byOwner(ALICE);
      expect(entry).not.toBeNull();
      expect(entry!.encryptionPubkey!.equals(buf32(0x11))).toBe(true);
      expect(entry!.scanPubkey!.equals(buf32(0x22))).toBe(true);
      expect(entry!.pqPubkey!.equals(bufPq(0xaa))).toBe(true);
    } finally {
      store.close();
    }
  });

  it('upsertKeys: persists pqPublishedRound', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), bufPq(0xaa), 99_999, 1_000);
      const entry = store.byOwner(ALICE);
      expect(entry!.pqPublishedRound).toBe(99_999);
    } finally {
      store.close();
    }
  });

  it('upsertKeys: accepts null pqPubkey and null round', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), null, null, 1_000);
      const entry = store.byOwner(ALICE);
      expect(entry!.pqPubkey).toBeNull();
      expect(entry!.pqPublishedRound).toBeNull();
    } finally {
      store.close();
    }
  });

  it('upsertKeys: overwrites existing keys; round updates', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), bufPq(0xaa), 100, 1_000);
      store.upsertKeys(ALICE, buf32(0x33), buf32(0x44), bufPq(0xbb), 200, 2_000);
      const entry = store.byOwner(ALICE);
      expect(entry!.encryptionPubkey!.equals(buf32(0x33))).toBe(true);
      expect(entry!.pqPubkey!.equals(bufPq(0xbb))).toBe(true);
      expect(entry!.pqPublishedRound).toBe(200);
      expect(entry!.registeredAt).toBe(1_000); // preserved
      expect(entry!.updatedAt).toBe(2_000);
    } finally {
      store.close();
    }
  });

  it('upsertKeys: throws on wrong-length encryptionPubkey', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() =>
        store.upsertKeys(ALICE, Buffer.alloc(31), buf32(0x22), null, null, 1),
      ).toThrow(/encryptionPubkey must be 32 bytes/);
    } finally {
      store.close();
    }
  });

  it('upsertKeys: throws on wrong-length scanPubkey', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() =>
        store.upsertKeys(ALICE, buf32(0x11), Buffer.alloc(33), null, null, 1),
      ).toThrow(/scanPubkey must be 32 bytes/);
    } finally {
      store.close();
    }
  });

  it('upsertKeys: throws on empty ownerPubkey', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() =>
        store.upsertKeys('', buf32(0x11), buf32(0x22), null, null, 1),
      ).toThrow();
    } finally {
      store.close();
    }
  });

  // ---------------------------------------------------------------------------
  // clearUsername
  // ---------------------------------------------------------------------------

  it('clearUsername: sets username to null', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'alice', 1_000);
      store.clearUsername(ALICE, 2_000);
      const entry = store.byOwner(ALICE);
      expect(entry!.username).toBeNull();
      expect(entry!.updatedAt).toBe(2_000);
    } finally {
      store.close();
    }
  });

  // ---------------------------------------------------------------------------
  // byOwner
  // ---------------------------------------------------------------------------

  it('byOwner: returns null for unknown owner', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(store.byOwner('NOPEAAAA')).toBeNull();
    } finally {
      store.close();
    }
  });

  it('byOwner: row with keys but no username has null username', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), bufPq(0xaa), 1, 1_000);
      const entry = store.byOwner(ALICE);
      expect(entry!.username).toBeNull();
      expect(entry!.pqPubkey).not.toBeNull();
    } finally {
      store.close();
    }
  });

  // ---------------------------------------------------------------------------
  // count
  // ---------------------------------------------------------------------------

  it('count: returns 0 on empty store', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(store.count()).toBe(0);
    } finally {
      store.close();
    }
  });

  it('count: increments on new owner', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'alice', 1);
      expect(store.count()).toBe(1);
      store.upsertUsername(BOB, 'bob', 2);
      expect(store.count()).toBe(2);
      // upsert same owner doesn't increment
      store.upsertUsername(ALICE, 'alice2', 3);
      expect(store.count()).toBe(2);
    } finally {
      store.close();
    }
  });

  // ---------------------------------------------------------------------------
  // search
  // ---------------------------------------------------------------------------

  it('search: case-insensitive substring match', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'AliceWonderland', 1);
      store.upsertUsername(BOB, 'bobby', 2);
      expect(store.search('alice').map((e) => e.username)).toEqual(['AliceWonderland']);
      expect(store.search('ALICE').map((e) => e.username)).toEqual(['AliceWonderland']);
      expect(store.search('bb').map((e) => e.username)).toEqual(['bobby']);
      expect(store.search('zzz')).toEqual([]);
    } finally {
      store.close();
    }
  });

  it('search: escapes SQL LIKE wildcards', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, '100%real', 1);
      store.upsertUsername(BOB, 'fake_user', 2);
      expect(store.search('%').map((e) => e.username)).toEqual(['100%real']);
      expect(store.search('_').map((e) => e.username)).toEqual(['fake_user']);
    } finally {
      store.close();
    }
  });

  it('search: caps result count', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      for (let i = 0; i < 5; i++) {
        store.upsertUsername(`OWNER${i}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`, `user${i}`, i);
      }
      expect(store.search('user', 2)).toHaveLength(2);
      expect(store.search('user', 100)).toHaveLength(5);
    } finally {
      store.close();
    }
  });

  it('search: tolerates single-char typo (fuzzy)', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'johnsmith', 1);
      const results = store.search('jhonsmith');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].username).toBe('johnsmith');
      expect(results[0].matchType).toBe('fuzzy');
    } finally {
      store.close();
    }
  });

  it('search: ranks exact > prefix > substring > fuzzy', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      const names = ['alice', 'alicewonders', 'malice', 'alike'];
      names.forEach((u, i) => {
        store.upsertUsername(
          `OWNER${i}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`,
          u,
          i,
        );
      });
      const results = store.search('alice');
      expect(results[0].username).toBe('alice');
      expect(results[0].matchType).toBe('exact');
      const order = results.map((r) => r.username);
      expect(order.indexOf('alicewonders')).toBeLessThan(order.indexOf('malice'));
    } finally {
      store.close();
    }
  });

  it('search: trigram index stays in sync after username rename', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'oldname', 1);
      expect(store.search('oldname').map((e) => e.username)).toContain('oldname');
      store.upsertUsername(ALICE, 'newname', 2);
      expect(store.search('oldname')).toEqual([]);
      expect(store.search('newname').map((e) => e.username)).toEqual(['newname']);
    } finally {
      store.close();
    }
  });

  it('search: store starts empty (DROP+CREATE on open wipes prior data)', () => {
    // user-store drops and recreates the table on every open so the
    // user-watcher can replay from genesis with correct selectors.
    // This test documents that intentional behavior.
    const s1 = createUserDirectoryStore(dbPath);
    s1.upsertUsername(ALICE, 'persisted', 1);
    s1.close();

    const s2 = createUserDirectoryStore(dbPath);
    try {
      expect(s2.count()).toBe(0);
      expect(s2.search('persisted')).toHaveLength(0);
    } finally {
      s2.close();
    }
  });

  // ---------------------------------------------------------------------------
  // upsertBio
  // ---------------------------------------------------------------------------

  it('upsertBio: sets and retrieves bio; seeds row if absent', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertBio(ALICE, 'friendly and hardworking', 1_000);
      const e = store.byOwner(ALICE);
      expect(e).not.toBeNull();
      expect(e!.bio).toBe('friendly and hardworking');
      expect(e!.username).toBeNull(); // independent column
    } finally {
      store.close();
    }
  });

  it('upsertBio: empty string and null both clear to NULL', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertBio(ALICE, 'has a bio', 1);
      store.upsertBio(ALICE, '', 2);
      expect(store.byOwner(ALICE)!.bio).toBeNull();
      store.upsertBio(ALICE, 'again', 3);
      store.upsertBio(ALICE, null, 4);
      expect(store.byOwner(ALICE)!.bio).toBeNull();
    } finally {
      store.close();
    }
  });

  it('upsertBio: does not affect username search index', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsertUsername(ALICE, 'alice', 1);
      store.upsertBio(ALICE, 'unsearchable bio text zzqx', 2);
      expect(store.search('zzqx')).toEqual([]); // bio never matches
      const hits = store.search('alice');
      expect(hits.map((e) => e.username)).toEqual(['alice']);
      expect(hits[0].bio).toBe('unsearchable bio text zzqx'); // but rides along
    } finally {
      store.close();
    }
  });

  it('upsertBio: throws on empty ownerPubkey', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() => store.upsertBio('', 'bio', 1)).toThrow();
    } finally {
      store.close();
    }
  });

  it('bio column migration: opening a pre-bio database adds the column', () => {
    // Simulate a pre-bio schema, then reopen through the store factory.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const Database = require('better-sqlite3');
    const legacy = new Database(dbPath);
    legacy.exec(`
      CREATE TABLE users (
        owner_pubkey       TEXT PRIMARY KEY,
        username           TEXT,
        encryption_pubkey  BLOB,
        scan_pubkey        BLOB,
        pq_pubkey          BLOB,
        pq_published_round INTEGER,
        registered_at      INTEGER NOT NULL,
        updated_at         INTEGER NOT NULL
      );
    `);
    legacy
      .prepare(
        'INSERT INTO users (owner_pubkey, username, registered_at, updated_at) VALUES (?, ?, ?, ?)',
      )
      .run(BOB, 'bob', 1, 1);
    legacy.close();

    const store = createUserDirectoryStore(dbPath);
    try {
      const e = store.byOwner(BOB);
      expect(e).not.toBeNull();
      expect(e!.bio).toBeNull(); // migrated column, defaults NULL
      store.upsertBio(BOB, 'post-migration bio', 2);
      expect(store.byOwner(BOB)!.bio).toBe('post-migration bio');
    } finally {
      store.close();
    }
  });
});

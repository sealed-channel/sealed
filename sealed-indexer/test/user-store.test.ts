/**
 * Unit tests for the SQLite-backed user directory store.
 */

import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createUserDirectoryStore } from '../src/users/user-store';

const ALICE = 'ALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BOB = 'BOBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

function buf32(byte: number): Buffer {
  return Buffer.alloc(32, byte);
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

  it('upserts and retrieves a user by owner', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsert({
        ownerPubkey: ALICE,
        username: 'alice',
        encryptionPubkey: buf32(0x11),
        scanPubkey: buf32(0x22),
        observedAt: 1_000,
      });
      const entry = store.byOwner(ALICE);
      expect(entry).not.toBeNull();
      expect(entry!.username).toBe('alice');
      expect(entry!.encryptionPubkey.equals(buf32(0x11))).toBe(true);
      expect(entry!.scanPubkey.equals(buf32(0x22))).toBe(true);
      expect(entry!.registeredAt).toBe(1_000);
      expect(entry!.updatedAt).toBe(1_000);
    } finally {
      store.close();
    }
  });

  it('returns null for unknown owner', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(store.byOwner('NOPEAAAA')).toBeNull();
    } finally {
      store.close();
    }
  });

  it('preserves registered_at on conflict but updates keys + updated_at', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsert({
        ownerPubkey: ALICE,
        username: 'alice',
        encryptionPubkey: buf32(0x11),
        scanPubkey: buf32(0x22),
        observedAt: 1_000,
      });
      store.upsert({
        ownerPubkey: ALICE,
        username: 'alice2',
        encryptionPubkey: buf32(0x33),
        scanPubkey: buf32(0x44),
        observedAt: 2_000,
      });
      const entry = store.byOwner(ALICE);
      expect(entry!.username).toBe('alice2');
      expect(entry!.encryptionPubkey.equals(buf32(0x33))).toBe(true);
      expect(entry!.scanPubkey.equals(buf32(0x44))).toBe(true);
      expect(entry!.registeredAt).toBe(1_000); // preserved
      expect(entry!.updatedAt).toBe(2_000); // updated
    } finally {
      store.close();
    }
  });

  it('rejects wrong-length pubkeys', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() =>
        store.upsert({
          ownerPubkey: ALICE,
          username: 'alice',
          encryptionPubkey: Buffer.alloc(31),
          scanPubkey: buf32(0x22),
          observedAt: 1_000,
        }),
      ).toThrow(/encryptionPubkey must be 32 bytes/);
      expect(() =>
        store.upsert({
          ownerPubkey: ALICE,
          username: 'alice',
          encryptionPubkey: buf32(0x11),
          scanPubkey: Buffer.alloc(33),
          observedAt: 1_000,
        }),
      ).toThrow(/scanPubkey must be 32 bytes/);
    } finally {
      store.close();
    }
  });

  it('rejects empty username and owner', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(() =>
        store.upsert({
          ownerPubkey: '',
          username: 'alice',
          encryptionPubkey: buf32(1),
          scanPubkey: buf32(2),
          observedAt: 1,
        }),
      ).toThrow();
      expect(() =>
        store.upsert({
          ownerPubkey: ALICE,
          username: '',
          encryptionPubkey: buf32(1),
          scanPubkey: buf32(2),
          observedAt: 1,
        }),
      ).toThrow();
    } finally {
      store.close();
    }
  });

  it('search performs case-insensitive substring match', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsert({
        ownerPubkey: ALICE,
        username: 'AliceWonderland',
        encryptionPubkey: buf32(1),
        scanPubkey: buf32(2),
        observedAt: 1,
      });
      store.upsert({
        ownerPubkey: BOB,
        username: 'bobby',
        encryptionPubkey: buf32(3),
        scanPubkey: buf32(4),
        observedAt: 2,
      });
      expect(store.search('alice').map((e) => e.username)).toEqual(['AliceWonderland']);
      expect(store.search('ALICE').map((e) => e.username)).toEqual(['AliceWonderland']);
      expect(store.search('bb').map((e) => e.username)).toEqual(['bobby']);
      expect(store.search('zzz')).toEqual([]);
    } finally {
      store.close();
    }
  });

  it('search escapes SQL LIKE wildcards in user input', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsert({
        ownerPubkey: ALICE,
        username: '100%real',
        encryptionPubkey: buf32(1),
        scanPubkey: buf32(2),
        observedAt: 1,
      });
      store.upsert({
        ownerPubkey: BOB,
        username: 'fake_user',
        encryptionPubkey: buf32(3),
        scanPubkey: buf32(4),
        observedAt: 2,
      });
      // '%' must be a literal — should match only "100%real", not everything.
      expect(store.search('%').map((e) => e.username)).toEqual(['100%real']);
      // '_' must be literal — should match only "fake_user".
      expect(store.search('_').map((e) => e.username)).toEqual(['fake_user']);
    } finally {
      store.close();
    }
  });

  it('search caps the result count', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      for (let i = 0; i < 5; i++) {
        store.upsert({
          ownerPubkey: `OWNER${i}`,
          username: `user${i}`,
          encryptionPubkey: buf32(1),
          scanPubkey: buf32(2),
          observedAt: i,
        });
      }
      expect(store.search('user', 2)).toHaveLength(2);
      expect(store.search('user', 100)).toHaveLength(5);
    } finally {
      store.close();
    }
  });

  it('count returns row count', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      expect(store.count()).toBe(0);
      store.upsert({
        ownerPubkey: ALICE,
        username: 'alice',
        encryptionPubkey: buf32(1),
        scanPubkey: buf32(2),
        observedAt: 1,
      });
      expect(store.count()).toBe(1);
    } finally {
      store.close();
    }
  });

  it('fuzzy search tolerates a single-character typo', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsert({
        ownerPubkey: ALICE,
        username: 'johnsmith',
        encryptionPubkey: buf32(1),
        scanPubkey: buf32(2),
        observedAt: 1,
      });
      store.upsert({
        ownerPubkey: BOB,
        username: 'bobby',
        encryptionPubkey: buf32(3),
        scanPubkey: buf32(4),
        observedAt: 2,
      });
      // typo: 'jhonsmith' → should still surface 'johnsmith' as top result
      const results = store.search('jhonsmith');
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].username).toBe('johnsmith');
      expect(results[0].matchType).toBe('fuzzy');
      expect(typeof results[0].score).toBe('number');
    } finally {
      store.close();
    }
  });

  it('fuzzy search ranks exact > prefix > substring > fuzzy', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      const names = ['alice', 'alicewonders', 'malice', 'alike'];
      names.forEach((u, i) => {
        store.upsert({
          ownerPubkey: `OWNER${i}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`,
          username: u,
          encryptionPubkey: buf32(i + 1),
          scanPubkey: buf32(i + 1),
          observedAt: i,
        });
      });
      const results = store.search('alice');
      const first = results[0];
      expect(first.username).toBe('alice');
      expect(first.matchType).toBe('exact');
      // 'alicewonders' is prefix, 'malice' is substring → prefix beats substring
      const order = results.map((r) => r.username);
      expect(order.indexOf('alicewonders')).toBeLessThan(order.indexOf('malice'));
    } finally {
      store.close();
    }
  });

  it('upsert keeps the trigram index in sync when a username changes', () => {
    const store = createUserDirectoryStore(dbPath);
    try {
      store.upsert({
        ownerPubkey: ALICE,
        username: 'oldname',
        encryptionPubkey: buf32(1),
        scanPubkey: buf32(2),
        observedAt: 1,
      });
      // sanity: old name is indexed
      expect(store.search('oldname').map((e) => e.username)).toContain('oldname');

      // Rename
      store.upsert({
        ownerPubkey: ALICE,
        username: 'newname',
        encryptionPubkey: buf32(1),
        scanPubkey: buf32(2),
        observedAt: 2,
      });
      // Old trigrams must be evicted; new trigrams must be present.
      expect(store.search('oldname')).toEqual([]);
      expect(store.search('newname').map((e) => e.username)).toEqual(['newname']);
    } finally {
      store.close();
    }
  });

  it('trigram index is rebuilt from disk on store open', () => {
    // Write through one store, reopen, search — exercises the boot-time
    // hydration loop in createUserDirectoryStore.
    const s1 = createUserDirectoryStore(dbPath);
    s1.upsert({
      ownerPubkey: ALICE,
      username: 'persisted',
      encryptionPubkey: buf32(1),
      scanPubkey: buf32(2),
      observedAt: 1,
    });
    s1.close();

    const s2 = createUserDirectoryStore(dbPath);
    try {
      const results = s2.search('persited'); // typo
      expect(results.length).toBeGreaterThan(0);
      expect(results[0].username).toBe('persisted');
    } finally {
      s2.close();
    }
  });
});

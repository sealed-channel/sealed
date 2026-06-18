/**
 * Unit tests for the on-chain UsernameRegistry mirror store.
 */
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createUsernameRegistryStore } from '../src/users/username-registry-store';
import type { UsernameRegistryStore } from '../src/users/username-registry-store';

const ALICE = 'ALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BOB = 'BOBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

// A unix timestamp well in the future so cooldown tests read as "active".
const FAR_FUTURE = Math.floor(Date.now() / 1000) + 86_400 * 365;

function buf32(byte: number): Buffer {
  return Buffer.alloc(32, byte);
}

describe('UsernameRegistryStore', () => {
  let dir: string;
  let dbPath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'username-store-test-'));
    dbPath = join(dir, 'indexer.db');
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it('upserts and retrieves by name', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      store.upsert({
        name: 'alice',
        owner: ALICE,
        aliasPubkey: buf32(0x11),
        claimedAt: 1_700_000_000,
        appRound: 42,
      });
      const rec = store.byName('alice');
      expect(rec).not.toBeNull();
      expect(rec!.owner).toBe(ALICE);
      expect(rec!.aliasPubkey.equals(buf32(0x11))).toBe(true);
      expect(rec!.claimedAt).toBe(1_700_000_000);
      expect(rec!.appRound).toBe(42);
    } finally {
      store.close();
    }
  });

  it('lowercases name on read and write', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      store.upsert({
        name: 'Alice',
        owner: ALICE,
        aliasPubkey: buf32(0x11),
        claimedAt: 1,
        appRound: 1,
      });
      expect(store.byName('alice')).not.toBeNull();
      expect(store.byName('ALICE')).not.toBeNull();
    } finally {
      store.close();
    }
  });

  it('isAvailable: true for unclaimed, false for claimed', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      expect(store.isAvailable('alice')).toBe(true);
      store.upsert({
        name: 'alice',
        owner: ALICE,
        aliasPubkey: buf32(0x11),
        claimedAt: 1,
        appRound: 1,
      });
      expect(store.isAvailable('alice')).toBe(false);
      expect(store.isAvailable('bob')).toBe(true);
    } finally {
      store.close();
    }
  });

  it('idempotent on replay: second upsert keeps original row', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      store.upsert({
        name: 'alice',
        owner: ALICE,
        aliasPubkey: buf32(0x11),
        claimedAt: 100,
        appRound: 1,
      });
      // simulated replay with different "later" data — should be ignored
      store.upsert({
        name: 'alice',
        owner: BOB,
        aliasPubkey: buf32(0x22),
        claimedAt: 200,
        appRound: 2,
      });
      const rec = store.byName('alice')!;
      expect(rec.owner).toBe(ALICE);
      expect(rec.aliasPubkey.equals(buf32(0x11))).toBe(true);
      expect(rec.claimedAt).toBe(100);
      expect(store.count()).toBe(1);
    } finally {
      store.close();
    }
  });

  it('byOwner returns first claim for that wallet', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      store.upsert({
        name: 'alice',
        owner: ALICE,
        aliasPubkey: buf32(0x11),
        claimedAt: 100,
        appRound: 1,
      });
      const rec = store.byOwner(ALICE);
      expect(rec).not.toBeNull();
      expect(rec!.name).toBe('alice');
    } finally {
      store.close();
    }
  });

  it('byName/byOwner return null for missing rows', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      expect(store.byName('ghost')).toBeNull();
      expect(store.byOwner(BOB)).toBeNull();
    } finally {
      store.close();
    }
  });

  it('rejects bad pubkey length', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      expect(() =>
        store.upsert({
          name: 'alice',
          owner: ALICE,
          aliasPubkey: Buffer.alloc(31, 0),
          claimedAt: 1,
          appRound: 1,
        }),
      ).toThrow(/32 bytes/);
    } finally {
      store.close();
    }
  });

  it('rejects empty name and owner', () => {
    const store = createUsernameRegistryStore(dbPath);
    try {
      expect(() =>
        store.upsert({
          name: '',
          owner: ALICE,
          aliasPubkey: buf32(0x11),
          claimedAt: 1,
          appRound: 1,
        }),
      ).toThrow(/name/);
      expect(() =>
        store.upsert({
          name: 'alice',
          owner: '',
          aliasPubkey: buf32(0x11),
          claimedAt: 1,
          appRound: 1,
        }),
      ).toThrow(/owner/);
    } finally {
      store.close();
    }
  });

  it('persists across reopen', () => {
    const a = createUsernameRegistryStore(dbPath);
    a.upsert({
      name: 'alice',
      owner: ALICE,
      aliasPubkey: buf32(0x11),
      claimedAt: 1,
      appRound: 1,
    });
    a.close();

    const b = createUsernameRegistryStore(dbPath);
    try {
      expect(b.byName('alice')).not.toBeNull();
      expect(b.count()).toBe(1);
    } finally {
      b.close();
    }
  });

  describe('release', () => {
    function claimAlice(store: UsernameRegistryStore) {
      store.upsert({ name: 'alice', owner: ALICE, aliasPubkey: buf32(0x11), claimedAt: 100, appRound: 1 });
    }

    it('deletes usernames row and creates cooldown row', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        claimAlice(store);
        store.release('alice', ALICE, FAR_FUTURE, 2);
        expect(store.byName('alice')).toBeNull();
        const cd = store.getCooldown('alice');
        expect(cd).not.toBeNull();
        expect(cd!.prevOwner).toBe(ALICE);
        expect(cd!.expiresAt).toBe(FAR_FUTURE);
        expect(cd!.appRound).toBe(2);
      } finally { store.close(); }
    });

    it('availability returns cooldown state after release', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        claimAlice(store);
        store.release('alice', ALICE, FAR_FUTURE, 2);
        const av = store.availability('alice');
        expect(av.state).toBe('cooldown');
        if (av.state === 'cooldown') {
          expect(av.cooldown.prevOwner).toBe(ALICE);
        }
      } finally { store.close(); }
    });

    it('isAvailable returns false during cooldown', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        claimAlice(store);
        store.release('alice', ALICE, FAR_FUTURE, 2);
        expect(store.isAvailable('alice')).toBe(false);
      } finally { store.close(); }
    });

    it('idempotent: release on already-released name is a no-op', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        claimAlice(store);
        store.release('alice', ALICE, FAR_FUTURE, 2);
        // Second release (replay) — cooldown row already exists; INSERT OR REPLACE updates it.
        expect(() => store.release('alice', ALICE, FAR_FUTURE + 1, 3)).not.toThrow();
        // Username row still gone.
        expect(store.byName('alice')).toBeNull();
      } finally { store.close(); }
    });

    it('availability returns free when cooldown expired', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        claimAlice(store);
        const PAST = Math.floor(Date.now() / 1000) - 1;
        store.release('alice', ALICE, PAST, 2);
        expect(store.availability('alice').state).toBe('free');
        expect(store.isAvailable('alice')).toBe(true);
      } finally { store.close(); }
    });
  });

  describe('rename', () => {
    it('atomically deletes old name and inserts new name', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        store.upsert({ name: 'alice', owner: ALICE, aliasPubkey: buf32(0x11), claimedAt: 100, appRound: 1 });
        store.rename('alice', 'alicia', buf32(0x22), 200, 2, ALICE);
        expect(store.byName('alice')).toBeNull();
        const rec = store.byName('alicia');
        expect(rec).not.toBeNull();
        expect(rec!.owner).toBe(ALICE);
        expect(rec!.aliasPubkey.equals(buf32(0x22))).toBe(true);
        expect(rec!.appRound).toBe(2);
      } finally { store.close(); }
    });

    it('idempotent: replay of rename keeps new name, old stays absent', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        store.upsert({ name: 'alice', owner: ALICE, aliasPubkey: buf32(0x11), claimedAt: 100, appRound: 1 });
        store.rename('alice', 'alicia', buf32(0x22), 200, 2, ALICE);
        // Replay
        store.rename('alice', 'alicia', buf32(0x33), 300, 3, ALICE);
        // INSERT OR IGNORE keeps first-seen row for alicia.
        expect(store.byName('alicia')!.aliasPubkey.equals(buf32(0x22))).toBe(true);
        expect(store.byName('alice')).toBeNull();
      } finally { store.close(); }
    });
  });

  describe('clearCooldown', () => {
    it('removes cooldown row (sweepExpiredCooldown)', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        store.upsert({ name: 'alice', owner: ALICE, aliasPubkey: buf32(0x11), claimedAt: 100, appRound: 1 });
        store.release('alice', ALICE, FAR_FUTURE, 2);
        store.clearCooldown('alice');
        expect(store.getCooldown('alice')).toBeNull();
        expect(store.availability('alice').state).toBe('free');
      } finally { store.close(); }
    });

    it('no-op when cooldown row absent', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        expect(() => store.clearCooldown('ghost')).not.toThrow();
      } finally { store.close(); }
    });
  });

  describe('availability', () => {
    it('free for unclaimed name with no cooldown', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        expect(store.availability('alice').state).toBe('free');
      } finally { store.close(); }
    });

    it('claimed for active claim', () => {
      const store = createUsernameRegistryStore(dbPath);
      try {
        store.upsert({ name: 'alice', owner: ALICE, aliasPubkey: buf32(0x11), claimedAt: 100, appRound: 1 });
        const av = store.availability('alice');
        expect(av.state).toBe('claimed');
        if (av.state === 'claimed') expect(av.record.owner).toBe(ALICE);
      } finally { store.close(); }
    });
  });

  describe('search', () => {
    function setup() {
      const store = createUsernameRegistryStore(dbPath);
      const names = ['alice', 'alice1', 'alice2', 'bob', 'alicia'];
      names.forEach((name, i) =>
        store.upsert({ name, owner: ALICE, aliasPubkey: Buffer.alloc(32, i), claimedAt: i + 1, appRound: i + 1 }),
      );
      return store;
    }

    it('prefix match returns alice, alice1, alice2, alicia for "alic"', () => {
      const store = setup();
      const res = store.search('alic');
      expect(res.map(r => r.name).sort()).toEqual(['alice', 'alice1', 'alice2', 'alicia']);
      store.close();
    });

    it('exact prefix match returns only matching names', () => {
      const store = setup();
      const res = store.search('alice');
      expect(res.map(r => r.name)).toContain('alice');
      expect(res.map(r => r.name)).toContain('alice1');
      store.close();
    });

    it('infix match finds alice via "lic"', () => {
      const store = setup();
      const res = store.search('lic');
      const names = res.map(r => r.name);
      expect(names).toContain('alice');
      store.close();
    });

    it('no match returns empty', () => {
      const store = setup();
      expect(store.search('zzz')).toHaveLength(0);
      store.close();
    });

    it('empty query returns empty', () => {
      const store = setup();
      expect(store.search('')).toHaveLength(0);
      store.close();
    });

    it('respects limit', () => {
      const store = setup();
      const res = store.search('a', 2);
      expect(res.length).toBeLessThanOrEqual(2);
      store.close();
    });
  });
});

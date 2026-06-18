/**
 * Unit tests for username-watcher.ts — decodeClaimUsername + watcher integration.
 * Uses a mock subscriber factory so no real algod is needed.
 *
 * Multi-filter mock: the mock subscriber collects all on() registrations into
 * a filterMap so tests can fire individual filters by name.
 */
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import pino from 'pino';
import {
  decodeClaimUsername,
  createUsernameWatcher,
  type SubscribedTxn,
  type SubscriberLike,
  type WatcherSubscriberConfig,
} from '../src/users/username-watcher';
import { createUsernameRegistryStore } from '../src/users/username-registry-store';
import type { CursorStore } from '../src/notifications/cursor-store';

// ─── Selectors ────────────────────────────────────────────────────────────────
const SEL_CLAIM   = Buffer.from([0x7f, 0xd7, 0xa1, 0x4b]);
const SEL_RELEASE = Buffer.from([0xb4, 0xe2, 0x0f, 0x0c]);
const SEL_RENAME  = Buffer.from([0xa3, 0x37, 0xdc, 0x8b]);
const SEL_SWEEP   = Buffer.from([0x7f, 0xb4, 0x34, 0x05]);

const OWNER = 'ALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BOB   = 'BOBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const logger = pino({ level: 'silent' });

const FAR_FUTURE_S = Math.floor(Date.now() / 1000) + 86_400 * 365;

function nullCursor(): CursorStore {
  let r: bigint | null = null;
  return { getRound: () => r, setRound: (v: bigint) => { r = v; } } as CursorStore;
}

/** Encode payload as ABI dynamic-bytes (2-byte BE length prefix || payload). */
function abiDyn(payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + payload.length);
  out[0] = (payload.length >> 8) & 0xff;
  out[1] = payload.length & 0xff;
  out.set(payload, 2);
  return out;
}

function nameBytes(s: string): Uint8Array { return new TextEncoder().encode(s); }
function pubkey(b: number): Uint8Array { return new Uint8Array(32).fill(b); }

// ─── txn builders per method ──────────────────────────────────────────────────

function claimTxn(name: string, pk?: Uint8Array, overrides: Partial<SubscribedTxn> = {}): SubscribedTxn {
  return {
    id: 'TX-CLAIM', sender: OWNER, confirmedRound: 100n, roundTime: 1_700_000_000,
    applicationTransaction: {
      applicationArgs: [SEL_CLAIM, abiDyn(nameBytes(name)), abiDyn(pk ?? pubkey(0xab))],
    },
    ...overrides,
  };
}

function releaseTxn(name: string, sender = OWNER, overrides: Partial<SubscribedTxn> = {}): SubscribedTxn {
  return {
    id: 'TX-RELEASE', sender, confirmedRound: 200n, roundTime: 1_700_001_000,
    applicationTransaction: { applicationArgs: [SEL_RELEASE, abiDyn(nameBytes(name))] },
    ...overrides,
  };
}

function renameTxn(
  oldName: string, newName: string, pk?: Uint8Array,
  sender = OWNER, overrides: Partial<SubscribedTxn> = {},
): SubscribedTxn {
  return {
    id: 'TX-RENAME', sender, confirmedRound: 300n, roundTime: 1_700_002_000,
    applicationTransaction: {
      applicationArgs: [SEL_RENAME, abiDyn(nameBytes(oldName)), abiDyn(nameBytes(newName)), abiDyn(pk ?? pubkey(0xcc))],
    },
    ...overrides,
  };
}

function sweepTxn(name: string, overrides: Partial<SubscribedTxn> = {}): SubscribedTxn {
  return {
    id: 'TX-SWEEP', sender: BOB, confirmedRound: 400n, roundTime: 1_700_003_000,
    applicationTransaction: { applicationArgs: [SEL_SWEEP, abiDyn(nameBytes(name))] },
    ...overrides,
  };
}

// ─── Multi-filter mock subscriber ────────────────────────────────────────────

type Handler = (txn: SubscribedTxn) => void | Promise<void>;

function makeMultiFilterMock(): { subscriber: SubscriberLike; fire: (filter: string, txn: SubscribedTxn) => Promise<void> } {
  const handlers = new Map<string, Handler>();
  const subscriber: SubscriberLike = {
    on(name, handler) { handlers.set(name, handler); },
    onError() {},
    start() {},
    async stop() {},
  };
  return {
    subscriber,
    fire: async (filter, txn) => {
      const h = handlers.get(filter);
      if (!h) throw new Error(`No handler registered for filter "${filter}"`);
      await h(txn);
    },
  };
}

// ─── decodeClaimUsername unit tests ──────────────────────────────────────────

describe('decodeClaimUsername', () => {
  it('decodes valid claim', () => {
    const pk = pubkey(0x42);
    const decoded = decodeClaimUsername(claimTxn('alice', pk), logger);
    expect(decoded).not.toBeNull();
    expect(decoded!.name).toBe('alice');
    expect(decoded!.owner).toBe(OWNER);
    expect(Buffer.from(decoded!.aliasPubkey).equals(Buffer.from(pk))).toBe(true);
    expect(decoded!.claimedAt).toBe(1_700_000_000);
    expect(decoded!.appRound).toBe(100);
  });

  it('lowercases name', () => {
    expect(decodeClaimUsername(claimTxn('Alice'), logger)?.name).toBe('alice');
  });

  it('returns null on selector mismatch', () => {
    const txn = claimTxn('alice');
    const args = txn.applicationTransaction!.applicationArgs!;
    expect(decodeClaimUsername(
      { ...txn, applicationTransaction: { ...txn.applicationTransaction, applicationArgs: [new Uint8Array(4), ...Array.from(args).slice(1)] } },
      logger,
    )).toBeNull();
  });

  it('returns null when missing applicationArgs', () => {
    expect(decodeClaimUsername({ ...claimTxn('alice'), applicationTransaction: {} }, logger)).toBeNull();
  });

  it('returns null when arg count wrong', () => {
    const txn = claimTxn('alice');
    const args = Array.from(txn.applicationTransaction!.applicationArgs!).slice(0, 2);
    expect(decodeClaimUsername(
      { ...txn, applicationTransaction: { ...txn.applicationTransaction, applicationArgs: args } },
      logger,
    )).toBeNull();
  });

  it('returns null for name > 20 bytes', () => {
    expect(decodeClaimUsername(claimTxn('a'.repeat(21)), logger)).toBeNull();
  });

  it('returns null for wrong pubkey length', () => {
    expect(decodeClaimUsername(claimTxn('alice', new Uint8Array(31).fill(1)), logger)).toBeNull();
  });

  it('returns null when sender missing', () => {
    expect(decodeClaimUsername(claimTxn('alice', undefined, { sender: undefined }), logger)).toBeNull();
  });

  it('returns null for non-utf8 name bytes', () => {
    const txn: SubscribedTxn = {
      id: 'T2', sender: OWNER, confirmedRound: 1n, roundTime: 1,
      applicationTransaction: {
        applicationArgs: [SEL_CLAIM, abiDyn(new Uint8Array([0xff, 0xfe, 0xfd])), abiDyn(pubkey(0))],
      },
    };
    expect(decodeClaimUsername(txn, logger)).toBeNull();
  });
});

// ─── Integration: multi-filter lifecycle sequence ────────────────────────────

describe('createUsernameWatcher — integration', () => {
  let dir: string;
  let dbPath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'username-watcher-test-'));
    dbPath = join(dir, 'indexer.db');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  function setupWatcher() {
    const store = createUsernameRegistryStore(dbPath);
    const cursor = nullCursor();
    const { subscriber, fire } = makeMultiFilterMock();

    const watcher = createUsernameWatcher({
      algodUrl: 'http://localhost:4001',
      registryAppId: 9999n,
      cursor,
      store,
      logger,
      subscriberFactory: (_cfg: WatcherSubscriberConfig) => subscriber,
    });

    return { store, watcher, fire };
  }

  it('upserts claim into store when subscriber fires', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    const pk = pubkey(0x55);
    await fire('claim-username-calls', claimTxn('alice', pk));

    const rec = store.byName('alice');
    expect(rec).not.toBeNull();
    expect(rec!.owner).toBe(OWNER);
    expect(Buffer.from(rec!.aliasPubkey).equals(Buffer.from(pk))).toBe(true);
    expect(rec!.appRound).toBe(100);

    await watcher.stop();
    store.close();
  });

  it('release: removes claim row, creates cooldown row', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    await fire('claim-username-calls', claimTxn('alice'));
    expect(store.byName('alice')).not.toBeNull();

    await fire('release-username-calls', releaseTxn('alice'));
    expect(store.byName('alice')).toBeNull();
    const cd = store.getCooldown('alice');
    expect(cd).not.toBeNull();
    expect(cd!.prevOwner).toBe(OWNER);
    // expiresAt = roundTime (1_700_001_000) + 86400
    expect(cd!.expiresAt).toBe(1_700_001_000 + 86_400);

    await watcher.stop();
    store.close();
  });

  it('rename: old name gone, new name present', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    await fire('claim-username-calls', claimTxn('alice', pubkey(0x11)));
    await fire('rename-username-calls', renameTxn('alice', 'alicia', pubkey(0x22)));

    expect(store.byName('alice')).toBeNull();
    const rec = store.byName('alicia');
    expect(rec).not.toBeNull();
    expect(rec!.owner).toBe(OWNER);
    expect(Buffer.from(rec!.aliasPubkey).equals(Buffer.from(pubkey(0x22)))).toBe(true);

    await watcher.stop();
    store.close();
  });

  it('sweep: clears cooldown row', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    await fire('claim-username-calls', claimTxn('alice'));
    await fire('release-username-calls', releaseTxn('alice'));
    expect(store.getCooldown('alice')).not.toBeNull();

    await fire('sweep-cooldown-calls', sweepTxn('alice'));
    expect(store.getCooldown('alice')).toBeNull();
    expect(store.availability('alice').state).toBe('free');

    await watcher.stop();
    store.close();
  });

  it('full lifecycle: claim → release → reclaim by other → rename → sweep', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    // Alice claims
    await fire('claim-username-calls', claimTxn('alice', pubkey(0x11)));
    expect(store.byName('alice')!.owner).toBe(OWNER);

    // Alice releases — enters cooldown
    // Use far-future roundTime so cooldown window is still active during test.
    const futureRelease = FAR_FUTURE_S - 86_400;
    await fire('release-username-calls', releaseTxn('alice', OWNER, { roundTime: futureRelease }));
    expect(store.availability('alice').state).toBe('cooldown');

    // Alice re-claims during cooldown (prev owner allowed by contract)
    // Simulate: claim tx fires again — store.upsert inserts (cooldown still in DB
    // until explicitly cleared; watcher's claimFilter fires upsert which no-ops on
    // existing row — real on-chain watcher would see the cooldown cleared by the
    // contract. We model this by having the claim handler clear the cooldown first.)
    // Actually our current watcher's claimFilter just calls store.upsert; the claim
    // logic trusts the chain. For the purpose of the test we verify that upsert
    // after a claim fires again keeps the store consistent.
    await fire('claim-username-calls', claimTxn('alice', pubkey(0x33), { sender: BOB, id: 'TX-RECLAIM', confirmedRound: 250n }));
    // INSERT OR IGNORE — original alice row gone (released), BOB's new claim inserts.
    // After release, usernames row was deleted so BOB's upsert succeeds.
    const afterReclaim = store.byName('alice');
    expect(afterReclaim).not.toBeNull();
    expect(afterReclaim!.owner).toBe(BOB);

    // Bob renames alice → alice2
    await fire('rename-username-calls', renameTxn('alice', 'alice2', pubkey(0x44), BOB, { id: 'TX-RENAME2', confirmedRound: 350n }));
    expect(store.byName('alice')).toBeNull();
    expect(store.byName('alice2')!.owner).toBe(BOB);

    // Sweep the lingering cooldown from Alice's original release
    await fire('sweep-cooldown-calls', sweepTxn('alice'));
    expect(store.getCooldown('alice')).toBeNull();

    await watcher.stop();
    store.close();
  });

  it('replay idempotency: same claim + release + sweep sequence twice = same state', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    async function runSequence() {
      await fire('claim-username-calls', claimTxn('alice'));
      await fire('release-username-calls', releaseTxn('alice'));
      await fire('sweep-cooldown-calls', sweepTxn('alice'));
    }

    await runSequence();
    const stateAfterFirst = store.availability('alice');

    await runSequence();
    const stateAfterSecond = store.availability('alice');

    expect(stateAfterFirst.state).toBe(stateAfterSecond.state);

    await watcher.stop();
    store.close();
  });

  it('out-of-order: release before claim is a no-op, claim later wins', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    // Release fires before claim (should not throw, no username row to delete)
    await fire('release-username-calls', releaseTxn('alice'));
    // Cooldown row exists (INSERT OR REPLACE is fine), but no username row
    expect(store.byName('alice')).toBeNull();

    // Claim fires after (simulating late delivery) — should insert successfully
    await fire('claim-username-calls', claimTxn('alice'));
    // INSERT OR IGNORE: if cooldown's prevOwner !== current sender this would fail
    // on-chain, but watcher trusts the chain. The claim inserts the username row.
    expect(store.byName('alice')).not.toBeNull();

    await watcher.stop();
    store.close();
  });

  it('ignores malformed txns without throwing', async () => {
    const { store, watcher, fire } = setupWatcher();
    await watcher.start();

    const badTxn: SubscribedTxn = {
      id: 'BAD', sender: OWNER,
      applicationTransaction: { applicationArgs: [new Uint8Array(4), new Uint8Array(5), new Uint8Array(34)] },
    };
    await fire('claim-username-calls', badTxn);
    expect(store.count()).toBe(0);

    await watcher.stop();
    store.close();
  });

  it('start() is idempotent', async () => {
    const store = createUsernameRegistryStore(dbPath);
    let startCount = 0;
    const mockSubscriber: SubscriberLike = {
      on() {}, onError() {}, start() { startCount++; }, async stop() {},
    };

    const watcher = createUsernameWatcher({
      algodUrl: 'http://localhost:4001',
      registryAppId: 9999n,
      cursor: nullCursor(),
      store,
      logger,
      subscriberFactory: () => mockSubscriber,
    });

    await watcher.start();
    await watcher.start();
    expect(startCount).toBe(1);
    await watcher.stop();
    store.close();
  });
});

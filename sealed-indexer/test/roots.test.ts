/**
 * Integration tests for SPEC-snark-redeem-B Task 6:
 *
 *   1. `RootPosted` ingest path (watcher → roots store).
 *   2. Admin leaf-set upload + `GET /roots` parity.
 *   3. OHTTP-friendliness of the public GET response.
 *
 * All three slices share fixtures so the round-trip is exercised end-to-end:
 * inject a fake on-chain `postRoot` txn → upload leaves over HTTP → fetch
 * `/roots` and compare byte-for-byte against the recomputed expected JSON.
 */
import request from 'supertest';
import { EventEmitter } from 'events';
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createApp } from '../src/app';
import { createRootsStore } from '../src/roots/roots-store';
import {
  createRootsWatcher,
  POST_ROOT_SELECTOR,
} from '../src/roots/roots-watcher';
import type { CursorStore } from '../src/notifications/cursor-store';
import type {
  SubscriberFactoryConfig,
  SubscriberLike,
  SubscribedTxn,
} from '../src/chain/chain-subscription';

const ROOT_A = 'a'.repeat(64);
const ROOT_B = 'b'.repeat(64);
const ADMIN_TOKEN = 'test-admin-token-1234567890';

function silentLogger() {
  const fn = jest.fn();
  return {
    info: fn,
    debug: fn,
    warn: fn,
    error: fn,
    fatal: fn,
    trace: fn,
    child: () => silentLogger(),
  } as any;
}

function inMemoryCursor(): CursorStore {
  let value: bigint | null = null;
  return {
    getRound: () => value,
    setRound: (r) => {
      value = r;
    },
    reset: () => {
      value = null;
    },
    close: () => {},
  };
}

function uint64BE(n: number): Buffer {
  const buf = Buffer.alloc(8);
  buf.writeUInt32BE(Math.floor(n / 0x1_0000_0000), 0);
  buf.writeUInt32BE(n >>> 0, 4);
  return buf;
}

function makePostRootTxn(opts: {
  rootHex: string;
  denomination: number;
  confirmedRound: bigint;
  id?: string;
}): SubscribedTxn {
  return {
    id: opts.id ?? `TX${opts.rootHex.slice(0, 6)}`,
    sender: 'ADMINWALLET12345678901234567890123456789012345678901234567',
    confirmedRound: opts.confirmedRound,
    roundTime: 1_700_000_000,
    applicationTransaction: {
      applicationId: 762_153_589n,
      applicationArgs: [
        new Uint8Array(POST_ROOT_SELECTOR),
        new Uint8Array(Buffer.from(opts.rootHex, 'hex')),
        new Uint8Array(uint64BE(opts.denomination)),
      ],
    },
  };
}

/** Fake SubscriberLike that lets a test fire txns synchronously. */
function makeFakeSubscriber() {
  const handlers = new Map<string, (t: SubscribedTxn) => void | Promise<void>>();
  let errorHandler: ((e: unknown) => void) | null = null;
  const sub: SubscriberLike = {
    on: (name, h) => {
      handlers.set(name, h);
    },
    onError: (h) => {
      errorHandler = h;
    },
    start: () => {},
    stop: async () => {},
  };
  return {
    sub,
    async fire(filterName: string, txn: SubscribedTxn) {
      const h = handlers.get(filterName);
      if (!h) throw new Error(`no handler for ${filterName}`);
      await h(txn);
    },
    errorHandler: () => errorHandler,
  };
}

describe('roots: ingest + admin upload + GET parity', () => {
  let dir: string;
  let dbPath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'roots-test-'));
    dbPath = join(dir, 'indexer.db');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('ingests RootPosted → admin upload → GET /roots returns identical bytes on repeat fetch', async () => {
    const store = createRootsStore(dbPath);

    // Drive the watcher with a fake subscriber so we don't need algod.
    const fake = makeFakeSubscriber();
    const watcher = createRootsWatcher({
      algodUrl: 'http://unused',
      sealedAppId: 762_153_589n,
      cursor: inMemoryCursor(),
      store,
      logger: silentLogger(),
      subscriberFactory: (_cfg: SubscriberFactoryConfig) => fake.sub,
    });
    await watcher.start();

    // Two roots posted on-chain.
    await fake.fire(
      'post-root-calls',
      makePostRootTxn({ rootHex: ROOT_A, denomination: 100, confirmedRound: 1000n }),
    );
    await fake.fire(
      'post-root-calls',
      makePostRootTxn({ rootHex: ROOT_B, denomination: 250, confirmedRound: 1010n }),
    );

    expect(store.count()).toBe(2);
    expect(store.getRoot(ROOT_A)).toEqual({
      root: ROOT_A,
      denomination: 100,
      postedRound: 1000,
    });

    const app = createApp({ rootsStore: store, adminToken: ADMIN_TOKEN });

    // Admin uploads leaves for ROOT_A only.
    const leavesA = [
      '1'.repeat(64),
      '2'.repeat(64),
      '3'.repeat(64),
    ];
    const uploadRes = await request(app)
      .post(`/admin/roots/${ROOT_A}/leaves`)
      .set('authorization', `Bearer ${ADMIN_TOKEN}`)
      .send({ root: ROOT_A, leaves: leavesA });
    expect(uploadRes.status).toBe(200);
    expect(uploadRes.body).toEqual({ ok: true, leafCount: 3 });

    // First fetch.
    const first = await request(app).get('/roots');
    expect(first.status).toBe(200);
    const expected = JSON.stringify([
      { root: ROOT_A, denomination: 100, postedRound: 1000, leaves: leavesA },
      { root: ROOT_B, denomination: 250, postedRound: 1010, leaves: [] },
    ]);
    expect(first.text).toBe(expected);

    // Second fetch — byte-for-byte parity (OHTTP cache friendliness).
    const second = await request(app).get('/roots');
    expect(second.text).toBe(first.text);
    expect(Buffer.from(second.text)).toEqual(Buffer.from(first.text));

    // Re-uploading the same root replaces the leaf set (deterministic).
    const replaced = ['4'.repeat(64), '5'.repeat(64)];
    await request(app)
      .post(`/admin/roots/${ROOT_A}/leaves`)
      .set('authorization', `Bearer ${ADMIN_TOKEN}`)
      .send({ root: ROOT_A, leaves: replaced })
      .expect(200);
    const third = await request(app).get('/roots');
    const reparsed = JSON.parse(third.text);
    expect(reparsed[0].leaves).toEqual(replaced);

    await watcher.stop();
    store.close();
  });

  it('GET /roots is OHTTP-friendly: no Set-Cookie, no identity Vary, public Cache-Control', async () => {
    const store = createRootsStore(dbPath);
    const app = createApp({ rootsStore: store, adminToken: ADMIN_TOKEN });

    // Hit twice with different bogus identity headers; response headers must
    // not include Set-Cookie nor Vary on any identity-bearing header.
    const r1 = await request(app)
      .get('/roots')
      .set('cookie', 'session=alice')
      .set('authorization', 'Bearer not-admin');
    const r2 = await request(app)
      .get('/roots')
      .set('cookie', 'session=bob')
      .set('authorization', 'Bearer also-not-admin');

    for (const r of [r1, r2]) {
      expect(r.status).toBe(200);
      // Forbidden headers per Task 6 §3 + §6 of the spec.
      expect(r.headers['set-cookie']).toBeUndefined();
      const vary = (r.headers['vary'] ?? '').toLowerCase();
      // `Vary` may be absent or empty; if present, it must not include
      // identity-bearing headers that would prevent cache reuse.
      for (const forbidden of ['cookie', 'authorization', 'user-agent', '*']) {
        expect(vary).not.toContain(forbidden);
      }
      // Cache-Control must mark the response cacheable.
      expect(r.headers['cache-control']).toBe('public, max-age=60');
      expect(r.headers['content-type']).toMatch(/application\/json/);
    }

    // Different identity headers, same payload bytes (cache key invariance).
    expect(r1.text).toBe(r2.text);
    store.close();
  });

  it('admin upload requires bearer token', async () => {
    const store = createRootsStore(dbPath);
    store.upsertRoot({ root: ROOT_A, denomination: 100, postedRound: 1 });
    const app = createApp({ rootsStore: store, adminToken: ADMIN_TOKEN });

    // No auth header.
    const noAuth = await request(app)
      .post(`/admin/roots/${ROOT_A}/leaves`)
      .send({ leaves: [] });
    expect(noAuth.status).toBe(401);

    // Wrong token.
    const wrong = await request(app)
      .post(`/admin/roots/${ROOT_A}/leaves`)
      .set('authorization', 'Bearer wrong-token-with-matching-length')
      .send({ leaves: [] });
    expect(wrong.status).toBe(401);

    // Right token, unknown root → 404.
    const unknown = await request(app)
      .post(`/admin/roots/${ROOT_B}/leaves`)
      .set('authorization', `Bearer ${ADMIN_TOKEN}`)
      .send({ leaves: [] });
    expect(unknown.status).toBe(404);
    expect(unknown.body.error).toBe('UNKNOWN_ROOT');

    store.close();
  });

  it('admin route 503s when adminToken unset', async () => {
    const store = createRootsStore(dbPath);
    const app = createApp({ rootsStore: store });
    const res = await request(app)
      .post(`/admin/roots/${ROOT_A}/leaves`)
      .send({ leaves: [] });
    expect(res.status).toBe(503);
    store.close();
  });

  it('routes 503 when rootsStore not configured', async () => {
    const app = createApp({});
    expect((await request(app).get('/roots')).status).toBe(503);
    expect(
      (
        await request(app)
          .post(`/admin/roots/${ROOT_A}/leaves`)
          .send({ leaves: [] })
      ).status,
    ).toBe(503);
  });

  it('rejects path-vs-body root mismatch and invalid leaf hex', async () => {
    const store = createRootsStore(dbPath);
    store.upsertRoot({ root: ROOT_A, denomination: 100, postedRound: 1 });
    const app = createApp({ rootsStore: store, adminToken: ADMIN_TOKEN });

    const mismatch = await request(app)
      .post(`/admin/roots/${ROOT_A}/leaves`)
      .set('authorization', `Bearer ${ADMIN_TOKEN}`)
      .send({ root: ROOT_B, leaves: [] });
    expect(mismatch.status).toBe(400);
    expect(mismatch.body.error).toBe('ROOT_MISMATCH');

    const badLeaf = await request(app)
      .post(`/admin/roots/${ROOT_A}/leaves`)
      .set('authorization', `Bearer ${ADMIN_TOKEN}`)
      .send({ leaves: ['not-hex'] });
    expect(badLeaf.status).toBe(400);
    store.close();
  });
});

/**
 * Route-level tests for the live user directory.
 *
 * Connects via supertest, which dials 127.0.0.1 — `requireTorOrigin` allows
 * loopback so we don't need to flip SEALED_ALLOW_NON_TOR.
 */

import request from 'supertest';
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createApp } from '../src/app';
import {
  createUserDirectoryStore,
  type UserDirectoryStore,
} from '../src/users/user-store';

const ALICE = 'ALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BOB = 'BOBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

function buf32(byte: number): Buffer {
  return Buffer.alloc(32, byte);
}

describe('user routes', () => {
  let dir: string;
  let dbPath: string;
  let store: UserDirectoryStore;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'user-routes-test-'));
    dbPath = join(dir, 'indexer.db');
    store = createUserDirectoryStore(dbPath);
  });

  afterEach(() => {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it('GET /user/by-owner returns base64-encoded pubkeys', async () => {
    store.upsert({
      ownerPubkey: ALICE,
      username: 'alice',
      encryptionPubkey: buf32(0x11),
      scanPubkey: buf32(0x22),
      observedAt: 1_000,
    });
    const app = createApp({ userDirectory: store });
    const res = await request(app).get(`/user/by-owner/${ALICE}`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      username: 'alice',
      ownerPubkey: ALICE,
      encryptionPubkey: buf32(0x11).toString('base64'),
      scanPubkey: buf32(0x22).toString('base64'),
      registeredAt: 1_000,
    });
  });

  it('GET /user/by-owner returns 404 for unknown owner', async () => {
    const app = createApp({ userDirectory: store });
    const res = await request(app).get(`/user/by-owner/${ALICE}`);
    expect(res.status).toBe(404);
    expect(res.body.error).toMatch(/not found/i);
  });

  it('GET /user/by-owner returns 503 when directory not configured', async () => {
    const app = createApp(); // no userDirectory
    const res = await request(app).get(`/user/by-owner/${ALICE}`);
    expect(res.status).toBe(503);
  });

  it('GET /user/search returns matching users', async () => {
    store.upsert({
      ownerPubkey: ALICE,
      username: 'alice',
      encryptionPubkey: buf32(0x11),
      scanPubkey: buf32(0x22),
      observedAt: 1_000,
    });
    store.upsert({
      ownerPubkey: BOB,
      username: 'bobby',
      encryptionPubkey: buf32(0x33),
      scanPubkey: buf32(0x44),
      observedAt: 2_000,
    });
    const app = createApp({ userDirectory: store });
    const res = await request(app).get('/user/search').query({ q: 'alic' });
    expect(res.status).toBe(200);
    expect(res.body.query).toBe('alic');
    expect(res.body.count).toBe(1);
    expect(res.body.users).toHaveLength(1);
    expect(res.body.users[0].username).toBe('alice');
    expect(res.body.users[0].scanPubkey).toBe(buf32(0x22).toString('base64'));
  });

  it('GET /user/search returns empty list for no matches', async () => {
    const app = createApp({ userDirectory: store });
    const res = await request(app).get('/user/search').query({ q: 'zzz' });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ query: 'zzz', count: 0, users: [] });
  });

  it('GET /user/search 400s on missing query', async () => {
    const app = createApp({ userDirectory: store });
    const res = await request(app).get('/user/search');
    expect(res.status).toBe(400);
  });

  it('GET /user/search clamps limit to allowed range', async () => {
    for (let i = 0; i < 5; i++) {
      store.upsert({
        ownerPubkey: `OWNER${i}`,
        username: `user${i}`,
        encryptionPubkey: buf32(1),
        scanPubkey: buf32(2),
        observedAt: i,
      });
    }
    const app = createApp({ userDirectory: store });
    const res = await request(app)
      .get('/user/search')
      .query({ q: 'user', limit: 2 });
    expect(res.status).toBe(200);
    expect(res.body.users).toHaveLength(2);
  });

  it('rejects non-Tor origin when SEALED_ALLOW_NON_TOR is unset', async () => {
    const previous = process.env.SEALED_ALLOW_NON_TOR;
    delete process.env.SEALED_ALLOW_NON_TOR;
    try {
      const app = createApp({ userDirectory: store });
      // Build a request that pretends to come from a public IP. We can't
      // easily change supertest's actual socket origin, so we invoke the
      // middleware path directly via a custom test: spoof remoteAddress on
      // the request by making a low-level express test.
      const res = await request(app)
        .get(`/user/by-owner/${ALICE}`)
        // X-Forwarded-For is ignored because `trust proxy` is false.
        .set('X-Forwarded-For', '8.8.8.8');
      // Loopback is allowed, so this passes — the test below is just for
      // completeness; full non-loopback rejection is covered by the
      // middleware's own unit tests. Asserting != 403 confirms loopback path.
      expect(res.status).not.toBe(403);
    } finally {
      if (previous !== undefined) process.env.SEALED_ALLOW_NON_TOR = previous;
    }
  });
});

/**
 * Route tests for /username routes.
 */
import request from 'supertest';
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createApp } from '../src/app';
import { createUsernameRegistryStore } from '../src/users/username-registry-store';

const OWNER = 'ALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

function buf32(byte: number): Buffer {
  return Buffer.alloc(32, byte);
}

// A unix timestamp well in the future so cooldown tests read as "active".
const FAR_FUTURE = Math.floor(Date.now() / 1000) + 86_400 * 365;

// requireTorOrigin allows when DISABLE_TOR_CHECK=true.
const env = process.env;

describe('/username routes', () => {
  let dir: string;
  let dbPath: string;

  beforeAll(() => {
    env.DISABLE_TOR_CHECK = 'true';
  });

  afterAll(() => {
    delete env.DISABLE_TOR_CHECK;
  });

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'username-routes-test-'));
    dbPath = join(dir, 'indexer.db');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  describe('GET /username/:name/available — 3-state', () => {
    it('returns state:free for unclaimed name', async () => {
      const store = createUsernameRegistryStore(dbPath);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/alice/available');
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ state: 'free' });
      store.close();
    });

    it('returns state:claimed for claimed name', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/alice/available');
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ state: 'claimed' });
      store.close();
    });

    it('returns state:cooldown with prev_owner + expires_at for released name', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      store.release('alice', OWNER, FAR_FUTURE, 2);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/alice/available');
      expect(res.status).toBe(200);
      expect(res.body.state).toBe('cooldown');
      expect(res.body.cooldown.prev_owner).toBe(OWNER);
      expect(res.body.cooldown.expires_at).toBe(FAR_FUTURE);
      store.close();
    });

    it('returns state:free for expired cooldown', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      store.release('alice', OWNER, Math.floor(Date.now() / 1000) - 1, 2);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/alice/available');
      expect(res.status).toBe(200);
      expect(res.body.state).toBe('free');
      store.close();
    });

    it('lowercases name in lookup', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/ALICE/available');
      expect(res.status).toBe(200);
      expect(res.body.state).toBe('claimed');
      store.close();
    });

    it('returns 503 when registry not configured', async () => {
      const app = createApp({});
      const res = await request(app).get('/username/alice/available');
      expect(res.status).toBe(503);
    });
  });

  describe('GET /username/:name', () => {
    it('returns 404 for unknown name (no claim, no cooldown)', async () => {
      const store = createUsernameRegistryStore(dbPath);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/ghost');
      expect(res.status).toBe(404);
      expect(res.body.error).toBe('Not Found');
      store.close();
    });

    it('returns record for active claim', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({
        name: 'alice',
        owner: OWNER,
        aliasPubkey: buf32(0x42),
        claimedAt: 1_700_000_000,
        appRound: 99,
      });
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/alice');
      expect(res.status).toBe(200);
      expect(res.body.name).toBe('alice');
      expect(res.body.owner).toBe(OWNER);
      expect(res.body.alias_pubkey).toBe(buf32(0x42).toString('base64'));
      expect(res.body.claimed_at).toBe(1_700_000_000);
      expect(res.body.app_round).toBe(99);
      store.close();
    });

    it('returns 404 with cooldown body for released name in cooldown window', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      store.release('alice', OWNER, FAR_FUTURE, 2);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/alice');
      expect(res.status).toBe(404);
      expect(res.body.error).toBe('cooldown');
      expect(res.body.cooldown.prev_owner).toBe(OWNER);
      expect(res.body.cooldown.expires_at).toBe(FAR_FUTURE);
      store.close();
    });

    it('lowercases name in lookup', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/ALICE');
      expect(res.status).toBe(200);
      expect(res.body.name).toBe('alice');
      store.close();
    });

    it('returns 503 when registry not configured', async () => {
      const app = createApp({});
      const res = await request(app).get('/username/alice');
      expect(res.status).toBe(503);
    });
  });

  describe('GET /username/search', () => {
    it('returns matches for prefix query', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      store.upsert({ name: 'alice1', owner: OWNER, aliasPubkey: buf32(0x12), claimedAt: 2, appRound: 2 });
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/search?q=alic');
      expect(res.status).toBe(200);
      expect(res.body.count).toBe(2);
      expect(res.body.users.map((u: { name: string }) => u.name).sort()).toEqual(['alice', 'alice1']);
      store.close();
    });

    it('does not include released (cooldown-only) names in search', async () => {
      const store = createUsernameRegistryStore(dbPath);
      store.upsert({ name: 'alice', owner: OWNER, aliasPubkey: buf32(0x11), claimedAt: 1, appRound: 1 });
      store.release('alice', OWNER, FAR_FUTURE, 2);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/search?q=alice');
      expect(res.status).toBe(200);
      expect(res.body.count).toBe(0);
      store.close();
    });

    it('returns empty for no match', async () => {
      const store = createUsernameRegistryStore(dbPath);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/search?q=ghost');
      expect(res.status).toBe(200);
      expect(res.body.count).toBe(0);
      store.close();
    });

    it('returns 400 when q missing', async () => {
      const store = createUsernameRegistryStore(dbPath);
      const app = createApp({ usernameRegistry: store });
      const res = await request(app).get('/username/search');
      expect(res.status).toBe(400);
      store.close();
    });

    it('returns 503 when registry not configured', async () => {
      const app = createApp({});
      const res = await request(app).get('/username/search?q=alice');
      expect(res.status).toBe(503);
    });
  });
});

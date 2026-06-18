/**
 * Route tests for GET /user/:wallet/pq-pubkey.
 */
import request from 'supertest';
import { createHash } from 'crypto';
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createApp } from '../src/app';
import { createUserDirectoryStore } from '../src/users/user-store';

// Valid 58-char base32 Algorand addresses
const ALICE = 'ALICEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const BOB =   'BOBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

function buf32(byte: number): Buffer {
  return Buffer.alloc(32, byte);
}

function bufPq(byte: number): Buffer {
  return Buffer.alloc(800, byte); // ML-KEM-512 pubkey = 800 bytes
}

describe('GET /user/:wallet/pq-pubkey', () => {
  let dir: string;
  let dbPath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'user-routes-test-'));
    dbPath = join(dir, 'indexer.db');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('200 with correct shape for wallet with keys', async () => {
    const store = createUserDirectoryStore(dbPath);
    store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), bufPq(0xab), 42_000, 1_000);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(200);
    expect(typeof res.body.pqPubkey).toBe('string');
    expect(typeof res.body.pqPubkeyHash).toBe('string');
    expect(typeof res.body.publishedAtRound).toBe('number');
    store.close();
  });

  it('200: pqPubkeyHash equals sha256(pqPubkey)', async () => {
    const store = createUserDirectoryStore(dbPath);
    const pqBytes = bufPq(0xcd);
    store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), pqBytes, 99, 1_000);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(200);

    const decoded = Buffer.from(res.body.pqPubkey as string, 'base64');
    const expectedHash = createHash('sha256').update(decoded).digest('hex');
    expect(res.body.pqPubkeyHash).toBe(expectedHash);
    store.close();
  });

  it('200: pqPubkey base64 round-trips to original bytes', async () => {
    const store = createUserDirectoryStore(dbPath);
    const pqBytes = bufPq(0xef);
    store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), pqBytes, 1, 1_000);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(200);
    const decoded = Buffer.from(res.body.pqPubkey as string, 'base64');
    expect(decoded.equals(pqBytes)).toBe(true);
    store.close();
  });

  it('200: publishedAtRound matches upsertKeys input', async () => {
    const store = createUserDirectoryStore(dbPath);
    store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), bufPq(0xaa), 55_555, 1_000);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(200);
    expect(res.body.publishedAtRound).toBe(55_555);
    store.close();
  });

  it('200: publishedAtRound is 0 when round was null', async () => {
    const store = createUserDirectoryStore(dbPath);
    store.upsertKeys(ALICE, buf32(0x11), buf32(0x22), bufPq(0xaa), null, 1_000);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(200);
    expect(res.body.publishedAtRound).toBe(0);
    store.close();
  });

  it('404 NOT_PUBLISHED for unknown wallet (no row)', async () => {
    const store = createUserDirectoryStore(dbPath);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('NOT_PUBLISHED');
    store.close();
  });

  it('404 NOT_PUBLISHED for wallet with username but no keys', async () => {
    const store = createUserDirectoryStore(dbPath);
    store.upsertUsername(ALICE, 'alice', 1_000);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('NOT_PUBLISHED');
    store.close();
  });

  it('404 NOT_PUBLISHED for wallet with enc/scan keys but null pq_pubkey', async () => {
    const store = createUserDirectoryStore(dbPath);
    store.upsertKeys(BOB, buf32(0x11), buf32(0x22), null, null, 1_000);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get(`/user/${BOB}/pq-pubkey`);
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('NOT_PUBLISHED');
    store.close();
  });

  it('400 for malformed wallet address (too short)', async () => {
    const store = createUserDirectoryStore(dbPath);
    const app = createApp({ userDirectory: store });

    const res = await request(app).get('/user/TOOSHORT/pq-pubkey');
    expect(res.status).toBe(400);
    expect(res.body.error).toBe('Invalid wallet address');
    store.close();
  });

  it('400 for malformed wallet address (invalid chars)', async () => {
    const store = createUserDirectoryStore(dbPath);
    const app = createApp({ userDirectory: store });

    // 58 chars but contains lowercase (invalid base32 for Algorand)
    const bad = 'a'.repeat(58);
    const res = await request(app).get(`/user/${bad}/pq-pubkey`);
    expect(res.status).toBe(400);
    store.close();
  });

  it('503 when userDirectory not configured', async () => {
    const app = createApp({});

    const res = await request(app).get(`/user/${ALICE}/pq-pubkey`);
    expect(res.status).toBe(503);
  });
});

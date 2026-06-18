/**
 * Grammar tests for the live /username/:name/available route
 * (createUsernameRoutes + UserDirectoryStore).
 *
 * Leading digit is VALID (matches contract validateNameFormat after the
 * 2026-06-12 relax); leading/trailing underscore and bad length are not.
 */
import request from 'supertest';
import { mkdtempSync, rmSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import { createApp } from '../src/app';
import { createUserDirectoryStore, type UserDirectoryStore } from '../src/users/user-store';

describe('/username/:name/available grammar', () => {
  let dir: string;
  let store: UserDirectoryStore;
  let app: ReturnType<typeof createApp>;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'username-grammar-test-'));
    store = createUserDirectoryStore(join(dir, 'indexer.db'));
    app = createApp({ userDirectory: store });
  });

  afterEach(() => {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it.each(['alice', '1abc', '123', '9to5', 'a_b_c', '1_2_3'])(
    'accepts %s',
    async (name) => {
      const res = await request(app).get(`/username/${name}/available`);
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ available: true });
    },
  );

  it.each(['_abc', 'abc_', 'ab', 'a'.repeat(21), 'has-dash', 'has.dot'])(
    'rejects %s with 400',
    async (name) => {
      const res = await request(app).get(`/username/${name}/available`);
      expect(res.status).toBe(400);
    },
  );

  it('reports taken digit-first name as unavailable', async () => {
    store.upsertUsername('OWNERPUBKEY', '1337user', 1);
    const res = await request(app).get('/username/1337user/available');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ available: false });
  });
});

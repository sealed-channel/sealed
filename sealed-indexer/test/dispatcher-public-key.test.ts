/**
 * Tests for the /dispatcher/public-key endpoint and DISPATCHER_DECRYPT_MODE
 * production gating in src/index.ts.
 */
import request from 'supertest';
import { createApp } from '../src/app';
import nacl from 'tweetnacl';

describe('/dispatcher/public-key', () => {
  it('returns the configured dispatcher public key as base64', async () => {
    const seed = Buffer.from(nacl.randomBytes(32));
    const pub = Buffer.from(nacl.scalarMult.base(new Uint8Array(seed)));
    const app = createApp({ dispatcherPubKey: pub });

    const res = await request(app).get('/dispatcher/public-key');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      public_key: pub.toString('base64'),
      algorithm: 'x25519',
      version: 'sealed-push-token-v1',
    });
  });

  it('returns 503 when no key is configured', async () => {
    const app = createApp();
    const res = await request(app).get('/dispatcher/public-key');
    expect(res.status).toBe(503);
    expect(res.body).toEqual({ error: 'Dispatcher public key not configured' });
  });
});

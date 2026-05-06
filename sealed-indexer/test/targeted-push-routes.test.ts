/**
 * Tests for /push/register-targeted and /push/unregister-targeted.
 *
 * Push Notifications is the opt-in mode: the server holds view_priv and
 * trial-decrypts every chain event to find the user's messages, dispatching
 * one visible-alert push per match. Because the server is now holding
 * sensitive key material, the route enforces two cryptographic proofs that
 * the blinded routes do not need:
 *
 *   1. derivePublicKey(view_priv) === view_pub
 *      → client cannot lie about its keypair.
 *   2. HMAC(view_priv, "push-v1") === blinded_id
 *      → client's blinded_id is consistent with the disclosed view_priv,
 *        preventing cross-user blinded_id substitution.
 *
 * Audit logging contract: only blinded_id + platform may be logged.
 * view_priv / view_pub / enc_token MUST never appear in logs.
 */
import request from 'supertest';
import { createHmac, generateKeyPairSync } from 'crypto';
import nacl from 'tweetnacl';
import { createApp } from '../src/app';
import { createTargetedPushTokenStore } from '../src/push/targeted-store';

function deriveViewPub(viewPriv: Buffer): Buffer {
  return Buffer.from(nacl.scalarMult.base(new Uint8Array(viewPriv)));
}

function blindedIdFor(viewPriv: Buffer): string {
  return createHmac('sha256', viewPriv).update('push-v1').digest('hex');
}

function makeKeypair() {
  // Random 32-byte X25519 seed.
  const viewPriv = Buffer.from(
    nacl.randomBytes(32),
  );
  const viewPub = deriveViewPub(viewPriv);
  return {
    viewPriv,
    viewPub,
    viewPrivHex: viewPriv.toString('hex'),
    viewPubHex: viewPub.toString('hex'),
    blindedId: blindedIdFor(viewPriv),
  };
}

describe('Push Notifications registry — store layer (cryptographic invariants)', () => {
  let store: ReturnType<typeof createTargetedPushTokenStore>;

  beforeEach(() => {
    store = createTargetedPushTokenStore(':memory:');
  });

  afterEach(() => {
    store.close();
  });

  it('upserts a registration and round-trips view_priv/view_pub bytes', () => {
    const kp = makeKeypair();
    store.register({
      blindedId: kp.blindedId,
      encToken: 'ZGV2aWNlLXRva2Vu',
      platform: 'ios',
      viewPriv: kp.viewPriv,
      viewPub: kp.viewPub,
    });

    const row = store.get(kp.blindedId);
    expect(row).not.toBeNull();
    expect(row!.viewPriv.equals(kp.viewPriv)).toBe(true);
    expect(row!.viewPub.equals(kp.viewPub)).toBe(true);
    expect(row!.encToken).toBe('ZGV2aWNlLXRva2Vu');
    expect(row!.platform).toBe('ios');
  });

  it('unregister removes the row entirely', () => {
    const kp = makeKeypair();
    store.register({
      blindedId: kp.blindedId,
      encToken: 'AA==',
      platform: 'android',
      viewPriv: kp.viewPriv,
      viewPub: kp.viewPub,
    });
    store.unregister(kp.blindedId);
    expect(store.get(kp.blindedId)).toBeNull();
  });
});

describe('HTTP /push/register-targeted', () => {
  function makeReq(overrides: Partial<{
    blinded_id: string;
    enc_token: string;
    platform: 'ios' | 'android';
    view_priv: string;
    view_pub: string;
  }> = {}) {
    const kp = makeKeypair();
    return {
      blinded_id: kp.blindedId,
      enc_token: 'ZGV2aWNlLXRva2Vu',
      platform: 'ios' as const,
      view_priv: kp.viewPrivHex,
      view_pub: kp.viewPubHex,
      ...overrides,
    };
  }

  it('accepts a well-formed targeted registration', async () => {
    const app = createApp();
    const res = await request(app).post('/push/register-targeted').send(makeReq());
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it('rejects when derivePublicKey(view_priv) !== view_pub', async () => {
    const app = createApp();
    const kpA = makeKeypair();
    const kpB = makeKeypair();
    const res = await request(app).post('/push/register-targeted').send({
      blinded_id: kpA.blindedId,
      enc_token: 'AA==',
      platform: 'ios',
      view_priv: kpA.viewPrivHex,
      view_pub: kpB.viewPubHex, // mismatched
    });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/view_pub|keypair/i);
  });

  it('rejects when HMAC(view_priv, "push-v1") !== blinded_id', async () => {
    const app = createApp();
    const kp = makeKeypair();
    const wrongBlinded = 'a'.repeat(64);
    const res = await request(app).post('/push/register-targeted').send({
      blinded_id: wrongBlinded,
      enc_token: 'AA==',
      platform: 'ios',
      view_priv: kp.viewPrivHex,
      view_pub: kp.viewPubHex,
    });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/blinded_id/i);
  });

  it('rejects malformed blinded_id', async () => {
    const app = createApp();
    const kp = makeKeypair();
    const res = await request(app).post('/push/register-targeted').send({
      blinded_id: 'not-hex',
      enc_token: 'AA==',
      platform: 'ios',
      view_priv: kp.viewPrivHex,
      view_pub: kp.viewPubHex,
    });
    expect(res.status).toBe(400);
  });

  it('rejects unknown platform', async () => {
    const app = createApp();
    const res = await request(app).post('/push/register-targeted').send(
      makeReq({ platform: 'web' as never }),
    );
    expect(res.status).toBe(400);
  });

  it('rejects missing fields', async () => {
    const app = createApp();
    const kp = makeKeypair();
    const res = await request(app).post('/push/register-targeted').send({
      blinded_id: kp.blindedId,
      platform: 'ios',
      view_priv: kp.viewPrivHex,
      // missing view_pub & enc_token
    });
    expect(res.status).toBe(400);
  });

  it('rejects empty enc_token', async () => {
    const app = createApp();
    const res = await request(app).post('/push/register-targeted').send(
      makeReq({ enc_token: '' }),
    );
    expect(res.status).toBe(400);
  });
});

describe('HTTP /push/unregister-targeted', () => {
  it('accepts a valid unregister', async () => {
    const app = createApp();
    const res = await request(app).post('/push/unregister-targeted').send({
      blinded_id: 'd'.repeat(64),
    });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it('rejects malformed blinded_id', async () => {
    const app = createApp();
    const res = await request(app).post('/push/unregister-targeted').send({
      blinded_id: 'short',
    });
    expect(res.status).toBe(400);
  });
});

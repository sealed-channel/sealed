import { createHash } from 'node:crypto';
import request from 'supertest';
import pino from 'pino';
import {
  createPreimageApp,
  createPreimageLogger,
  parseSidecarEnv,
} from '../../src/preimage-server/index';
import { createPreimageStore, type PreimageStore } from '../../src/preimage-server/db';

describe('preimage-server HTTP scaffold', () => {
  let store: PreimageStore;

  beforeEach(() => {
    store = createPreimageStore(':memory:');
  });

  afterEach(() => {
    store.close();
  });

  describe('/health', () => {
    test('returns 200 with status ok and a null lastWatcherRound on a fresh DB', async () => {
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get('/health');
      expect(res.status).toBe(200);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(res.body).toEqual({ status: 'ok', lastWatcherRound: null });
    });

    test('returns the current watcher checkpoint as a string (bigint-safe)', async () => {
      const big = BigInt(Number.MAX_SAFE_INTEGER) + 99n;
      store.setWatcherCheckpoint(big);
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get('/health');
      expect(res.status).toBe(200);
      expect(res.body.lastWatcherRound).toBe(big.toString());
    });
  });

  describe('unknown routes', () => {
    test('404 + Cache-Control: no-store + plain body (no echo of input)', async () => {
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get('/does-not-exist');
      expect(res.status).toBe(404);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(res.text).toBe('not found');
    });

    test('does not leak deliveryPubkey-shaped paths into the response body', async () => {
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const fakeHex = 'a'.repeat(64);
      const res = await request(app).get(`/delivery/${fakeHex}`);
      expect(res.status).toBe(404);
      expect(res.text).toBe('not found');
      expect(res.text.includes(fakeHex)).toBe(false);
    });
  });

  describe('security headers (helmet)', () => {
    test('sets sensible defaults and strips X-Powered-By', async () => {
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get('/health');
      expect(res.headers['x-powered-by']).toBeUndefined();
      expect(res.headers['x-content-type-options']).toBe('nosniff');
    });
  });

  describe('GET /delivery/:hex', () => {
    const COMMITMENT_HASH = new Uint8Array(32).fill(0xaa);
    const PREIMAGE = new Uint8Array(16).fill(0x55);
    const CODE = '0123456789ABCDEF';
    const DELIVERY_PUBKEY = new Uint8Array(32).fill(0xbb);
    const CIPHERTEXT = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);

    function sha256(b: Uint8Array): Uint8Array {
      return new Uint8Array(createHash('sha256').update(b).digest());
    }
    function toHex(b: Uint8Array): string {
      return Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');
    }

    function seedSoldRow(): { deliveryKeyHex: string } {
      store.insertAvailable(COMMITMENT_HASH, PREIMAGE, CODE);
      const deliveryKeySha256 = sha256(DELIVERY_PUBKEY);
      store.markSold({
        commitmentHash: COMMITMENT_HASH,
        soldAtRound: 5000n,
        deliveryKeySha256,
        ciphertext: CIPHERTEXT,
      });
      return { deliveryKeyHex: toHex(deliveryKeySha256) };
    }

    test('404 + no-store + plain body for an unknown delivery key', async () => {
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get(`/delivery/${'a'.repeat(64)}`);
      expect(res.status).toBe(404);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(res.text).toBe('not found');
    });

    test('404 when the hex param is malformed (length, charset)', async () => {
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      for (const bad of [
        'short',
        'a'.repeat(63),
        'a'.repeat(65),
        'zz' + 'a'.repeat(62), // illegal hex char
        '%' + 'a'.repeat(63),
      ]) {
        const res = await request(app).get(`/delivery/${encodeURIComponent(bad)}`);
        expect(res.status).toBe(404);
        expect(res.text).toBe('not found');
      }
    });

    test('serves the ciphertext bytes verbatim for a sold delivery key', async () => {
      const { deliveryKeyHex } = seedSoldRow();
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get(`/delivery/${deliveryKeyHex}`);
      expect(res.status).toBe(200);
      expect(res.headers['content-type']).toMatch(/^application\/octet-stream/);
      expect(res.headers['cache-control']).toBe('no-store');
      expect(Buffer.from(res.body).equals(Buffer.from(CIPHERTEXT))).toBe(true);
    });

    test('uppercase hex is accepted and normalised', async () => {
      const { deliveryKeyHex } = seedSoldRow();
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get(`/delivery/${deliveryKeyHex.toUpperCase()}`);
      expect(res.status).toBe(200);
      expect(Buffer.from(res.body).equals(Buffer.from(CIPHERTEXT))).toBe(true);
    });

    test('first fetch transitions the row to delivered (preimage + code cleared)', async () => {
      const { deliveryKeyHex } = seedSoldRow();
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      await request(app).get(`/delivery/${deliveryKeyHex}`);
      // markDelivered runs after res.send(); await a microtask to let it settle.
      await new Promise((r) => setImmediate(r));
      const row = store.getByCommitment(COMMITMENT_HASH)!;
      expect(row.status).toBe('delivered');
      expect(row.preimage).toBeNull();
      expect(row.code).toBeNull();
      expect(Buffer.from(row.ciphertext!).equals(Buffer.from(CIPHERTEXT))).toBe(true);
    });

    test('re-fetch is idempotent: same ciphertext, no error', async () => {
      const { deliveryKeyHex } = seedSoldRow();
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const first = await request(app).get(`/delivery/${deliveryKeyHex}`);
      await new Promise((r) => setImmediate(r));
      const second = await request(app).get(`/delivery/${deliveryKeyHex}`);
      expect(first.status).toBe(200);
      expect(second.status).toBe(200);
      expect(Buffer.from(first.body).equals(Buffer.from(second.body))).toBe(true);
      expect(Buffer.from(second.body).equals(Buffer.from(CIPHERTEXT))).toBe(true);
    });

    test('available (unsold) rows are not exposed via delivery endpoint', async () => {
      // Insert but do not mark sold.
      store.insertAvailable(COMMITMENT_HASH, PREIMAGE, CODE);
      const deliveryKeyHex = toHex(sha256(DELIVERY_PUBKEY));
      const app = createPreimageApp({ store, logger: pino({ level: 'silent' }) });
      const res = await request(app).get(`/delivery/${deliveryKeyHex}`);
      expect(res.status).toBe(404);
    });
  });

  describe('parseSidecarEnv', () => {
    const MIN_VALID: NodeJS.ProcessEnv = {
      ALGOD_URL: 'https://testnet-api.algonode.cloud',
      SEALED_APP_ID: '763452863',
    };

    test('accepts the minimum required env and applies sensible defaults', () => {
      const cfg = parseSidecarEnv({ ...MIN_VALID });
      expect(cfg.algodUrl).toBe('https://testnet-api.algonode.cloud');
      expect(cfg.appId).toBe(763452863n);
      expect(cfg.algodToken).toBeUndefined();
      expect(cfg.startRound).toBeUndefined();
      expect(cfg.pollIntervalMs).toBeUndefined();
      expect(cfg.port).toBe(4100);
      expect(cfg.dbPath).toBe('./preimage-server.sqlite');
    });

    test('overrides each optional value when set', () => {
      const cfg = parseSidecarEnv({
        ...MIN_VALID,
        ALGOD_TOKEN: 'tok',
        ALGORAND_START_ROUND: '63622000',
        PREIMAGE_DB_PATH: '/data/preimage.sqlite',
        PREIMAGE_PORT: '5500',
        PREIMAGE_POLL_INTERVAL_MS: '2000',
      });
      expect(cfg.algodToken).toBe('tok');
      expect(cfg.startRound).toBe(63622000n);
      expect(cfg.dbPath).toBe('/data/preimage.sqlite');
      expect(cfg.port).toBe(5500);
      expect(cfg.pollIntervalMs).toBe(2000);
    });

    test('throws when ALGOD_URL is missing', () => {
      expect(() => parseSidecarEnv({ SEALED_APP_ID: '1' })).toThrow(/ALGOD_URL/);
    });

    test('throws when SEALED_APP_ID is missing or invalid', () => {
      expect(() => parseSidecarEnv({ ALGOD_URL: 'x' })).toThrow(/SEALED_APP_ID not set/);
      expect(() => parseSidecarEnv({ ...MIN_VALID, SEALED_APP_ID: 'not-a-number' })).toThrow(
        /not a valid bigint/,
      );
      expect(() => parseSidecarEnv({ ...MIN_VALID, SEALED_APP_ID: '0' })).toThrow(
        /must be positive/,
      );
    });

    test('throws on malformed PREIMAGE_PORT', () => {
      expect(() => parseSidecarEnv({ ...MIN_VALID, PREIMAGE_PORT: '0' })).toThrow(/PREIMAGE_PORT/);
      expect(() => parseSidecarEnv({ ...MIN_VALID, PREIMAGE_PORT: '70000' })).toThrow(
        /PREIMAGE_PORT/,
      );
      expect(() => parseSidecarEnv({ ...MIN_VALID, PREIMAGE_PORT: 'abc' })).toThrow(
        /PREIMAGE_PORT/,
      );
    });

    test('throws on malformed ALGORAND_START_ROUND or PREIMAGE_POLL_INTERVAL_MS', () => {
      expect(() =>
        parseSidecarEnv({ ...MIN_VALID, ALGORAND_START_ROUND: 'not-a-number' }),
      ).toThrow(/ALGORAND_START_ROUND/);
      expect(() => parseSidecarEnv({ ...MIN_VALID, ALGORAND_START_ROUND: '-1' })).toThrow(
        /non-negative/,
      );
      expect(() => parseSidecarEnv({ ...MIN_VALID, PREIMAGE_POLL_INTERVAL_MS: '0' })).toThrow(
        /PREIMAGE_POLL_INTERVAL_MS/,
      );
      expect(() => parseSidecarEnv({ ...MIN_VALID, PREIMAGE_POLL_INTERVAL_MS: 'soon' })).toThrow(
        /PREIMAGE_POLL_INTERVAL_MS/,
      );
    });

    test('empty ALGOD_TOKEN is treated as undefined (no auth)', () => {
      const cfg = parseSidecarEnv({ ...MIN_VALID, ALGOD_TOKEN: '' });
      expect(cfg.algodToken).toBeUndefined();
    });
  });

  describe('logger redaction', () => {
    test('masks secret-bearing field names', () => {
      const writes: string[] = [];
      const stream = { write: (s: string): void => { writes.push(s); } };
      const log = pino({ level: 'info', redact: { paths: [
        '*.preimage', '*.ciphertext', '*.deliveryPubkey', '*.delivery_key_sha256',
        'preimage', 'ciphertext', 'deliveryPubkey', 'delivery_key_sha256',
      ], censor: '[REDACTED]' } }, stream);

      log.info({
        ok: true,
        preimage: 'should-not-appear',
        ciphertext: 'definitely-not-this',
        deliveryPubkey: 'nope',
        delivery_key_sha256: 'never',
        nested: { preimage: 'also-masked', ciphertext: 'masked', deliveryPubkey: 'masked' },
      }, 'sample');

      const joined = writes.join('');
      expect(joined).toContain('[REDACTED]');
      expect(joined).not.toContain('should-not-appear');
      expect(joined).not.toContain('definitely-not-this');
      expect(joined).not.toContain('nope');
      expect(joined).not.toContain('never');
      expect(joined).not.toContain('also-masked');
    });

    test('createPreimageLogger returns a pino instance', () => {
      const log = createPreimageLogger('silent');
      expect(typeof log.info).toBe('function');
      expect(typeof log.error).toBe('function');
    });
  });
});

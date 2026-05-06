import { createTargetedPushTokenStore } from '../src/push/targeted-store';
import nacl from 'tweetnacl';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

function tmpDb(): string {
  return path.join(os.tmpdir(), `targeted-store-${Date.now()}-${Math.random()}.db`);
}

function genKeypair(): { priv: Buffer; pub: Buffer } {
  const seed = Buffer.from(nacl.randomBytes(32));
  const pub = Buffer.from(nacl.scalarMult.base(new Uint8Array(seed)));
  return { priv: seed, pub };
}

const HEX_BLINDED = 'a'.repeat(64);

describe('TargetedPushTokenStore', () => {
  let dbPath: string;
  beforeEach(() => {
    dbPath = tmpDb();
  });
  afterEach(() => {
    try {
      fs.unlinkSync(dbPath);
    } catch {}
  });

  it('round-trips a registration', () => {
    const store = createTargetedPushTokenStore(dbPath);
    const kp = genKeypair();
    store.register({
      blindedId: HEX_BLINDED,
      encToken: 'enc-blob-base64',
      platform: 'ios',
      viewPriv: kp.priv,
      viewPub: kp.pub,
    });
    const got = store.get(HEX_BLINDED);
    expect(got?.blindedId).toBe(HEX_BLINDED);
    expect(got?.platform).toBe('ios');
    expect(got?.encToken).toBe('enc-blob-base64');
    expect(got?.viewPriv.equals(kp.priv)).toBe(true);
    expect(got?.viewPub.equals(kp.pub)).toBe(true);
    store.close();
  });

  it('upsert preserves createdAt but updates everything else', async () => {
    const store = createTargetedPushTokenStore(dbPath);
    const kp1 = genKeypair();
    store.register({
      blindedId: HEX_BLINDED,
      encToken: 'first',
      platform: 'ios',
      viewPriv: kp1.priv,
      viewPub: kp1.pub,
    });
    const first = store.get(HEX_BLINDED)!;

    await new Promise((r) => setTimeout(r, 5));
    const kp2 = genKeypair();
    store.register({
      blindedId: HEX_BLINDED,
      encToken: 'second',
      platform: 'android',
      viewPriv: kp2.priv,
      viewPub: kp2.pub,
    });
    const second = store.get(HEX_BLINDED)!;
    expect(second.createdAt).toBe(first.createdAt);
    expect(second.updatedAt).toBeGreaterThan(first.updatedAt);
    expect(second.encToken).toBe('second');
    expect(second.platform).toBe('android');
    expect(second.viewPriv.equals(kp2.priv)).toBe(true);
    store.close();
  });

  it('rejects invalid blinded_id', () => {
    const store = createTargetedPushTokenStore(dbPath);
    const kp = genKeypair();
    expect(() =>
      store.register({
        blindedId: 'not-hex',
        encToken: 'x',
        platform: 'ios',
        viewPriv: kp.priv,
        viewPub: kp.pub,
      }),
    ).toThrow();
    store.close();
  });

  it('rejects wrong-length viewPriv / viewPub', () => {
    const store = createTargetedPushTokenStore(dbPath);
    expect(() =>
      store.register({
        blindedId: HEX_BLINDED,
        encToken: 'x',
        platform: 'ios',
        viewPriv: Buffer.alloc(31),
        viewPub: Buffer.alloc(32),
      }),
    ).toThrow(/view_priv/);
    expect(() =>
      store.register({
        blindedId: HEX_BLINDED,
        encToken: 'x',
        platform: 'ios',
        viewPriv: Buffer.alloc(32),
        viewPub: Buffer.alloc(31),
      }),
    ).toThrow(/view_pub/);
    store.close();
  });

  it('listAll returns every registration', () => {
    const store = createTargetedPushTokenStore(dbPath);
    const a = genKeypair();
    const b = genKeypair();
    store.register({
      blindedId: 'a'.repeat(64),
      encToken: 'tA',
      platform: 'ios',
      viewPriv: a.priv,
      viewPub: a.pub,
    });
    store.register({
      blindedId: 'b'.repeat(64),
      encToken: 'tB',
      platform: 'android',
      viewPriv: b.priv,
      viewPub: b.pub,
    });
    const all = store.listAll();
    expect(all).toHaveLength(2);
    const platforms = all.map((r) => r.platform).sort();
    expect(platforms).toEqual(['android', 'ios']);
    store.close();
  });

  it('unregister removes the row', () => {
    const store = createTargetedPushTokenStore(dbPath);
    const kp = genKeypair();
    store.register({
      blindedId: HEX_BLINDED,
      encToken: 'x',
      platform: 'ios',
      viewPriv: kp.priv,
      viewPub: kp.pub,
    });
    store.unregister(HEX_BLINDED);
    expect(store.get(HEX_BLINDED)).toBeNull();
    store.close();
  });
});

/**
 * Unit tests for the on-chain set_username watcher.
 *
 * Strategy mirrors algorand-watcher.test.ts: inject a fake `SubscriberLike`
 * via `subscriberFactory` and drive the on-chain handler deterministically
 * without hitting algod.
 */

import { decodeSetUsername, type SubscribedTxn } from '../src/users/user-watcher';

const SET_USERNAME_SELECTOR = Buffer.from([0xd2, 0xfc, 0xc8, 0x3f]);

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

function abiBytes(payload: Buffer): Uint8Array {
  const out = Buffer.alloc(2 + payload.length);
  out.writeUInt16BE(payload.length, 0);
  payload.copy(out, 2);
  return new Uint8Array(out);
}

function makeSetUsernameTxn(opts: {
  username?: string;
  encryptionPubkey?: Buffer;
  scanPubkey?: Buffer;
  sender?: string;
  selector?: Buffer;
  argCount?: number;
}): SubscribedTxn {
  const usernameBytes = Buffer.from(opts.username ?? 'alice', 'utf8');
  const enc = opts.encryptionPubkey ?? Buffer.alloc(32, 0xaa);
  const scan = opts.scanPubkey ?? Buffer.alloc(32, 0xbb);
  const allArgs: Uint8Array[] = [
    new Uint8Array(opts.selector ?? SET_USERNAME_SELECTOR),
    abiBytes(usernameBytes),
    new Uint8Array(enc),
    new Uint8Array(scan),
  ];
  const desired = opts.argCount ?? 4;
  let finalArgs: Uint8Array[];
  if (desired <= 4) {
    finalArgs = allArgs.slice(0, desired);
  } else {
    finalArgs = [...allArgs];
    while (finalArgs.length < desired) {
      finalArgs.push(new Uint8Array(0));
    }
  }
  return {
    id: 'TXSETUSER',
    sender: opts.sender ?? 'ALICEWALLET',
    confirmedRound: 100n,
    roundTime: 1_700_000_000,
    applicationTransaction: {
      applicationId: 759_175_203n,
      applicationArgs: finalArgs,
    },
  };
}

describe('decodeSetUsername', () => {
  it('decodes a well-formed set_username txn', () => {
    const decoded = decodeSetUsername(
      makeSetUsernameTxn({ username: 'alice' }),
      silentLogger(),
    );
    expect(decoded).not.toBeNull();
    expect(decoded!.username).toBe('alice');
    expect(decoded!.ownerPubkey).toBe('ALICEWALLET');
    expect(decoded!.encryptionPubkey.equals(Buffer.alloc(32, 0xaa))).toBe(true);
    expect(decoded!.scanPubkey.equals(Buffer.alloc(32, 0xbb))).toBe(true);
    // observedAt = roundTime * 1000
    expect(decoded!.observedAt).toBe(1_700_000_000_000);
  });

  it('returns null for wrong selector', () => {
    const decoded = decodeSetUsername(
      makeSetUsernameTxn({ selector: Buffer.from([0xde, 0xad, 0xbe, 0xef]) }),
      silentLogger(),
    );
    expect(decoded).toBeNull();
  });

  it('returns null for wrong arg count', () => {
    expect(
      decodeSetUsername(makeSetUsernameTxn({ argCount: 3 }), silentLogger()),
    ).toBeNull();
    expect(
      decodeSetUsername(makeSetUsernameTxn({ argCount: 5 }), silentLogger()),
    ).toBeNull();
  });

  it('returns null for wrong-length pubkeys', () => {
    expect(
      decodeSetUsername(
        makeSetUsernameTxn({ encryptionPubkey: Buffer.alloc(31, 0xaa) }),
        silentLogger(),
      ),
    ).toBeNull();
    expect(
      decodeSetUsername(
        makeSetUsernameTxn({ scanPubkey: Buffer.alloc(33, 0xbb) }),
        silentLogger(),
      ),
    ).toBeNull();
  });

  it('returns null when sender is missing', () => {
    const txn = makeSetUsernameTxn({});
    txn.sender = undefined;
    expect(decodeSetUsername(txn, silentLogger())).toBeNull();
  });

  it('returns null for empty username', () => {
    const txn = makeSetUsernameTxn({});
    // Replace username arg with abiBytes of empty payload.
    txn.applicationTransaction!.applicationArgs = [
      new Uint8Array(SET_USERNAME_SELECTOR),
      abiBytes(Buffer.alloc(0)),
      new Uint8Array(Buffer.alloc(32, 0xaa)),
      new Uint8Array(Buffer.alloc(32, 0xbb)),
    ];
    expect(decodeSetUsername(txn, silentLogger())).toBeNull();
  });

  it('returns null for non-utf8 username bytes', () => {
    const txn = makeSetUsernameTxn({});
    // 0xff 0xfe is invalid as a UTF-8 lead.
    const bad = Buffer.from([0xff, 0xfe, 0xfd]);
    txn.applicationTransaction!.applicationArgs = [
      new Uint8Array(SET_USERNAME_SELECTOR),
      abiBytes(bad),
      new Uint8Array(Buffer.alloc(32, 0xaa)),
      new Uint8Array(Buffer.alloc(32, 0xbb)),
    ];
    expect(decodeSetUsername(txn, silentLogger())).toBeNull();
  });

  it('falls back to Date.now when roundTime is missing', () => {
    const txn = makeSetUsernameTxn({});
    txn.roundTime = undefined;
    const before = Date.now();
    const decoded = decodeSetUsername(txn, silentLogger())!;
    const after = Date.now();
    expect(decoded.observedAt).toBeGreaterThanOrEqual(before);
    expect(decoded.observedAt).toBeLessThanOrEqual(after);
  });
});

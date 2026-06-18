/**
 * Tests for src/chain/decode-abi-call.ts.
 *
 * Domain decoders (decodeClaimUsername, decodeSetUsername) keep their
 * own integration tests in test/username-watcher.test.ts and
 * test/user-watcher.test.ts; this file covers the schema layer itself
 * (selector match, dynBytes header parsing, length gates, sender-log
 * verification).
 */

import algosdk from 'algosdk';
import {
  decodeAbiCall,
  type AbiCallSchema,
  type SubscribedTxn,
} from '../src/chain/decode-abi-call';

const SELECTOR_OK = Buffer.from([0xaa, 0xbb, 0xcc, 0xdd]);
const SELECTOR_BAD = Buffer.from([0x00, 0x00, 0x00, 0x00]);
// Real Algorand addresses derived from raw 32-byte public keys.
const SENDER = algosdk.encodeAddress(new Uint8Array(32).fill(0x01));
const OTHER_SENDER = algosdk.encodeAddress(new Uint8Array(32).fill(0x02));

function silentLogger() {
  const fn = jest.fn();
  const log = {
    info: fn, debug: fn, warn: fn, error: fn, fatal: fn, trace: fn,
    child: () => log,
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return log as any;
}

function abiDynBytes(payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + payload.length);
  out[0] = (payload.length >> 8) & 0xff;
  out[1] = payload.length & 0xff;
  out.set(payload, 2);
  return out;
}

function makeTxn(args: Uint8Array[], overrides: Partial<SubscribedTxn> = {}): SubscribedTxn {
  return {
    id: 'TX1',
    sender: SENDER,
    confirmedRound: 42n,
    roundTime: 1_700_000_000,
    applicationTransaction: { applicationArgs: args },
    ...overrides,
  };
}

const TWO_DYN_BYTES_SCHEMA = {
  selector: SELECTOR_OK,
  args: {
    name: { kind: 'dynBytes', minLen: 1, maxLen: 20 },
    blob: { kind: 'dynBytes', minLen: 32, maxLen: 32 },
  },
} satisfies AbiCallSchema<{
  name: { kind: 'dynBytes'; minLen: number; maxLen: number };
  blob: { kind: 'dynBytes'; minLen: number; maxLen: number };
}>;

const FIXED_BYTES_SCHEMA = {
  selector: SELECTOR_OK,
  args: {
    a: { kind: 'fixedBytes', len: 32 },
    b: { kind: 'fixedBytes', len: 32 },
  },
} satisfies AbiCallSchema<{
  a: { kind: 'fixedBytes'; len: number };
  b: { kind: 'fixedBytes'; len: number };
}>;

describe('decodeAbiCall — selector + arg-count gates', () => {
  it('decodes a well-formed call with named args', () => {
    const name = new TextEncoder().encode('alice');
    const blob = new Uint8Array(32).fill(0x42);
    const decoded = decodeAbiCall(
      makeTxn([SELECTOR_OK, abiDynBytes(name), abiDynBytes(blob)]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(decoded).not.toBeNull();
    expect(Buffer.from(decoded!.args.name).toString()).toBe('alice');
    expect(Buffer.from(decoded!.args.blob).equals(Buffer.from(blob))).toBe(true);
    expect(decoded!.sender).toBe(SENDER);
    expect(decoded!.confirmedRound).toBe(42n);
    expect(decoded!.roundTime).toBe(1_700_000_000);
  });

  it('returns null on selector mismatch', () => {
    const result = decodeAbiCall(
      makeTxn([SELECTOR_BAD, abiDynBytes(new Uint8Array([0x61])), abiDynBytes(new Uint8Array(32))]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  it('returns null on too few args', () => {
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, abiDynBytes(new Uint8Array([0x61]))]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  it('returns null on too many args', () => {
    const result = decodeAbiCall(
      makeTxn([
        SELECTOR_OK,
        abiDynBytes(new Uint8Array([0x61])),
        abiDynBytes(new Uint8Array(32)),
        new Uint8Array(0),
      ]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  it('returns null when applicationArgs is missing', () => {
    const result = decodeAbiCall(
      { id: 'X', sender: SENDER, applicationTransaction: {} },
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });
});

describe('decodeAbiCall — dynBytes parsing', () => {
  it('rejects dynBytes whose declared length disagrees with payload', () => {
    // Header says length 5 but payload is 4 bytes.
    const broken = new Uint8Array([0x00, 0x05, 0x61, 0x62, 0x63, 0x64]);
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, broken, abiDynBytes(new Uint8Array(32))]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  it('rejects dynBytes shorter than the 2-byte header', () => {
    const tooShort = new Uint8Array([0x00]);
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, tooShort, abiDynBytes(new Uint8Array(32))]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  it('enforces minLen', () => {
    // empty payload — header [0x00, 0x00] then nothing; minLen is 1.
    const empty = new Uint8Array([0x00, 0x00]);
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, empty, abiDynBytes(new Uint8Array(32))]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  it('enforces maxLen', () => {
    const tooLong = new TextEncoder().encode('a'.repeat(21)); // schema maxLen = 20
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, abiDynBytes(tooLong), abiDynBytes(new Uint8Array(32))]),
      TWO_DYN_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });
});

describe('decodeAbiCall — fixedBytes parsing', () => {
  it('decodes raw 32-byte args without ABI header', () => {
    const a = new Uint8Array(32).fill(0x11);
    const b = new Uint8Array(32).fill(0x22);
    const decoded = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b]),
      FIXED_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(decoded).not.toBeNull();
    expect(Buffer.from(decoded!.args.a).equals(Buffer.from(a))).toBe(true);
    expect(Buffer.from(decoded!.args.b).equals(Buffer.from(b))).toBe(true);
  });

  it('rejects fixedBytes of wrong length', () => {
    const a = new Uint8Array(31).fill(0x11);
    const b = new Uint8Array(32).fill(0x22);
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b]),
      FIXED_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });
});

describe('decodeAbiCall — sender + sender-log verification', () => {
  const a = new Uint8Array(32).fill(0xaa);
  const b = new Uint8Array(32).fill(0xbb);

  it('returns null when sender is missing', () => {
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b], { sender: undefined }),
      FIXED_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  function senderToLogBytes(addr: string): Uint8Array {
    return algosdk.decodeAddress(addr).publicKey;
  }

  it('passes sender-log check when logs[0] matches txn.sender', () => {
    const logBytes = senderToLogBytes(SENDER);
    const decoded = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b], { logs: [logBytes] }),
      { ...FIXED_BYTES_SCHEMA, requireSenderLog: true },
      silentLogger(),
    );
    expect(decoded).not.toBeNull();
  });

  it('drops txn when logs[0] disagrees with txn.sender', () => {
    const logBytes = senderToLogBytes(OTHER_SENDER);
    const result = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b], { logs: [logBytes] }),
      { ...FIXED_BYTES_SCHEMA, requireSenderLog: true },
      silentLogger(),
    );
    expect(result).toBeNull();
  });

  it('falls back to txn.sender when logs are absent (legacy contract)', () => {
    const decoded = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b], { logs: [] }),
      { ...FIXED_BYTES_SCHEMA, requireSenderLog: true },
      silentLogger(),
    );
    expect(decoded).not.toBeNull();
    expect(decoded!.sender).toBe(SENDER);
  });

  it('ignores log[0] when its length is not 32 bytes', () => {
    const decoded = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b], { logs: [new Uint8Array([1, 2, 3])] }),
      { ...FIXED_BYTES_SCHEMA, requireSenderLog: true },
      silentLogger(),
    );
    expect(decoded).not.toBeNull();
  });
});

describe('decodeAbiCall — passthrough fields', () => {
  it('passes confirmedRound + roundTime through unchanged', () => {
    const a = new Uint8Array(32);
    const b = new Uint8Array(32);
    const decoded = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b], { confirmedRound: 999n, roundTime: 1_750_000_000 }),
      FIXED_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(decoded!.confirmedRound).toBe(999n);
    expect(decoded!.roundTime).toBe(1_750_000_000);
  });

  it('returns roundTime undefined when txn lacks it (caller decides default)', () => {
    const a = new Uint8Array(32);
    const b = new Uint8Array(32);
    const decoded = decodeAbiCall(
      makeTxn([SELECTOR_OK, a, b], { roundTime: undefined }),
      FIXED_BYTES_SCHEMA,
      silentLogger(),
    );
    expect(decoded!.roundTime).toBeUndefined();
  });
});

describe('decodeAbiCall — setBio schema shape (dynBytes minLen 0, ≤160)', () => {
  // Mirrors SET_BIO_SCHEMA in user-watcher.ts: a single dynBytes arg where
  // empty payload is VALID (= clear bio).
  const SET_BIO_SELECTOR = Buffer.from([0xf4, 0x28, 0xf4, 0x7a]);
  const BIO_SCHEMA = {
    selector: SET_BIO_SELECTOR,
    args: {
      bio: { kind: 'dynBytes', minLen: 0, maxLen: 160 },
    },
  } satisfies AbiCallSchema<{
    bio: { kind: 'dynBytes'; minLen: number; maxLen: number };
  }>;

  it('selector constant matches sha512/256("setBio(byte[])void")[0..4]', () => {
    const expected = new algosdk.ABIMethod({
      name: 'setBio',
      args: [{ type: 'byte[]', name: 'bio' }],
      returns: { type: 'void' },
    }).getSelector();
    expect(Buffer.from(expected).equals(SET_BIO_SELECTOR)).toBe(true);
  });

  it('accepts an empty bio (clear)', () => {
    const decoded = decodeAbiCall(
      makeTxn([new Uint8Array(SET_BIO_SELECTOR), abiDynBytes(new Uint8Array(0))]),
      BIO_SCHEMA,
      silentLogger(),
    );
    expect(decoded).not.toBeNull();
    expect(decoded!.args.bio).toHaveLength(0);
  });

  it('accepts a 160-byte bio, rejects 161', () => {
    const ok = decodeAbiCall(
      makeTxn([new Uint8Array(SET_BIO_SELECTOR), abiDynBytes(new Uint8Array(160).fill(0x61))]),
      BIO_SCHEMA,
      silentLogger(),
    );
    expect(ok).not.toBeNull();
    expect(ok!.args.bio).toHaveLength(160);

    const tooLong = decodeAbiCall(
      makeTxn([new Uint8Array(SET_BIO_SELECTOR), abiDynBytes(new Uint8Array(161).fill(0x61))]),
      BIO_SCHEMA,
      silentLogger(),
    );
    expect(tooLong).toBeNull();
  });
});

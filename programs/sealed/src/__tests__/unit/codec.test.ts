import { describe, expect, it } from "vitest";
import {
  decodeBatch,
  decodeCommitment,
  decodeUserState,
  encodeBatch,
  encodeCommitment,
  encodeUserState,
  sumActiveCredits,
  USER_STATE_TYPE_V2,
  USER_STATE_VERSION,
  ZERO_KEY,
  type Batch,
  type UserState,
  type Commitment,
} from "../../lib/codec.js";

const utf8 = (s: string) => new TextEncoder().encode(s);

const baseKeys = () => ({
  encryptionPubkey: new Uint8Array(ZERO_KEY),
  scanPubkey: new Uint8Array(ZERO_KEY),
  pqPubkeyHash: new Uint8Array(ZERO_KEY),
  bio: new Uint8Array(),
});

describe("codec — Batch ARC4 round-trip", () => {
  it("encodes and decodes a batch", () => {
    const b: Batch = { amount: 50n, expiryRound: 12_345_678n };
    const decoded = decodeBatch(encodeBatch(b));
    expect(decoded).toEqual(b);
  });

  it("handles uint64 max", () => {
    const max = (1n << 64n) - 1n;
    const b: Batch = { amount: max, expiryRound: max };
    expect(decodeBatch(encodeBatch(b))).toEqual(b);
  });
});

describe("codec — Commitment ARC4 round-trip", () => {
  it("encodes and decodes a commitment", () => {
    const c: Commitment = { denomination: 50n, postedAtRound: 99n };
    expect(decodeCommitment(encodeCommitment(c))).toEqual(c);
  });
});

describe("codec — UserState ARC4 round-trip", () => {
  it("handles empty username + zero batches + zero keys", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: new Uint8Array(),
      batchCount: 0,
      batches: [],
      ...baseKeys(),
    };
    expect(decodeUserState(encodeUserState(s))).toEqual(s);
  });

  it("handles full 12 batches + max-length username + non-zero keys", () => {
    const enc = new Uint8Array(32).fill(0xaa);
    const scan = new Uint8Array(32).fill(0xbb);
    const pqHash = new Uint8Array(32).fill(0xcc);
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: utf8("a".repeat(32)),
      batchCount: 12,
      batches: Array.from({ length: 12 }, (_, i) => ({
        amount: BigInt(i + 1),
        expiryRound: BigInt(1000 + i),
      })),
      encryptionPubkey: enc,
      scanPubkey: scan,
      pqPubkeyHash: pqHash,
      bio: utf8("hello, I am a bio"),
    };
    const out = decodeUserState(encodeUserState(s));
    expect(out.batchCount).toBe(12);
    expect(out.batches).toHaveLength(12);
    expect(out.username).toEqual(s.username);
    expect(out.batches[5]).toEqual(s.batches[5]);
    expect(out.encryptionPubkey).toEqual(enc);
    expect(out.scanPubkey).toEqual(scan);
    expect(out.pqPubkeyHash).toEqual(pqHash);
  });

  it("rejects username over 32 bytes", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: utf8("a".repeat(33)),
      batchCount: 0,
      batches: [],
      ...baseKeys(),
    };
    expect(() => encodeUserState(s)).toThrow(/USERNAME_TOO_LONG/);
  });

  it("rejects > 12 batches", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: new Uint8Array(),
      batchCount: 13,
      batches: Array.from({ length: 13 }, () => ({
        amount: 1n,
        expiryRound: 1n,
      })),
      ...baseKeys(),
    };
    expect(() => encodeUserState(s)).toThrow(/TOO_MANY_BATCHES/);
  });

  it("rejects batchCount/batches.length mismatch", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: new Uint8Array(),
      batchCount: 2,
      batches: [{ amount: 1n, expiryRound: 1n }],
      ...baseKeys(),
    };
    expect(() => encodeUserState(s)).toThrow(/BATCH_COUNT_MISMATCH/);
  });

  it("rejects bad pubkey lengths", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: new Uint8Array(),
      batchCount: 0,
      batches: [],
      encryptionPubkey: new Uint8Array(31),
      scanPubkey: new Uint8Array(ZERO_KEY),
      pqPubkeyHash: new Uint8Array(ZERO_KEY),
      bio: new Uint8Array(),
    };
    expect(() => encodeUserState(s)).toThrow(/ENC_PUBKEY_BAD_LEN/);
  });

  it("rejects bio over 160 bytes", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: new Uint8Array(),
      batchCount: 0,
      batches: [],
      ...baseKeys(),
      bio: new Uint8Array(161),
    };
    expect(() => encodeUserState(s)).toThrow(/BIO_TOO_LONG/);
  });

  it("accepts a 160-byte bio (boundary)", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: new Uint8Array(),
      batchCount: 0,
      batches: [],
      ...baseKeys(),
      bio: new Uint8Array(160).fill(0x61),
    };
    expect(decodeUserState(encodeUserState(s)).bio).toHaveLength(160);
  });

  it("decodes v2 wire bytes (no bio field) as empty bio", () => {
    // Hand-build v2 encoding: same tuple minus the trailing byte[] bio.
    const v2 = USER_STATE_TYPE_V2.encode([
      2,
      utf8("alice"),
      1,
      [[42n, 999n]],
      new Uint8Array(ZERO_KEY),
      new Uint8Array(ZERO_KEY),
      new Uint8Array(ZERO_KEY),
    ]);
    const out = decodeUserState(v2 as Uint8Array);
    expect(out.version).toBe(2);
    expect(out.username).toEqual(utf8("alice"));
    expect(out.batches).toEqual([{ amount: 42n, expiryRound: 999n }]);
    expect(out.bio).toEqual(new Uint8Array(0));
  });
});

describe("codec — sumActiveCredits", () => {
  it("skips expired batches", () => {
    const s: UserState = {
      version: USER_STATE_VERSION,
      username: new Uint8Array(),
      batchCount: 3,
      batches: [
        { amount: 5n, expiryRound: 100n },
        { amount: 7n, expiryRound: 200n },
        { amount: 9n, expiryRound: 300n },
      ],
      ...baseKeys(),
    };
    expect(sumActiveCredits(s, 50n)).toBe(21n);
    expect(sumActiveCredits(s, 100n)).toBe(16n); // expiry strict >
    expect(sumActiveCredits(s, 250n)).toBe(9n);
    expect(sumActiveCredits(s, 999n)).toBe(0n);
  });
});

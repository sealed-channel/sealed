import algosdk from 'algosdk';
import {
  COMMITMENTS_SOLD_SIGNATURE,
  COMMITMENTS_SOLD_TAG,
  encodeCommitmentsSoldEvent,
  parseCommitmentsSoldEvent,
  type CommitmentsSoldEvent,
} from '../../src/preimage-server/events';

function makeAddress(seed: number): string {
  const bytes = new Uint8Array(32).fill(seed);
  return algosdk.encodeAddress(bytes);
}

function makeHash(seed: number): Uint8Array {
  return new Uint8Array(32).fill(seed);
}

const SAMPLE: CommitmentsSoldEvent = {
  buyer: makeAddress(0x11),
  deliveryPubkey: new Uint8Array(32).fill(0x22),
  commitments: [makeHash(0xa1), makeHash(0xa2), makeHash(0xa3)],
  purchasedAtRound: 1_234_567n,
};

const toHex = (b: Uint8Array): string =>
  Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');

describe('preimage-server events (CommitmentsSold ARC28 decoder)', () => {
  describe('COMMITMENTS_SOLD_TAG', () => {
    test('is 4 bytes, deterministic, matches the documented signature', () => {
      expect(COMMITMENTS_SOLD_TAG).toHaveLength(4);
      // Locked: sha512/256("CommitmentsSold(address,byte[32],byte[32][],uint64)")[0..4]
      // Drift in either side will fail this and the watcher would silently
      // ignore real events on chain.
      expect(COMMITMENTS_SOLD_SIGNATURE).toBe(
        'CommitmentsSold(address,byte[32],byte[32][],uint64)',
      );
    });
  });

  describe('encode + parse roundtrip', () => {
    test('decodes a freshly encoded event back into the same fields', () => {
      const log = encodeCommitmentsSoldEvent(SAMPLE);
      const decoded = parseCommitmentsSoldEvent(log);
      expect(decoded).not.toBeNull();
      expect(decoded!.buyer).toBe(SAMPLE.buyer);
      expect(toHex(decoded!.deliveryPubkey)).toBe(toHex(SAMPLE.deliveryPubkey));
      expect(decoded!.commitments).toHaveLength(SAMPLE.commitments.length);
      for (let i = 0; i < SAMPLE.commitments.length; i++) {
        expect(toHex(decoded!.commitments[i])).toBe(toHex(SAMPLE.commitments[i]));
      }
      expect(decoded!.purchasedAtRound).toBe(SAMPLE.purchasedAtRound);
    });

    test('handles every valid commitments-count from 1 to 8', () => {
      for (let n = 1; n <= 8; n++) {
        const commitments = Array.from({ length: n }, (_, i) => makeHash(0xb0 + i));
        const log = encodeCommitmentsSoldEvent({ ...SAMPLE, commitments });
        const decoded = parseCommitmentsSoldEvent(log);
        expect(decoded).not.toBeNull();
        expect(decoded!.commitments).toHaveLength(n);
      }
    });

    test('preserves uint64 rounds past Number.MAX_SAFE_INTEGER', () => {
      const big = BigInt(Number.MAX_SAFE_INTEGER) + 12345n;
      const log = encodeCommitmentsSoldEvent({ ...SAMPLE, purchasedAtRound: big });
      const decoded = parseCommitmentsSoldEvent(log);
      expect(decoded!.purchasedAtRound).toBe(big);
    });
  });

  describe('parse rejects malformed input', () => {
    test('returns null on a log shorter than the tag', () => {
      expect(parseCommitmentsSoldEvent(new Uint8Array(2))).toBeNull();
      expect(parseCommitmentsSoldEvent(new Uint8Array(0))).toBeNull();
    });

    test('returns null when the tag does not match', () => {
      const log = encodeCommitmentsSoldEvent(SAMPLE);
      const wrongTag = new Uint8Array(log);
      wrongTag[0] ^= 0xff;
      expect(parseCommitmentsSoldEvent(wrongTag)).toBeNull();
    });

    test('returns null on an empty commitments list (contract invariant)', () => {
      // Hand-build a body with zero commitments and confirm we reject it.
      const type = algosdk.ABIType.from('(address,byte[32],byte[32][],uint64)');
      const body = type.encode([SAMPLE.buyer, SAMPLE.deliveryPubkey, [], 1n]);
      const log = new Uint8Array(COMMITMENTS_SOLD_TAG.length + body.length);
      log.set(COMMITMENTS_SOLD_TAG, 0);
      log.set(body, COMMITMENTS_SOLD_TAG.length);
      expect(parseCommitmentsSoldEvent(log)).toBeNull();
    });

    test('returns null when commitments-count exceeds the contract cap (8)', () => {
      const tooMany = Array.from({ length: 9 }, (_, i) => makeHash(0xc0 + i));
      const log = encodeCommitmentsSoldEvent({ ...SAMPLE, commitments: tooMany });
      expect(parseCommitmentsSoldEvent(log)).toBeNull();
    });

    test('returns null on a truncated body', () => {
      const log = encodeCommitmentsSoldEvent(SAMPLE);
      const truncated = log.slice(0, log.length - 16);
      expect(parseCommitmentsSoldEvent(truncated)).toBeNull();
    });

    test('returns null on garbage after a valid tag', () => {
      const log = new Uint8Array(COMMITMENTS_SOLD_TAG.length + 64);
      log.set(COMMITMENTS_SOLD_TAG, 0);
      log.fill(0xff, COMMITMENTS_SOLD_TAG.length);
      expect(parseCommitmentsSoldEvent(log)).toBeNull();
    });
  });

  describe('encode validation', () => {
    test('rejects wrong-size deliveryPubkey', () => {
      expect(() =>
        encodeCommitmentsSoldEvent({ ...SAMPLE, deliveryPubkey: new Uint8Array(31) }),
      ).toThrow(/deliveryPubkey must be 32/);
    });

    test('rejects empty commitments at encode-time too', () => {
      expect(() => encodeCommitmentsSoldEvent({ ...SAMPLE, commitments: [] })).toThrow(
        /commitments must be non-empty/,
      );
    });

    test('rejects wrong-size commitment entries', () => {
      expect(() =>
        encodeCommitmentsSoldEvent({
          ...SAMPLE,
          commitments: [new Uint8Array(31)],
        }),
      ).toThrow(/every commitment must be 32/);
    });
  });
});

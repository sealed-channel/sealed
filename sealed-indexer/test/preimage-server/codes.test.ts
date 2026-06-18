import { createHash } from 'node:crypto';
import {
  CODE_LEN,
  commitmentFromCode,
  commitmentHash,
  formatCode,
  generateCode,
  normalizeCode,
  preimageFromCode,
} from '../../src/preimage-server/codes';

const toHex = (b: Uint8Array): string =>
  Array.from(b)
    .map((x) => x.toString(16).padStart(2, '0'))
    .join('');

/**
 * Golden vectors computed against programs/sealed/src/lib/code.ts on
 * 2026-05-28. Drift in either implementation will fail these tests and
 * surface unredeemable-code risk before any code ships.
 *
 * Reproduce via:
 *   cd programs/sealed && node --import tsx --input-type=module -e \
 *     "import {commitmentFromCode,preimageFromCode} from './src/lib/code.ts'; ..."
 */
const GOLDEN: ReadonlyArray<{ code: string; preimage: string; commitment: string; formatted: string }> = [
  {
    code: '0123456789ABCDEF',
    formatted: '0123-4567-89AB-CDEF',
    preimage: '2125b2c332b1113aae9bfc5e9f7e3b4c',
    commitment: '1c0fe3de5732f9e96ba3899402fc295f29a4c7902a28ce2d1c3e9f10627e761f',
  },
  {
    code: 'ZZZZZZZZZZZZZZZZ',
    formatted: 'ZZZZ-ZZZZ-ZZZZ-ZZZZ',
    preimage: '1c712ecc21e27e374111d5a1beeaf75a',
    commitment: 'b0e7ac0c308644530b3bac05bd7077043a9f64463a7c7a735b299708ec9cfb46',
  },
  {
    code: 'ABCD-EFGH-JKMN-PQRS',
    formatted: 'ABCD-EFGH-JKMN-PQRS',
    preimage: 'f598056127fcd4387651a49b3a4235d8',
    commitment: '79c6ec134a34d44d28e24a69a4c826ac8eae49f59c3cbacfd5b4091ab445f31f',
  },
];

describe('preimage-server codes module', () => {
  describe('parity with programs/sealed/src/lib/code.ts', () => {
    for (const v of GOLDEN) {
      test(`code "${v.code}" → preimage + commitment`, () => {
        expect(toHex(preimageFromCode(v.code))).toBe(v.preimage);
        expect(toHex(commitmentFromCode(v.code))).toBe(v.commitment);
      });
    }
  });

  describe('normalizeCode', () => {
    test('lower → upper', () => {
      expect(normalizeCode('abcdefghjkmnpqrs')).toBe('ABCDEFGHJKMNPQRS');
    });
    test('strips dashes and whitespace', () => {
      expect(normalizeCode('ABCD-EFGH JKMN-PQRS')).toBe('ABCDEFGHJKMNPQRS');
    });
    test('maps I → 1, L → 1, O → 0', () => {
      expect(normalizeCode('IIIILLLLOOOOPQRS')).toBe('111111110000PQRS');
    });
    test('rejects wrong length', () => {
      expect(() => normalizeCode('ABCD')).toThrow(/BAD_CODE_LEN/);
      expect(() => normalizeCode('ABCDEFGHJKMNPQRSXY')).toThrow(/BAD_CODE_LEN/);
    });
    test('rejects illegal Crockford chars (U is forbidden)', () => {
      expect(() => normalizeCode('UUUUUUUUUUUUUUUU')).toThrow(/BAD_CODE_CHAR U/);
    });
  });

  describe('formatCode', () => {
    test('inserts dashes every 4 chars', () => {
      expect(formatCode('0123456789ABCDEF')).toBe('0123-4567-89AB-CDEF');
    });
    test('normalizes before formatting', () => {
      expect(formatCode('abcd efgh-jkmnpqrs')).toBe('ABCD-EFGH-JKMN-PQRS');
    });
  });

  describe('generateCode', () => {
    test('produces a valid Crockford-b32 code of CODE_LEN chars', () => {
      for (let i = 0; i < 32; i++) {
        const c = generateCode();
        expect(c).toHaveLength(CODE_LEN);
        expect(() => normalizeCode(c)).not.toThrow();
      }
    });
    test('is non-deterministic (32 calls collide < 2 times)', () => {
      const seen = new Set<string>();
      for (let i = 0; i < 32; i++) seen.add(generateCode());
      expect(seen.size).toBeGreaterThan(30);
    });
  });

  describe('commitmentHash(preimage)', () => {
    test('equals sha256(preimage) for an arbitrary 16-byte input', () => {
      const pre = new Uint8Array(16).fill(0x42);
      const expected = new Uint8Array(createHash('sha256').update(pre).digest());
      expect(toHex(commitmentHash(pre))).toBe(toHex(expected));
    });
    test('matches commitmentFromCode end-to-end', () => {
      const pre = preimageFromCode('0123456789ABCDEF');
      expect(toHex(commitmentHash(pre))).toBe(toHex(commitmentFromCode('0123456789ABCDEF')));
    });
  });
});

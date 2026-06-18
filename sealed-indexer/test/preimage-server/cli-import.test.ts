import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BundleSchema, importBundle } from '../../scripts/preimage-server-import';
import { commitmentFromCode, preimageFromCode } from '../../src/preimage-server/codes';
import { createPreimageStore } from '../../src/preimage-server/db';

const toHex = (b: Uint8Array): string =>
  Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');

function makeRecord(code: string, txid = 'TX'): {
  code: string;
  codeFormatted: string;
  preimageHex: string;
  commitmentHex: string;
  txid: string;
} {
  const pre = preimageFromCode(code);
  const com = commitmentFromCode(code);
  return {
    code,
    codeFormatted: `${code.slice(0, 4)}-${code.slice(4, 8)}-${code.slice(8, 12)}-${code.slice(12, 16)}`,
    preimageHex: toHex(pre),
    commitmentHex: toHex(com),
    txid,
  };
}

describe('preimage-server-import CLI library', () => {
  let workDir: string;
  let dbPath: string;
  let txtPath: string;

  beforeEach(() => {
    workDir = mkdtempSync(join(tmpdir(), 'preimage-import-test-'));
    dbPath = join(workDir, 'test.sqlite');
    txtPath = join(workDir, 'codes.txt');
  });

  afterEach(() => {
    rmSync(workDir, { recursive: true, force: true });
  });

  describe('BundleSchema', () => {
    test('accepts a valid bundle', () => {
      const bundle = {
        network: 'testnet',
        appId: '763452863',
        denomination: '500',
        records: [makeRecord('0123456789ABCDEF')],
      };
      expect(() => BundleSchema.parse(bundle)).not.toThrow();
    });

    test('rejects malformed hex', () => {
      const rec = makeRecord('0123456789ABCDEF');
      const bundle = {
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [{ ...rec, commitmentHex: 'not-hex' }],
      };
      expect(() => BundleSchema.parse(bundle)).toThrow();
    });

    test('rejects an empty records list', () => {
      const bundle = { network: 'testnet', appId: '1', denomination: '500', records: [] };
      expect(() => BundleSchema.parse(bundle)).toThrow(/no records/);
    });
  });

  describe('importBundle()', () => {
    test('inserts every record and reports a summary', () => {
      const bundle = BundleSchema.parse({
        network: 'testnet',
        appId: '763452863',
        denomination: '500',
        records: [makeRecord('0123456789ABCDEF', 'tx1'), makeRecord('ZZZZZZZZZZZZZZZZ', 'tx2')],
      });

      const summary = importBundle(bundle, dbPath);
      expect(summary.inserted).toBe(2);
      expect(summary.skipped).toBe(0);
      expect(summary.network).toBe('testnet');
      expect(summary.appId).toBe('763452863');

      const store = createPreimageStore(dbPath);
      try {
        for (const r of bundle.records) {
          const com = commitmentFromCode(r.code);
          const row = store.getByCommitment(com);
          expect(row).not.toBeNull();
          expect(row!.status).toBe('available');
          expect(toHex(row!.preimage!)).toBe(r.preimageHex);
          // 16-char normalized code is persisted so the watcher can seal it.
          expect(row!.code).toBe(r.code);
        }
      } finally {
        store.close();
      }
    });

    test('persists the normalized 16-char form even when JSON `code` was supplied with dashes', () => {
      const formatted = 'ABCD-EFGH-JKMN-PQRS';
      const rec = makeRecord(formatted);
      const bundle = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [rec],
      });
      importBundle(bundle, dbPath);

      const store = createPreimageStore(dbPath);
      try {
        const row = store.getByCommitment(commitmentFromCode(formatted));
        expect(row!.code).toBe('ABCDEFGHJKMNPQRS');
      } finally {
        store.close();
      }
    });

    test('writes --out-txt with one codeFormatted per line and trailing newline', () => {
      const bundle = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [makeRecord('0123456789ABCDEF'), makeRecord('ZZZZZZZZZZZZZZZZ')],
      });
      importBundle(bundle, dbPath, { outTxt: txtPath });
      expect(existsSync(txtPath)).toBe(true);
      const lines = readFileSync(txtPath, 'utf-8').split('\n');
      expect(lines).toEqual(['0123-4567-89AB-CDEF', 'ZZZZ-ZZZZ-ZZZZ-ZZZZ', '']);
    });

    test('aborts on commitment hash mismatch (tampered JSON)', () => {
      const rec = makeRecord('0123456789ABCDEF');
      const tampered = {
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [
          {
            ...rec,
            commitmentHex: '0'.repeat(64),
          },
        ],
      };
      const bundle = BundleSchema.parse(tampered);
      expect(() => importBundle(bundle, dbPath)).toThrow(/COMMITMENT_MISMATCH/);

      // No row should have been inserted before the abort.
      const store = createPreimageStore(dbPath);
      try {
        expect(store.getByCommitment(commitmentFromCode(rec.code))).toBeNull();
      } finally {
        store.close();
      }
    });

    test('rejects duplicate import by default', () => {
      const bundle = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [makeRecord('0123456789ABCDEF')],
      });
      importBundle(bundle, dbPath);
      expect(() => importBundle(bundle, dbPath)).toThrow(/UNIQUE/);
    });

    test('--skip-duplicates silently skips already-inserted rows', () => {
      const bundle = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [makeRecord('0123456789ABCDEF'), makeRecord('ZZZZZZZZZZZZZZZZ')],
      });
      importBundle(bundle, dbPath);
      const second = importBundle(bundle, dbPath, { skipDuplicates: true });
      expect(second.inserted).toBe(0);
      expect(second.skipped).toBe(2);
    });

    test('partial import: --skip-duplicates inserts new rows and skips old', () => {
      const bundle1 = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [makeRecord('0123456789ABCDEF')],
      });
      importBundle(bundle1, dbPath);

      const bundle2 = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [makeRecord('0123456789ABCDEF'), makeRecord('ZZZZZZZZZZZZZZZZ')],
      });
      const summary = importBundle(bundle2, dbPath, { skipDuplicates: true });
      expect(summary.inserted).toBe(1);
      expect(summary.skipped).toBe(1);
    });

    test('closes the sqlite handle even if a mismatch throws', () => {
      const rec = makeRecord('0123456789ABCDEF');
      const bad = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [{ ...rec, commitmentHex: '0'.repeat(64) }],
      });
      expect(() => importBundle(bad, dbPath)).toThrow();
      // Re-open should succeed without "database is locked" — proves close() ran.
      const reopen = createPreimageStore(dbPath);
      reopen.close();
    });

    test('does not write --out-txt when import aborts', () => {
      const bundle = BundleSchema.parse({
        network: 'testnet',
        appId: '1',
        denomination: '500',
        records: [
          makeRecord('0123456789ABCDEF'),
          { ...makeRecord('ZZZZZZZZZZZZZZZZ'), commitmentHex: '0'.repeat(64) },
        ],
      });
      // The first record will insert (valid), the second aborts. Per spec the
      // txt is written AFTER all inserts succeed, so it must not exist here.
      const tmpTxt = join(workDir, 'should-not-exist.txt');
      writeFileSync(tmpTxt, ''); // pre-create to make absence test meaningful
      rmSync(tmpTxt);
      expect(() => importBundle(bundle, dbPath, { outTxt: tmpTxt })).toThrow();
      expect(existsSync(tmpTxt)).toBe(false);
    });
  });
});

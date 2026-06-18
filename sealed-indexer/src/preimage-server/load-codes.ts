/**
 * Admin tool: load `gen-monetization-code` output into the preimage-server
 * sqlite store as `available` rows.
 *
 * This is the bridge between the contract-side code generator
 * (`programs/sealed/src/scripts/gen-monetization-code.ts`, which registers the
 * commitment on chain and writes a JSON file) and the sidecar's delivery DB.
 * Without it, a buyer's `purchaseCodes` emits `CommitmentsSold`, the watcher
 * looks the commitment up via `getByCommitment`, finds nothing, and skips the
 * whole event — the buyer's paid code is never delivered.
 *
 * For each record the loader RECOMPUTES `preimage` and `commitment` from the
 * raw `code` (the single source of truth) and — when the input carries the
 * pre-computed hex — asserts they match. Drift between the generator and the
 * sidecar means unredeemable / undeliverable codes, so we fail loud rather
 * than trust the file.
 *
 * Usage:
 *   PREIMAGE_DB_PATH=./preimage-server.sqlite \
 *   ts-node src/preimage-server/load-codes.ts --in sale-pool-batch2.json
 *
 * Flags:
 *   --in <path>   gen-monetization-code JSON (uses `records[].code`). Required.
 *   --db <path>   sqlite path. Overrides PREIMAGE_DB_PATH (default
 *                 ./preimage-server.sqlite).
 *   --dry-run     parse + verify every record, print counts, write nothing.
 *
 * Idempotent: re-running on the same file skips rows whose commitment is
 * already present (PRIMARY KEY collision) rather than erroring. A row that has
 * already advanced to `sold`/`delivered` is left untouched.
 *
 * SECURITY: the input file holds bearer secrets (each `code` is worth a full
 * code's credits). This tool never logs `code` or `preimage` — only commitment
 * prefixes. Destroy the JSON after loading; the sidecar DB is the only place
 * the preimage should live, and only until first delivery.
 */

import { existsSync, readFileSync } from 'node:fs';

import { commitmentFromCode, normalizeCode, preimageFromCode } from './codes';
import { createPreimageStore } from './db';

interface CodeRecord {
  code: string;
  codeFormatted?: string;
  preimageHex?: string;
  commitmentHex?: string;
}

interface CodesFile {
  records?: CodeRecord[];
}

function parseArgs(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const k = a.slice(2);
    const next = argv[i + 1];
    out[k] = next && !next.startsWith('--') ? argv[++i] : 'true';
  }
  return out;
}

function toHex(b: Uint8Array): string {
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}

/** Best-effort detection of a sqlite PRIMARY KEY collision (idempotent skip). */
function isDuplicateKeyError(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    String((err as { code: unknown }).code).startsWith('SQLITE_CONSTRAINT')
  );
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  const dryRun = args['dry-run'] === 'true';

  const inPath = args.in;
  if (!inPath || inPath === 'true') throw new Error('--in <codes.json> required');
  if (!existsSync(inPath)) throw new Error(`input not found: ${inPath}`);

  const dbPath = args.db && args.db !== 'true' ? args.db : process.env.PREIMAGE_DB_PATH ?? './preimage-server.sqlite';

  const parsed = JSON.parse(readFileSync(inPath, 'utf-8')) as CodesFile;
  const records = parsed.records;
  if (!Array.isArray(records) || records.length === 0) {
    throw new Error(`${inPath} has no .records[]`);
  }

  // Recompute + verify every record BEFORE touching the DB, so a corrupt file
  // aborts the whole load instead of leaving a partial DB.
  const prepared = records.map((r, i) => {
    if (typeof r.code !== 'string') throw new Error(`record[${i}] missing .code`);
    const code = normalizeCode(r.code); // throws on bad length / charset
    const preimage = preimageFromCode(code);
    const commitment = commitmentFromCode(code);

    if (r.preimageHex && r.preimageHex.toLowerCase() !== toHex(preimage)) {
      throw new Error(`record[${i}] preimageHex mismatch — generator/sidecar drift`);
    }
    if (r.commitmentHex && r.commitmentHex.toLowerCase() !== toHex(commitment)) {
      throw new Error(`record[${i}] commitmentHex mismatch — generator/sidecar drift`);
    }
    return { code, preimage, commitment };
  });

  console.log(`db=${dbPath} input=${inPath} records=${prepared.length}${dryRun ? ' (dry-run)' : ''}`);

  if (dryRun) {
    for (const p of prepared) {
      console.log(`  [dry-run] would insert commitment=${toHex(p.commitment).slice(0, 16)}…`);
    }
    console.log(`\ndry-run complete. ${prepared.length} record(s) verified, 0 written.`);
    return;
  }

  const store = createPreimageStore(dbPath);
  let inserted = 0;
  let skipped = 0;
  try {
    for (const p of prepared) {
      try {
        store.insertAvailable(p.commitment, p.preimage, p.code);
        inserted += 1;
        console.log(`  inserted commitment=${toHex(p.commitment).slice(0, 16)}…`);
      } catch (err) {
        if (isDuplicateKeyError(err)) {
          skipped += 1;
          console.log(`  skip (already present) commitment=${toHex(p.commitment).slice(0, 16)}…`);
          continue;
        }
        throw err;
      }
    }
  } finally {
    store.close();
  }

  console.log(`\nload complete. inserted=${inserted} skipped=${skipped} total=${prepared.length}`);
}

main();

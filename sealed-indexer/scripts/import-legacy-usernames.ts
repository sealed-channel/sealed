/**
 * One-shot importer: read legacy usernames from the old indexer-service
 * SQLite (`registered_users`) and upsert them into the new sealed-tor-indexer
 * `legacy_directory` table.
 *
 * These accounts pre-date the move to Algorand on-chain `set_username`
 * and were never published on-chain. Owner pubkeys are Solana base58.
 *
 * Usage:
 *   npx ts-node scripts/import-legacy-usernames.ts \
 *     --src /path/to/indexer-service/data/indexer.db \
 *     --dst /path/to/sealed-tor-indexer/indexer.db
 *
 * Defaults:
 *   --src ../indexer-service/data/indexer.db
 *   --dst ./indexer.db
 *
 * Idempotent: re-running upserts the same rows.
 */
import path from 'path';
import Database from 'better-sqlite3';
import { createLegacyDirectoryStore } from '../src/legacy/legacy-directory';

interface CliArgs {
  src: string;
  dst: string;
}

function parseArgs(argv: string[]): CliArgs {
  const args: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const val = argv[i + 1];
      if (!val || val.startsWith('--')) {
        throw new Error(`Missing value for --${key}`);
      }
      args[key] = val;
      i++;
    }
  }
  return {
    src: args.src ?? path.resolve(__dirname, '../../indexer-service/data/indexer.db'),
    dst: args.dst ?? path.resolve(__dirname, '../indexer.db'),
  };
}

interface LegacyRow {
  username: string;
  owner_pubkey: string;
  encryption_pubkey: Buffer | null;
  scan_pubkey: Buffer | null;
  registered_at: number;
}

function bufToB64OrNull(buf: Buffer | null): string | null {
  if (!buf || buf.length === 0) return null;
  return buf.toString('base64');
}

function main(): void {
  const { src, dst } = parseArgs(process.argv.slice(2));
  // eslint-disable-next-line no-console
  console.log(`[legacy-import] src=${src}`);
  // eslint-disable-next-line no-console
  console.log(`[legacy-import] dst=${dst}`);

  const srcDb = new Database(src, { readonly: true });
  const dstStore = createLegacyDirectoryStore(dst);

  try {
    const rows = srcDb
      .prepare(
        `SELECT username, owner_pubkey, encryption_pubkey, scan_pubkey, registered_at
         FROM registered_users`,
      )
      .all() as LegacyRow[];

    let imported = 0;
    for (const row of rows) {
      dstStore.upsert({
        username: row.username,
        ownerPubkey: row.owner_pubkey,
        encryptionPubkey: bufToB64OrNull(row.encryption_pubkey),
        scanPubkey: bufToB64OrNull(row.scan_pubkey),
        registeredAt: row.registered_at,
        source: 'indexer-service-v1',
      });
      imported++;
    }

    // eslint-disable-next-line no-console
    console.log(`[legacy-import] imported ${imported} row(s)`);
    // eslint-disable-next-line no-console
    console.log(`[legacy-import] legacy_directory total: ${dstStore.count()}`);
  } finally {
    srcDb.close();
    dstStore.close();
  }
}

main();

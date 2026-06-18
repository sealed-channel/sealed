/**
 * Preimage-server entrypoint.
 *
 * The sidecar is a separate process from the main indexer. It owns its own
 * sqlite file and its own HTTP listener. Inbound traffic is expected to
 * reach it via the pi-gateway OHTTP relay; there should be no direct
 * public route to this port.
 *
 * Slice 4 ships only the HTTP scaffold + `/health`. The CommitmentsSold
 * watcher and the `/delivery/<hex>` endpoint land in later slices.
 *
 * Logger redaction covers every secret-bearing field name the sidecar
 * touches — drop into log entries by these keys and pino will mask them.
 * This is defense in depth on top of "never log these in the first place".
 */

import express, { type Express } from 'express';
import helmet from 'helmet';
import pino, { type Logger } from 'pino';
import algosdk from 'algosdk';

import { createPreimageStore, type PreimageStore } from './db';
import { createPreimageWatcher, type PreimageWatcher } from './watcher';

const REDACT_PATHS: string[] = [
  '*.preimage',
  '*.ciphertext',
  '*.deliveryPubkey',
  '*.delivery_key_sha256',
  '*.deliveryKeySha256',
  'preimage',
  'ciphertext',
  'deliveryPubkey',
  'delivery_key_sha256',
  'deliveryKeySha256',
];

export function createPreimageLogger(level: string = process.env.LOG_LEVEL ?? 'info'): Logger {
  return pino({
    level,
    redact: { paths: REDACT_PATHS, censor: '[REDACTED]' },
  });
}

export interface CreatePreimageAppArgs {
  store: PreimageStore;
  logger?: Logger;
}

export function createPreimageApp({ store, logger }: CreatePreimageAppArgs): Express {
  const log = logger ?? createPreimageLogger();
  const app = express();

  app.disable('x-powered-by');
  app.use(helmet());

  app.get('/health', (_req, res) => {
    const checkpoint = store.getWatcherCheckpoint();
    res.set('Cache-Control', 'no-store');
    res.json({
      status: 'ok',
      lastWatcherRound: checkpoint === null ? null : checkpoint.toString(),
    });
  });

  // SNARK-sold stock check: the LP calls this before letting a buyer pay, so
  // a payment is only sent when inventory exists (shrinks the pay-but-no-code
  // window; residual races still land in unfulfilled_payments → manual refund).
  app.get('/stock', (_req, res) => {
    res.set('Cache-Control', 'no-store');
    res.json({ available: store.countAvailable() });
  });

  const DELIVERY_HEX = /^[0-9a-fA-F]{64}$/;

  app.get('/delivery/:hex', (req, res) => {
    res.set('Cache-Control', 'no-store');
    const rawHex = req.params.hex ?? '';
    if (!DELIVERY_HEX.test(rawHex)) {
      res.status(404).type('text/plain').send('not found');
      return;
    }
    const key = Buffer.from(rawHex.toLowerCase(), 'hex');
    const ciphertext = store.getCiphertextByDeliveryKey(new Uint8Array(key));
    if (!ciphertext) {
      res.status(404).type('text/plain').send('not found');
      return;
    }
    res
      .status(200)
      .type('application/octet-stream')
      .send(Buffer.from(ciphertext));

    // Post-response: mark every matching row delivered so future fetches
    // remain idempotent (ciphertext stays) but `preimage` and `code` are
    // wiped. Failures here are non-fatal — the buyer already has their
    // ciphertext.
    try {
      const round = store.getWatcherCheckpoint() ?? 0n;
      const updated = store.markDelivered(new Uint8Array(key), round);
      if (updated > 0) {
        log.info({ rows: updated, round: round.toString() }, 'preimage-server: marked rows delivered');
      }
    } catch (err) {
      log.warn(
        { err: err instanceof Error ? err.message : String(err) },
        'preimage-server: markDelivered failed (response already sent)',
      );
    }
  });

  app.use((req, res) => {
    log.debug({ path: req.path, method: req.method }, 'unknown route');
    res.status(404).set('Cache-Control', 'no-store').type('text/plain').send('not found');
  });

  return app;
}

export interface SidecarConfig {
  dbPath: string;
  port: number;
  algodUrl: string;
  algodToken: string | undefined;
  appId: bigint;
  startRound: bigint | undefined;
  pollIntervalMs: number | undefined;
  /** SNARK-sold treasury (defaults to the app account address). */
  treasuryAddress: string;
  /** Per-code price (µAlgos); when set, enables the payment-delivery watcher. */
  priceMicroAlgos: bigint | undefined;
}

/**
 * Read sidecar config from the environment. Required:
 *
 *   ALGOD_URL          — algod endpoint (shared with the main indexer).
 *   SEALED_APP_ID      — unified Sealed contract app id (shared).
 *
 * Optional:
 *   ALGOD_TOKEN              — pass-through to algokit-subscriber.
 *   ALGORAND_START_ROUND     — first round when watcher_checkpoint is empty.
 *   PREIMAGE_DB_PATH         — sqlite file path (default `./preimage-server.sqlite`).
 *   PREIMAGE_PORT            — HTTP listen port (default 4100).
 *   PREIMAGE_POLL_INTERVAL_MS — watcher poll cadence (defaults to chain-subscription default).
 *
 * Throws synchronously on any malformed value so deploy-time mistakes
 * fail loud before the process starts holding open ports or sqlite handles.
 */
export function parseSidecarEnv(env: NodeJS.ProcessEnv): SidecarConfig {
  const dbPath = env.PREIMAGE_DB_PATH ?? './preimage-server.sqlite';

  const port = Number(env.PREIMAGE_PORT ?? '4100');
  if (!Number.isInteger(port) || port <= 0 || port >= 65_536) {
    throw new Error(`invalid PREIMAGE_PORT: ${env.PREIMAGE_PORT}`);
  }

  const algodUrl = env.ALGOD_URL;
  if (!algodUrl) throw new Error('ALGOD_URL not set');
  const algodToken = env.ALGOD_TOKEN ? env.ALGOD_TOKEN : undefined;

  const appIdRaw = env.SEALED_APP_ID;
  if (!appIdRaw) throw new Error('SEALED_APP_ID not set');
  let appId: bigint;
  try {
    appId = BigInt(appIdRaw);
  } catch {
    throw new Error(`SEALED_APP_ID is not a valid bigint: ${appIdRaw}`);
  }
  if (appId <= 0n) throw new Error('SEALED_APP_ID must be positive');

  let startRound: bigint | undefined;
  if (env.ALGORAND_START_ROUND) {
    try {
      startRound = BigInt(env.ALGORAND_START_ROUND);
    } catch {
      throw new Error(`ALGORAND_START_ROUND is not a valid bigint: ${env.ALGORAND_START_ROUND}`);
    }
    if (startRound < 0n) throw new Error('ALGORAND_START_ROUND must be non-negative');
  }

  let pollIntervalMs: number | undefined;
  if (env.PREIMAGE_POLL_INTERVAL_MS) {
    const n = Number(env.PREIMAGE_POLL_INTERVAL_MS);
    if (!Number.isFinite(n) || n <= 0) {
      throw new Error(`invalid PREIMAGE_POLL_INTERVAL_MS: ${env.PREIMAGE_POLL_INTERVAL_MS}`);
    }
    pollIntervalMs = n;
  }

  // SNARK-sold: treasury defaults to the app account address; the LP pays
  // there and the watcher delivers. Override with SEALED_TREASURY_ADDRESS.
  const treasuryAddress = env.SEALED_TREASURY_ADDRESS
    ? env.SEALED_TREASURY_ADDRESS
    : algosdk.getApplicationAddress(appId).toString();
  if (!algosdk.isValidAddress(treasuryAddress)) {
    throw new Error(`invalid SEALED_TREASURY_ADDRESS: ${treasuryAddress}`);
  }

  // Price gates the payment-delivery watcher. Absent ⇒ watcher disabled
  // (legacy CommitmentsSold path only). Must be a positive bigint when set.
  let priceMicroAlgos: bigint | undefined;
  if (env.SEALED_PRICE_MICROALGOS) {
    try {
      priceMicroAlgos = BigInt(env.SEALED_PRICE_MICROALGOS);
    } catch {
      throw new Error(`SEALED_PRICE_MICROALGOS is not a valid bigint: ${env.SEALED_PRICE_MICROALGOS}`);
    }
    if (priceMicroAlgos <= 0n) throw new Error('SEALED_PRICE_MICROALGOS must be positive');
  }

  return {
    dbPath,
    port,
    algodUrl,
    algodToken,
    appId,
    startRound,
    pollIntervalMs,
    treasuryAddress,
    priceMicroAlgos,
  };
}

function main(): void {
  const logger = createPreimageLogger();
  const cfg = parseSidecarEnv(process.env);
  const store = createPreimageStore(cfg.dbPath);
  const watcher = createPreimageWatcher({
    algodUrl: cfg.algodUrl,
    algodToken: cfg.algodToken,
    appId: cfg.appId,
    store,
    logger,
    startRound: cfg.startRound,
    pollIntervalMs: cfg.pollIntervalMs,
    treasuryAddress: cfg.treasuryAddress,
    priceMicroAlgos: cfg.priceMicroAlgos,
  });
  const app = createPreimageApp({ store, logger });

  const server = app.listen(cfg.port, () => {
    logger.info(
      { port: cfg.port, dbPath: cfg.dbPath, appId: cfg.appId.toString() },
      'preimage-server listening',
    );
  });

  watcher.start().catch((err) => {
    logger.error(
      { err: err instanceof Error ? err.message : String(err) },
      'preimage-server: watcher start failed',
    );
  });

  // Lifecycle backstop: stall watchdog exhausted its in-process rebuilds —
  // exit non-zero so docker (`restart: unless-stopped`) recreates the
  // container with a fresh process / socket pool.
  watcher.on('stalled', () => {
    logger.fatal('preimage-watcher stalled beyond recovery — exiting for container restart');
    process.exit(1);
  });

  const shutdown = async (signal: string): Promise<void> => {
    logger.info({ signal }, 'preimage-server shutting down');
    try {
      await watcher.stop();
    } catch (e) {
      logger.error(
        { err: e instanceof Error ? e.message : String(e) },
        'watcher stop failed',
      );
    }
    await new Promise<void>((resolve) => {
      server.close((err) => {
        if (err) {
          logger.error({ err: err.message }, 'http server close failed');
        }
        resolve();
      });
    });
    try {
      store.close();
    } catch (e) {
      logger.error(
        { err: e instanceof Error ? e.message : String(e) },
        'sqlite close failed',
      );
    }
    process.exit(0);
  };

  process.on('SIGINT', () => {
    void shutdown('SIGINT');
  });
  process.on('SIGTERM', () => {
    void shutdown('SIGTERM');
  });
}

if (require.main === module) {
  main();
}

// Surface PreimageWatcher type for downstream importers (tests, smoke tools).
export type { PreimageWatcher };

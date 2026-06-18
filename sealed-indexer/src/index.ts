import pino from 'pino';
import algosdk from 'algosdk';
import * as fs from 'fs';
import * as http from 'http';
import { EventEmitter } from 'events';
import { createApp } from './app';
import { createApnsJwtProvider, validateApnsEnvVars } from './notifications/apns-jwt';
import { createAlertApnsSender } from './notifications/ohttp-apns-alert';
import { createDirectAlertApnsSender } from './notifications/direct-apns-alert';
import { createOhttpFcmSender } from './notifications/ohttp-fcm';
import { createFcmAccessTokenProvider, type ServiceAccountKey } from './notifications/fcm-oauth';
import { createTargetedFanout } from './notifications/targeted-fanout';
import { createMockAlgorandWatcher, type TokenDecryptFn } from './notifications/chain-event';
import { createAlgorandWatcher, type AlgorandWatcher } from './notifications/algorand-watcher';
import { createCursorStore } from './notifications/cursor-store';
import { createTargetedPushTokenStore } from './push/targeted-store';
import { createDispatcherDecryptor } from './push/dispatcher-seal';
import { createOhttpClient } from './notifications/ohttp-client';
import { createUserDirectoryStore } from './users/user-store';
import { createUserWatcher, type UserWatcher } from './users/user-watcher';
import { createRootsStore } from './roots/roots-store';

const logger = pino({ level: process.env.LOG_LEVEL ?? 'info' });

/// OPT-IN, DATA-LOSSY: when set, a watcher lagging more than
/// [MAX_CATCHUP_ROUNDS] behind tip abandons the backlog and jumps to tip —
/// events in the skipped gap are NEVER indexed. Safe only on throwaway
/// deployments (testnet). MUST stay off for mainnet / real users, where every
/// gap event (usernames, messages) must be caught up, not dropped.
const SKIP_BACKLOG = process.env.WATCHER_SKIP_BACKLOG === '1';

/// Lag threshold for [SKIP_BACKLOG]. Ignored when SKIP_BACKLOG is off.
const MAX_CATCHUP_ROUNDS = BigInt(process.env.MAX_CATCHUP_ROUNDS ?? '1000');

/// Resolve the current chain tip (algod last-round). Returns undefined on
/// failure so callers can fall back to a static start round.
async function resolveTipRound(
  algodUrl: string,
  algodToken: string,
): Promise<bigint | undefined> {
  try {
    const algod = new algosdk.Algodv2(algodToken, algodUrl, '');
    const status = (await algod.status().do()) as unknown as Record<
      string,
      unknown
    >;
    const last = status['lastRound'] ?? status['last-round'];
    return last === undefined ? undefined : BigInt(last as number | bigint);
  } catch (e) {
    logger.warn({ e }, 'resolveTipRound failed — using static start round');
    return undefined;
  }
}

/// Position a watcher's cursor for boot.
///
///  - **No watermark (fresh DB)** → start at [tip]: don't replay pre-deploy
///    history. One-time, lossless (there's nothing persisted to lose).
///  - **Existing watermark** → leave it untouched: the watcher RESUMES and
///    catches up the gap (retry-resilient), so no event is dropped. This is the
///    mainnet-safe default.
///  - **Existing watermark + [SKIP_BACKLOG]** → if lagging beyond
///    [MAX_CATCHUP_ROUNDS], jump to tip. DROPS the gap — opt-in, testnet only.
function positionCursorForBoot(
  cursor: { getRound(): bigint | null; setRound(r: bigint): void },
  tip: bigint | undefined,
  name: string,
): void {
  if (tip === undefined) return;
  const w = cursor.getRound();
  if (w === null) {
    cursor.setRound(tip);
    logger.info(
      { name, tip: tip.toString() },
      'fresh cursor → starting at chain tip',
    );
    return;
  }
  if (SKIP_BACKLOG && tip - w > MAX_CATCHUP_ROUNDS) {
    cursor.setRound(tip);
    logger.warn(
      { name, tip: tip.toString(), previous: w.toString(), skipped: (tip - w).toString() },
      'WATCHER_SKIP_BACKLOG: jumped to tip — gap events are NOT indexed',
    );
    return;
  }
  // Default: keep the watermark; resume + catch up the gap (no data loss).
  logger.info(
    { name, watermark: w.toString(), lag: (tip - w).toString() },
    'resuming from persisted watermark (catching up, no skip)',
  );
}

const PORT = Number(process.env.PORT ?? 3000);

// Validate APNs environment variables
validateApnsEnvVars();

// Validate required environment variables for production deployment
if (!process.env.OHTTP_RELAY_URL || !process.env.OHTTP_KEY_CONFIG_URL) {
  logger.fatal('Missing required environment variables: OHTTP_RELAY_URL, OHTTP_KEY_CONFIG_URL');
  process.exit(1);
}

const dispatcherDecryptMode = process.env.DISPATCHER_DECRYPT_MODE;
let dispatcherPrivKeyBuf: Buffer | undefined;
let dispatcherPubKeyBuf: Buffer | undefined;
if (dispatcherDecryptMode !== 'split-process') {
  if (dispatcherDecryptMode === 'passthrough-dev' && process.env.NODE_ENV !== 'production') {
    // Allow passthrough-dev in non-production
  } else {
    logger.fatal('DISPATCHER_DECRYPT_MODE must be "split-process" (see Task 1.3)');
    process.exit(1);
  }
} else {
  // split-process mode requires the dispatcher keypair to be provisioned via env.
  const privB64 = process.env.DISPATCHER_PRIV_KEY_BASE64;
  const pubB64 = process.env.DISPATCHER_PUB_KEY_BASE64;
  if (!privB64 || !pubB64) {
    logger.fatal(
      'DISPATCHER_DECRYPT_MODE=split-process requires DISPATCHER_PRIV_KEY_BASE64 and DISPATCHER_PUB_KEY_BASE64',
    );
    process.exit(1);
  }
  try {
    dispatcherPrivKeyBuf = Buffer.from(privB64, 'base64');
    dispatcherPubKeyBuf = Buffer.from(pubB64, 'base64');
    if (dispatcherPrivKeyBuf.length !== 32 || dispatcherPubKeyBuf.length !== 32) {
      throw new Error('Dispatcher keys must decode to exactly 32 bytes each');
    }
  } catch (err) {
    logger.fatal({ err }, 'Failed to decode DISPATCHER_PRIV_KEY_BASE64 / DISPATCHER_PUB_KEY_BASE64');
    process.exit(1);
  }
}

const algorandWatcherMode = process.env.ALGORAND_WATCHER_MODE;
if (algorandWatcherMode !== 'mock-dev' && algorandWatcherMode !== 'production') {
  logger.fatal({ algorandWatcherMode }, 'ALGORAND_WATCHER_MODE must be "mock-dev" or "production"');
  process.exit(1);
}
if (algorandWatcherMode === 'mock-dev' && process.env.NODE_ENV === 'production') {
  logger.fatal('Mock Algorand watcher cannot be used in production');
  process.exit(1);
}

const dbPath = process.env.INDEXER_DB_PATH || './indexer.db';

// User directory is owned by the app (so /user/by-owner can read from it) and
// the user-watcher (so it can write into it). Sharing one instance avoids two
// open SQLite handles to the same file.
const userDirectoryStore = createUserDirectoryStore(dbPath);

const rootsStore = createRootsStore(dbPath);
const adminToken = process.env.ADMIN_TOKEN;

const app = createApp({
  dispatcherPubKey: dispatcherPubKeyBuf,
  userDirectory: userDirectoryStore,
  rootsStore,
  adminToken,
  preimageUpstreamUrl: process.env.PREIMAGE_UPSTREAM_URL,
});
const server = http.createServer(app);

// Indexer is push-only. Chain events trigger targeted-push trial-decrypts
// for opted-in users; clients fetch ciphertext directly from the chain via
// OHTTP. No realtime WebSocket broadcast (would require the indexer to know
// which messages belong to which user).

// Initialize push notification infrastructure
async function initializeNotifications() {
  try {
    const targetedStore = createTargetedPushTokenStore(dbPath);

    // Create OHTTP client for anonymous relaying
    const ohttpClient = createOhttpClient({
      relayUrl: process.env.OHTTP_RELAY_URL!,
      keyConfigFetcher: async () => {
        const response = await fetch(process.env.OHTTP_KEY_CONFIG_URL!);
        if (!response.ok) {
          throw new Error(`Failed to fetch OHTTP key config: ${response.status} ${response.statusText}`);
        }
        return Buffer.from(await response.arrayBuffer());
      },
    });

    // Create APNs JWT provider
    const apnsJwtProvider = createApnsJwtProvider({
      keyPath: process.env.APNS_KEY_PATH!,
      keyId: process.env.APNS_KEY_ID!,
      teamId: process.env.APNS_TEAM_ID!,
    });

    // -------------------------------------------------------------------------
    // Targeted-push senders (opt-in alert mode). Built only when the
    // service-account env is present so an iOS-only deployment still starts.
    //
    // APNS_DIRECT=1 bypasses the OHTTP relay for the APNs alert leg only.
    // Use this when the OHTTP gateway in front of the indexer does not
    // allow api.push.apple.com / api.sandbox.push.apple.com as targets and
    // returns 403 ("Target forbidden on gateway"). FCM and silent-APNs
    // continue to use OHTTP. Trade-off: Apple sees the indexer's egress IP
    // and per-push timing. Body is still TARGETED_PUSH_BODY (no sender,
    // no message metadata).
    // -------------------------------------------------------------------------
    const apnsDirect = process.env.APNS_DIRECT === '1';
    const apnsUrl = process.env.APNS_URL || 'https://api.push.apple.com:443/3/device/';
    const alertApnsSender = apnsDirect
      ? createDirectAlertApnsSender({
          apnsUrl,
          jwtProvider: apnsJwtProvider,
          topic: process.env.APNS_BUNDLE_ID!,
          onInvalidToken: (token: string) => {
            logger.warn(
              { tokenPrefix: token.slice(0, 8) },
              'alert APNs token invalidated (direct)',
            );
          },
          logger: logger.child({ component: 'direct-apns' }),
        })
      : createAlertApnsSender({
          ohttp: ohttpClient,
          apnsUrl,
          jwtProvider: apnsJwtProvider,
          topic: process.env.APNS_BUNDLE_ID!,
          onInvalidToken: (token: string) => {
            logger.warn({ tokenPrefix: token.slice(0, 8) }, 'alert APNs token invalidated');
          },
          logger: logger.child({ component: 'alert-apns' }),
        });
    if (apnsDirect) {
      logger.warn(
        { apnsUrl },
        'APNS_DIRECT=1: alert-APNs is bypassing OHTTP — Apple will see indexer egress IP',
      );
    }

    let fcmAlertSender: ReturnType<typeof createOhttpFcmSender> | null = null;
    const fcmJsonPath = process.env.FCM_SERVICE_ACCOUNT_JSON_PATH;
    const fcmProjectId = process.env.FCM_PROJECT_ID;
    if (fcmJsonPath && fcmProjectId) {
      try {
        const sa = JSON.parse(fs.readFileSync(fcmJsonPath, 'utf8')) as ServiceAccountKey;
        const accessTokenProvider = createFcmAccessTokenProvider({ serviceAccount: sa });
        fcmAlertSender = createOhttpFcmSender({
          ohttp: ohttpClient,
          projectId: fcmProjectId,
          accessTokenProvider,
          onInvalidToken: (token: string) => {
            logger.warn({ tokenPrefix: token.slice(0, 8) }, 'FCM token invalidated');
          },
          logger: logger.child({ component: 'ohttp-fcm' }),
        });
      } catch (err) {
        logger.error({ err, fcmJsonPath }, 'failed to load FCM service account; targeted Android push disabled');
      }
    } else {
      logger.warn('FCM_SERVICE_ACCOUNT_JSON_PATH / FCM_PROJECT_ID not set; targeted Android push disabled');
    }

    // Create token decryption function based on mode
    let decryptTokenFn: TokenDecryptFn;
    if (dispatcherDecryptMode === 'passthrough-dev' && process.env.NODE_ENV !== 'production') {
      // Mock token decryption for development
      decryptTokenFn = (encryptedToken: Buffer): string => {
        return encryptedToken.toString('utf8');
      };
    } else {
      // Production: sealed-box decryption with the provisioned dispatcher keypair.
      if (!dispatcherPrivKeyBuf || !dispatcherPubKeyBuf) {
        throw new Error('Dispatcher keypair missing despite split-process mode');
      }
      decryptTokenFn = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcherPrivKeyBuf,
        dispatcherPubKey: dispatcherPubKeyBuf,
      });
    }

    // Create Algorand watcher based on mode
    let algorandWatcher: EventEmitter;
    let realAlgorandWatcher: AlgorandWatcher | null = null;
    let userWatcher: UserWatcher | null = null;

    // Legacy SealedMessage app (759175203) and alias-channel app (757387707)
    // are sunset. Only the unified Sealed app is subscribed; alias chat now
    // rides `sendMessage` under its own `recipient_tag` per Spec H.
    const sealedAppIdBig = BigInt(process.env.SEALED_APP_ID || '763452863');
    if (algorandWatcherMode === 'mock-dev' && process.env.NODE_ENV !== 'production') {
      algorandWatcher = createMockAlgorandWatcher();
    } else {
      const algodUrl =
        process.env.ALGOD_URL ?? 'https://testnet-api.algonode.cloud';
      const algodToken = process.env.ALGOD_TOKEN ?? '';
      // Resolve the chain tip once at boot; both watchers start here instead of
      // re-walking ~350K rounds of history (the sync-oldest backlog that caused
      // the Cloudflare 504s). Static *_START_ROUND envs are only a fallback if
      // the tip query fails.
      const tipRound = await resolveTipRound(algodUrl, algodToken);
      logger.info(
        { tipRound: tipRound?.toString() ?? null },
        'resolved chain tip for watcher start',
      );

      const cursorStore = createCursorStore(dbPath);
      // Push watcher only cares about NEW messages — clamp to tip so we never
      // re-walk (and re-notify) historical rounds after a restart.
      positionCursorForBoot(cursorStore, tipRound, 'msg-watcher');
      realAlgorandWatcher = createAlgorandWatcher({
        algodUrl,
        algodToken,
        appIds: [sealedAppIdBig],
        cursor: cursorStore,
        startRound:
          tipRound ??
          (process.env.ALGORAND_START_ROUND
            ? BigInt(process.env.ALGORAND_START_ROUND)
            : undefined),
        logger: logger.child({ component: 'msg-watcher' }),
      });
      algorandWatcher = realAlgorandWatcher;
      await realAlgorandWatcher.start();

      // User-directory watcher uses its own cursor row so a clamp/rewind does
      // not also move the message-event watermark above.
      const userCursorStore = createCursorStore(dbPath, 'user_cursor');
      if (process.env.USER_STORE_RESET === '1') {
        userCursorStore.reset();
        logger.info('user-watcher cursor reset — will replay from genesis');
      }
      // Skip-to-tip: jump to the newest round on a fresh DB or a large backlog
      // (no historical username backfill); brief restart gaps still catch up.
      positionCursorForBoot(userCursorStore, tipRound, 'user-watcher');
      userWatcher = createUserWatcher({
        algodUrl,
        algodToken,
        messageAppId: sealedAppIdBig,
        cursor: userCursorStore,
        store: userDirectoryStore,
        startRound:
          tipRound ??
          (process.env.USER_BACKFILL_START_ROUND
            ? BigInt(process.env.USER_BACKFILL_START_ROUND)
            : undefined),
        logger: logger.child({ component: 'user-watcher' }),
      });
      await userWatcher.start();

      // Lifecycle backstop: if a watcher's stall watchdog exhausts its
      // in-process rebuilds without watermark progress, the process is no
      // longer trustworthy (wedged sockets / event loop state). Exit non-zero
      // so docker (`restart: unless-stopped`) recreates the container fresh —
      // the same remedy as a manual compose restart, automated.
      const fatalStall = (component: string) => () => {
        logger.fatal({ component }, 'watcher stalled beyond recovery — exiting for container restart');
        process.exit(1);
      };
      realAlgorandWatcher.on('stalled', fatalStall('msg-watcher'));
      userWatcher.on('stalled', fatalStall('user-watcher'));
    }

    // Targeted fanout — opt-in visible-alert path. The only push path post
    // Phase B (legacy and blinded modes have been removed). FCM falls back
    // to a no-op so iOS-only deployments without a service-account JSON
    // still start.
    const noopFcm: typeof alertApnsSender = {
      async send() {
        logger.warn('targeted-fanout: FCM sender not configured; dropping Android push');
        return { ok: false, status: 0 };
      },
    };
    const targetedFanout = createTargetedFanout({
      store: targetedStore,
      decryptToken: decryptTokenFn,
      apnsSender: alertApnsSender,
      fcmSender: fcmAlertSender ?? noopFcm,
      logger,
      algorandWatcher,
    });

    targetedFanout.start();

    logger.info('Push notification services initialized');

    // Cleanup on shutdown
    const shutdown = (exit: boolean) => {
      logger.info('Shutting down notification services...');
      targetedFanout.stop();
      if (realAlgorandWatcher) {
        realAlgorandWatcher.stop().catch((err) => logger.error({ err }, 'watcher stop failed'));
      }
      if (userWatcher) {
        userWatcher.stop().catch((err) => logger.error({ err }, 'user watcher stop failed'));
      }
      targetedStore.close();
      userDirectoryStore.close();
      if (exit) process.exit(0);
    };
    process.on('SIGTERM', () => shutdown(false));
    process.on('SIGINT', () => shutdown(true));
  } catch (error) {
    const err = error instanceof Error ? error : new Error(String(error));
    logger.error(
      { err, message: err.message, stack: err.stack },
      'Failed to initialize notification services',
    );
    process.exit(1);
  }
}

server.listen(PORT, () => {
  logger.info({ port: PORT }, 'sealed-tor-indexer listening');

  // Initialize notifications after server starts
  initializeNotifications();
});

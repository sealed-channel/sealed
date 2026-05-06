import pino from 'pino';
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

const logger = pino({ level: process.env.LOG_LEVEL ?? 'info' });

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

const app = createApp({
  dispatcherPubKey: dispatcherPubKeyBuf,
  userDirectory: userDirectoryStore,
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
    const messageAppIdBig = BigInt(process.env.SEALED_MESSAGE_APP_ID ?? '759175203');
    if (algorandWatcherMode === 'mock-dev' && process.env.NODE_ENV !== 'production') {
      algorandWatcher = createMockAlgorandWatcher();
    } else {
      const cursorStore = createCursorStore(dbPath);
      realAlgorandWatcher = createAlgorandWatcher({
        algodUrl: process.env.ALGOD_URL ?? 'https://testnet-api.algonode.cloud',
        algodToken: process.env.ALGOD_TOKEN ?? '',
        appIds: [
          BigInt(process.env.ALIAS_CHANNEL_APP_ID ?? '757387707'),
          messageAppIdBig,
        ],
        cursor: cursorStore,
        startRound: process.env.ALGORAND_START_ROUND
          ? BigInt(process.env.ALGORAND_START_ROUND)
          : undefined,
        logger,
      });
      algorandWatcher = realAlgorandWatcher;
      await realAlgorandWatcher.start();

      // User-directory watcher uses its own cursor row so a backfill rewind
      // does not also rewind the message-event watermark above (which would
      // re-fire push notifications for old chain messages).
      const userCursorStore = createCursorStore(dbPath, 'user_cursor');
      userWatcher = createUserWatcher({
        algodUrl: process.env.ALGOD_URL ?? 'https://testnet-api.algonode.cloud',
        algodToken: process.env.ALGOD_TOKEN ?? '',
        messageAppId: messageAppIdBig,
        cursor: userCursorStore,
        store: userDirectoryStore,
        startRound: process.env.USER_BACKFILL_START_ROUND
          ? BigInt(process.env.USER_BACKFILL_START_ROUND)
          : undefined,
        logger: logger.child({ component: 'user-watcher' }),
      });
      await userWatcher.start();
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

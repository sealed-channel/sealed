/**
 * On-chain user-directory watcher.
 *
 * Subscribes to `set_username` app calls on `SEALED_MESSAGE_APP_ID` and upserts
 * each observed (owner_pubkey, username, encryption_pubkey, scan_pubkey) tuple
 * into `user-store.ts`. Sibling of `notifications/algorand-watcher.ts`, but
 * intentionally a SEPARATE `AlgorandSubscriber` instance with its OWN cursor
 * row — so rewinding for historical backfill does not also replay message
 * events (which would re-fire push notifications for old chain messages).
 *
 * On-chain encoding (verified against
 *   sealed_app/lib/chain/algorand_chain_client.dart, lines 56–62, 236–253):
 *
 *   set_username(byte[] username, byte[32] encryption_pubkey, byte[32] scan_pubkey) void
 *     selector       = 0xd2fcc83f
 *     applicationArgs = [selector, abiBytes(username), encPubkey(32), scanPubkey(32)]
 *     ABI dynamic-bytes (`byte[]`) = 2-byte big-endian length || payload.
 *
 * The transaction sender (`txn.sender`) is the registering wallet — that
 * Algorand address becomes the row's `owner_pubkey`.
 *
 * Operational notes:
 *  - Backfill: when no watermark is persisted, the subscriber starts from
 *    `startRound` (env `USER_BACKFILL_START_ROUND`) and catches up via algod.
 *  - We use `syncBehaviour: 'sync-oldest'` (NOT 'sync-oldest-start-now') so the
 *    library actually walks history rather than skipping to tip.
 *  - Errors are logged via `subscriber.onError`; we never crash the host.
 *  - Username strings are validated UTF-8 of length 1..64; malformed
 *    set_username calls are ignored.
 */

import { EventEmitter } from 'events';
import type { Logger } from 'pino';
import algosdk from 'algosdk';
import { AlgorandSubscriber } from '@algorandfoundation/algokit-subscriber';
import type { CursorStore } from '../notifications/cursor-store';
import type { UserDirectoryStore } from './user-store';

const SET_USERNAME_FILTER = 'set-username-calls';

// sha512/256("set_username(byte[],byte[32],byte[32])void")[0..4]
// Source of truth: sealed_app/lib/chain/algorand_chain_client.dart:57
const SET_USERNAME_SELECTOR = Buffer.from([0xd2, 0xfc, 0xc8, 0x3f]);

// ABI byte[] dynamic-bytes header is a 2-byte big-endian length prefix.
const ABI_DYNAMIC_BYTES_HEADER = 2;
const MAX_USERNAME_BYTES = 64;

export interface UserWatcherOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  /** Sealed message app id — set_username is one of its methods. */
  readonly messageAppId: bigint;
  readonly cursor: CursorStore;
  readonly store: UserDirectoryStore;
  /** First round to scan when no watermark is persisted (backfill anchor). */
  readonly startRound?: bigint;
  readonly pollIntervalMs?: number;
  readonly logger: Logger;
  /** Test-only seam: inject a pre-built subscriber. */
  readonly subscriberFactory?: (config: SubscriberFactoryConfig) => SubscriberLike;
}

export interface UserWatcher extends EventEmitter {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export interface SubscriberLike {
  on(filterName: string, handler: (txn: SubscribedTxn) => void | Promise<void>): void;
  onError(handler: (err: unknown) => void): void;
  start(): void;
  stop(reason: string): Promise<void>;
}

export interface SubscriberFactoryConfig {
  algodUrl: string;
  algodToken: string;
  messageAppId: bigint;
  cursor: CursorStore;
  startRound?: bigint;
  frequencyInSeconds: number;
}

export interface SubscribedTxn {
  id: string;
  sender?: string;
  confirmedRound?: bigint;
  roundTime?: number;
  logs?: ReadonlyArray<Uint8Array | string>;
  applicationTransaction?: {
    applicationId?: bigint | number;
    applicationArgs?: ReadonlyArray<Uint8Array>;
  };
}

export interface DecodedSetUsername {
  ownerPubkey: string;
  username: string;
  encryptionPubkey: Buffer;
  scanPubkey: Buffer;
  observedAt: number;
}

export function createUserWatcher(opts: UserWatcherOptions): UserWatcher {
  const {
    algodUrl,
    algodToken = '',
    messageAppId,
    cursor,
    store,
    startRound,
    pollIntervalMs = 4000,
    logger,
    subscriberFactory,
  } = opts;

  const emitter = new EventEmitter() as UserWatcher;
  let subscriber: SubscriberLike | null = null;
  let started = false;
  let stopped = false;

  const factory = subscriberFactory ?? defaultSubscriberFactory;

  async function handleTxn(txn: SubscribedTxn): Promise<void> {
    try {
      const decoded = decodeSetUsername(txn, logger);
      if (!decoded) return;
      store.upsert(decoded);
      logger.info(
        {
          owner: decoded.ownerPubkey,
          username: decoded.username,
          round: txn.confirmedRound?.toString(),
          txId: txn.id,
        },
        'user-watcher: upserted user from set_username',
      );
    } catch (err) {
      logger.error(
        { err, txId: txn.id },
        'user-watcher: failed to process set_username txn',
      );
    }
  }

  async function start(): Promise<void> {
    if (started) return;
    started = true;

    subscriber = factory({
      algodUrl,
      algodToken,
      messageAppId,
      cursor,
      startRound,
      frequencyInSeconds: 5,
      
    });

    subscriber.on(SET_USERNAME_FILTER, (txn) => {
      void handleTxn(txn);
    });
    subscriber.onError((err) => {
      logger.error({ err }, 'user-watcher: subscriber error');
    });

    logger.info(
      {
        messageAppId: messageAppId.toString(),
        startRound: startRound?.toString(),
        existingCursor: cursor.getRound()?.toString() ?? null,
      },
      'user-watcher: starting',
    );
    subscriber.start();
  }

  async function stop(): Promise<void> {
    if (!started || stopped) return;
    stopped = true;
    if (subscriber) {
      await subscriber.stop('shutdown');
    }
  }

  emitter.start = start;
  emitter.stop = stop;
  return emitter;
}

/**
 * Decode a set_username app call. Returns `null` for any txn that is not a
 * well-formed set_username call (wrong selector, malformed args, bad
 * username encoding, missing sender). Exported for direct unit testing.
 */
export function decodeSetUsername(
  txn: SubscribedTxn,
  logger: Logger,
): DecodedSetUsername | null {
  const appCall = txn.applicationTransaction;
  const appArgs = appCall?.applicationArgs;
  if (!appArgs || appArgs.length !== 4) return null;

  const selector = Buffer.from(appArgs[0]);
  if (!selector.equals(SET_USERNAME_SELECTOR)) return null;

  const usernameRaw = stripAbiDynamicBytes(appArgs[1]);
  if (!usernameRaw || usernameRaw.length === 0 || usernameRaw.length > MAX_USERNAME_BYTES) {
    logger.debug({ txId: txn.id }, 'user-watcher: skipping malformed username arg');
    return null;
  }

  const encPubkeyArg = appArgs[2];
  const scanPubkeyArg = appArgs[3];
  if (encPubkeyArg.length !== 32 || scanPubkeyArg.length !== 32) {
    logger.debug({ txId: txn.id }, 'user-watcher: skipping wrong-length pubkey arg');
    return null;
  }

  if (!txn.sender || txn.sender.length === 0) {
    logger.debug({ txId: txn.id }, 'user-watcher: skipping txn with missing sender');
    return null;
  }
  // Defence-in-depth: the contract logs Txn.sender() as logs[0] for
  // set_username (since the auth-binding refactor). If logs are present,
  // they MUST agree with the txn-level sender. Disagreement means either
  // a contract regression or a subscriber-library bug — either way, drop
  // the claim rather than upsert a mismatched mapping.
  const senderFromLogs = extractSenderLog(txn);
  if (senderFromLogs && senderFromLogs !== txn.sender) {
    logger.warn(
      { txId: txn.id, txnSender: txn.sender, loggedSender: senderFromLogs },
      'user-watcher: dropping set_username with sender / log[0] mismatch',
    );
    return null;
  }

  let username: string;
  try {
    username = new TextDecoder('utf-8', { fatal: true }).decode(usernameRaw);
  } catch {
    logger.debug({ txId: txn.id }, 'user-watcher: skipping non-utf8 username');
    return null;
  }
  if (username.length === 0) return null;

  const observedAt = txn.roundTime ? txn.roundTime * 1000 : Date.now();

  return {
    ownerPubkey: txn.sender,
    username,
    encryptionPubkey: Buffer.from(encPubkeyArg),
    scanPubkey: Buffer.from(scanPubkeyArg),
    observedAt,
  };
}

function stripAbiDynamicBytes(arg: Uint8Array): Uint8Array | null {
  if (arg.length < ABI_DYNAMIC_BYTES_HEADER) return null;
  const len = (arg[0] << 8) | arg[1];
  if (len + ABI_DYNAMIC_BYTES_HEADER !== arg.length) return null;
  return arg.subarray(ABI_DYNAMIC_BYTES_HEADER);
}

/**
 * Read logs[0] of a set_username call as an Algorand address, if present.
 * Post-auth-binding contracts log Txn.sender() as the first log line so
 * downstream consumers can verify the binding without trusting the txn
 * envelope. Returns `null` for pre-binding contracts (no logs) — the caller
 * MUST treat that as "old contract, fall back to txn.sender" rather than
 * a hard failure, otherwise we cannot ingest historical claims.
 */
function extractSenderLog(txn: SubscribedTxn): string | null {
  const logs = txn.logs;
  if (!logs || logs.length === 0) return null;
  const first = logs[0];
  const buf = typeof first === 'string' ? Buffer.from(first, 'base64') : Buffer.from(first);
  if (buf.length !== 32) return null;
  try {
    return algosdk.encodeAddress(new Uint8Array(buf));
  } catch {
    return null;
  }
}

function defaultSubscriberFactory(config: SubscriberFactoryConfig): SubscriberLike {
  const algod = new algosdk.Algodv2(config.algodToken, config.algodUrl, '');
  const subscriber = new AlgorandSubscriber(
    {
      filters: [
        {
          name: SET_USERNAME_FILTER,
          filter: {
            appId: config.messageAppId,
            // Match only set_username calls. The library accepts a hex string
            // OR a function predicate; hex string is the documented happy path.
            methodSignature: 'set_username(byte[],byte[32],byte[32])void',
          },
        },
      ],
      maxRoundsToSync: 50,
      // 'sync-oldest' walks history from the watermark (or startRound) without
      // skipping to tip — that's what enables the historical backfill.
      syncBehaviour: 'sync-oldest',
      waitForBlockWhenAtTip: true,
      frequencyInSeconds: config.frequencyInSeconds,
      watermarkPersistence: {
        get: async () => {
          const persisted = config.cursor.getRound();
          if (persisted !== null) return persisted;
          return config.startRound ?? 0n;
        },
        set: async (w: bigint) => {
          config.cursor.setRound(w);
        },
      },
    },
    algod,
  );
  return {
    on: (name, handler) => subscriber.on(name, handler as never),
    onError: (handler) => subscriber.onError(handler),
    start: () => subscriber.start(),
    stop: (reason) => subscriber.stop(reason),
  };
}

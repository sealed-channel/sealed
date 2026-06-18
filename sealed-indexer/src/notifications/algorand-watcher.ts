/**
 * Real Algorand watcher for sealed-tor-indexer.
 *
 * Wraps `@algorandfoundation/algokit-subscriber` to monitor the unified Sealed
 * app (e.g. 762153589) on a single subscriber instance with one named filter,
 * and emits a unified `'newMessage'` event (`AlgorandMessageEvent`) per
 * relevant on-chain message so `targeted-fanout.ts` can dispatch pushes/WS
 * broadcasts unchanged.
 *
 * On-chain encoding contract (Sealed unified app, ARC4 selectors computed at
 * boot from `sealed.arc56.json` by `sealed-abi-decoder.ts`):
 *
 *   sendMessage(byte[32] recipient_tag, byte[] ciphertext)void
 *     selector       = 0520eebb (derived; do not hardcode here)
 *     applicationArgs = [selector, recipient_tag(32), abiBytes(framed_ciphertext)]
 *     framed_ciphertext = senderEphemeralPubkey(32) || ciphertext
 *     ABI dynamic-bytes (`byte[]`) encoding = 2-byte big-endian length || payload.
 *
 * Per Spec H, alias channels are removed from the contract; alias chat
 * messages now ride the same `sendMessage` path under their own
 * `recipient_tag`. The legacy SealedMessage app (759175203) and alias-channel
 * app (757387707) are no longer subscribed — `LEGACY_SUNSET_DISABLED` is
 * implicitly true.
 *
 * `viewKeyHash` (the key under which push tokens are indexed) is derived as
 *   sha256(recipient_tag).toString('hex')      // 64 lowercase hex chars
 * matching the format `push/store.ts` validates and what the WS `auth.ts`
 * computes from the registered view pubkey. The Flutter client is responsible
 * for registering the matching hash on `/push/register`.
 *
 * Operational notes:
 *   - One subscriber, one filter (`sealed-app-calls`).
 *   - syncBehaviour: 'sync-oldest-start-now' — first run starts at chain tip;
 *     subsequent runs resume from the persisted watermark.
 *   - waitForBlockWhenAtTip + frequencyInSeconds:1 — library handles tip-wait.
 *   - Watermark persistence is delegated to `CursorStore` (SQLite, single-row).
 *   - Errors are logged via `subscriber.onError`. The algokit subscriber HALTS
 *     its poll loop on an unhandled error and does NOT self-restart, so the
 *     handler re-arms the subscriber after a short backoff (unless stopping).
 *     A transient algod socket drop (e.g. nodely closing an idle
 *     wait-for-block long-poll: "other side closed") would otherwise kill
 *     message detection permanently. We never crash the host process.
 *   - Delivery is at-least-once: a crash between `set()` and the next emit can
 *     replay a round. Downstream is idempotent (push-fanout) so this is fine.
 *   - Inner txns are walked by the subscriber itself; we do not recurse.
 *   - We never log plaintext, ciphertext, or full recipient_tag — only the
 *     8-char viewKeyHash prefix, matching push-fanout.ts.
 */

import { EventEmitter } from 'events';
import type { Logger } from 'pino';
import algosdk from 'algosdk';
import { AlgorandSubscriber } from '@algorandfoundation/algokit-subscriber';
import type { CursorStore } from './cursor-store';
import type { AlgorandMessageEvent } from './chain-event';
import { decodeAbiCall } from './sealed-abi-decoder';
import { createStallWatchdog } from '../chain/stall-watchdog';

const SEALED_FILTER_NAME = 'sealed-app-calls';

// ABI byte[] dynamic-bytes header is a 2-byte big-endian length prefix.
const ABI_DYNAMIC_BYTES_HEADER = 2;

// Backoff before re-arming the subscriber after an unhandled poll-loop error.
const SUBSCRIBER_RESTART_BACKOFF_MS = 5000;

// Bound on waiting for a wedged subscriber to stop during a stall rebuild.
// `stop()` awaits the poll-loop promise, which may be stuck in a fetch that
// never settles — abandon the old instance rather than hang the rebuild.
const STALL_STOP_TIMEOUT_MS = 10_000;

// Sealed unified-app dispatch uses `decodeAbiCall` (sealed-abi-decoder) which
// computes ARC4 selectors at boot from sealed.arc56.json. No hardcoded
// selectors here — the decoder is the source of truth.

export interface AlgorandWatcherOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  /**
   * Sealed app IDs to subscribe. Accepts 1-3 entries for backwards
   * compatibility with callers still passing `[alias, message, sealed]`; only
   * the final entry (the unified Sealed app) is used.
   */
  readonly appIds: readonly bigint[];
  readonly cursor: CursorStore;
  readonly startRound?: bigint;
  readonly pollIntervalMs?: number;
  /** Stall watchdog: no watermark progress for this long → rebuild. Default 10 min. */
  readonly stallThresholdMs?: number;
  /** Stall watchdog check cadence. Default 30s. Exposed for tests. */
  readonly stallCheckIntervalMs?: number;
  readonly logger: Logger;
  /**
   * Test-only seam: inject a pre-built subscriber. Production callers omit
   * this and the watcher constructs an `AlgorandSubscriber` internally.
   */
  readonly subscriberFactory?: (config: SubscriberFactoryConfig) => SubscriberLike;
}

export interface AlgorandWatcher extends EventEmitter {
  start(): Promise<void>;
  stop(): Promise<void>;
}

/** Minimal subset of AlgorandSubscriber we depend on — keeps tests honest. */
export interface SubscriberLike {
  on(filterName: string, handler: (txn: SubscribedTxn) => void | Promise<void>): void;
  onError(handler: (err: unknown) => void): void;
  start(): void;
  stop(reason: string): Promise<void>;
}

export interface SubscriberFactoryConfig {
  algodUrl: string;
  algodToken: string;
  sealedAppId: bigint;
  cursor: CursorStore;
  startRound?: bigint;
  frequencyInSeconds: number;
  heartbeat?: (round: bigint) => void;
}

/**
 * The library's `SubscribedTransaction` extends algosdk.indexerModels.Transaction.
 * We only read a small handful of fields, so this narrow shape avoids coupling
 * the watcher to the full algosdk type surface (and keeps tests simple).
 */
export interface SubscribedTxn {
  id: string;
  sender?: string;
  note?: Uint8Array;
  confirmedRound?: bigint;
  roundTime?: number; // seconds since epoch
  applicationTransaction?: {
    applicationId?: bigint | number;
    applicationArgs?: ReadonlyArray<Uint8Array>;
  };
  filtersMatched?: string[];
}

export function createAlgorandWatcher(opts: AlgorandWatcherOptions): AlgorandWatcher {
  const {
    algodUrl,
    algodToken = '',
    appIds,
    cursor,
    startRound,
    pollIntervalMs = 4000,
    stallThresholdMs,
    stallCheckIntervalMs,
    logger,
    subscriberFactory,
  } = opts;

  if (appIds.length < 1 || appIds.length > 3) {
    throw new Error('algorand-watcher: expected 1-3 app IDs (last is the Sealed unified app)');
  }
  // Legacy sunset complete: only the final appId (unified Sealed app) is
  // subscribed. Older callers passing `[alias, message, sealed]` still work.
  const sealedAppId = appIds[appIds.length - 1];

  const emitter = new EventEmitter() as AlgorandWatcher;
  let subscriber: SubscriberLike | null = null;
  let started = false;
  let stopped = false;

  const factory = subscriberFactory ?? defaultSubscriberFactory;

  let lastHeartbeatRound = 0n;
  const heartbeat = (round: bigint): void => {
    // Every watermark persist counts as liveness, even when the round delta
    // is below the log throttle.
    watchdog.recordProgress();
    // Log every 500 rounds while catching up; throttles to one per ~30min
    // at tip (since tip moves ~1 round / 3.3s).
    if (round - lastHeartbeatRound < 500n) return;
    lastHeartbeatRound = round;
    logger.info({ round: round.toString() }, 'watcher heartbeat');
  };

  const handle = (filterName: string) => async (txn: SubscribedTxn) => {
    try {
      const event = mapTxnToEvent(txn, filterName, logger);
      if (event) emitter.emit('newMessage', event);
    } catch (err) {
      logger.error({ err, txId: txn.id }, 'algorand-watcher: failed to map txn');
    }
  };

  function buildSubscriber(): SubscriberLike {
    const sub = factory({
      algodUrl,
      algodToken,
      sealedAppId,
      cursor,
      startRound,
      frequencyInSeconds: Math.max(1, Math.floor(pollIntervalMs / 1000)),
      heartbeat,
    });

    sub.on(SEALED_FILTER_NAME, handle(SEALED_FILTER_NAME));
    sub.onError((err) => {
      logger.error({ err }, 'algorand subscriber error');
      // The algokit subscriber stops its poll loop on an unhandled error and
      // does not auto-restart. Re-arm after a short backoff so a transient
      // algod socket drop does not permanently silence message detection.
      // On restart the subscriber resumes from the persisted watermark, so any
      // messages that landed during the outage are caught up (at-least-once).
      // If the wedge is in the algod client itself (so re-arming this same
      // instance can't help), the stall watchdog rebuilds from scratch.
      if (stopped) return;
      setTimeout(() => {
        if (stopped || subscriber !== sub) return;
        try {
          logger.warn('algorand-watcher: restarting subscriber after error');
          sub.start();
        } catch (restartErr) {
          logger.error({ err: restartErr }, 'algorand-watcher: restart failed');
        }
      }, SUBSCRIBER_RESTART_BACKOFF_MS);
    });
    return sub;
  }

  const watchdog = createStallWatchdog({
    name: 'msg-watcher',
    logger,
    stallThresholdMs,
    checkIntervalMs: stallCheckIntervalMs,
    rebuild: async () => {
      const old = subscriber;
      subscriber = null;
      if (old) {
        // stop() aborts the wait-for-block race, but a fetch wedged inside
        // pollOnce is not abortable — bound the wait and abandon if needed.
        await Promise.race([
          old.stop('stalled').catch(() => undefined),
          new Promise((resolve) => setTimeout(resolve, STALL_STOP_TIMEOUT_MS)),
        ]);
      }
      if (stopped) return;
      subscriber = buildSubscriber();
      subscriber.start();
    },
    onGiveUp: () => {
      // Host process decides (index.ts wires this to a fatal exit so the
      // container supervisor restarts the whole indexer).
      emitter.emit('stalled');
    },
  });

  async function start(): Promise<void> {
    if (started) return;
    started = true;

    subscriber = buildSubscriber();
    logger.info(
      {
        sealedAppId: sealedAppId.toString(),
      },
      'algorand-watcher: starting',
    );
    subscriber.start();
    watchdog.start();
  }

  async function stop(): Promise<void> {
    if (!started || stopped) return;
    stopped = true;
    watchdog.stop();
    if (subscriber) {
      await subscriber.stop('shutdown');
    }
    emitter.removeAllListeners('newMessage');
  }

  emitter.start = start;
  emitter.stop = stop;
  return emitter;
}

/**
 * Map an on-chain SubscribedTxn into an AlgorandMessageEvent. Returns `null`
 * when the txn does not encode a sealed-message-shaped payload.
 *
 * Dispatch model: arc56 selector decoder. Only `sendMessage` produces push
 * events. All other methods (claimUsername, redeem, getCredits, publishKeys,
 * …) drop. Per Spec H, alias channels are removed from the contract; alias
 * chat messages ride the existing `sendMessage` path under their own
 * `recipient_tag`.
 */
export function mapTxnToEvent(
  txn: SubscribedTxn,
  filterName: string,
  logger: Logger,
): AlgorandMessageEvent | null {
  if (filterName !== SEALED_FILTER_NAME) return null;
  const appCall = txn.applicationTransaction;
  const appArgs = appCall?.applicationArgs;
  if (!appArgs || appArgs.length < 2) return null;

  const decoded = decodeAbiCall(appArgs);
  if (!decoded) return null;
  if (decoded.method !== 'sendMessage' || decoded.args.length < 2) {
    // Spec H: alias methods removed from contract. Anything that's not
    // `sendMessage` is non-routing (claimUsername / redeem / getCredits / …).
    return null;
  }

  // sendMessage(byte[32] recipientTag, byte[] framed)
  // framed = senderEphPub(32) || ciphertext
  const recipientTagArg = decoded.args[0];
  const framed = stripAbiDynamicBytes(decoded.args[1]);
  if (!framed || framed.length < 32) return null;
  const senderEphArg = framed.subarray(0, 32);
  const ciphertextRaw = framed.subarray(32);

  if (!recipientTagArg || recipientTagArg.length !== 32) return null;
  if (!senderEphArg || senderEphArg.length !== 32) return null;
  if (!ciphertextRaw || ciphertextRaw.length === 0) return null;

  const timestamp = txn.roundTime ? txn.roundTime * 1000 : Date.now();

  const event: AlgorandMessageEvent = {
    recipientTag: Buffer.from(recipientTagArg),
    senderEphemeralPubkey: Buffer.from(senderEphArg),
    ciphertext: Buffer.from(ciphertextRaw),
    messageId: txn.id,
    timestamp,
    appId: toBigInt(appCall?.applicationId),
    txId: txn.id,
    confirmedRound: txn.confirmedRound,
    sender: txn.sender,
  };

  logger.debug(
    {
      txId: txn.id,
      filter: filterName,
      round: txn.confirmedRound?.toString(),
    },
    'algorand-watcher: emitting newMessage',
  );

  return event;
}

function stripAbiDynamicBytes(arg: Uint8Array): Uint8Array {
  if (arg.length < ABI_DYNAMIC_BYTES_HEADER) return arg;
  const len = (arg[0] << 8) | arg[1];
  if (len + ABI_DYNAMIC_BYTES_HEADER !== arg.length) {
    // Length prefix doesn't match — fall back to raw bytes rather than truncate.
    return arg;
  }
  return arg.subarray(ABI_DYNAMIC_BYTES_HEADER);
}

function toBigInt(value: bigint | number | undefined): bigint | undefined {
  if (value === undefined) return undefined;
  return typeof value === 'bigint' ? value : BigInt(value);
}

function defaultSubscriberFactory(config: SubscriberFactoryConfig): SubscriberLike {
  const algod = new algosdk.Algodv2(config.algodToken, config.algodUrl, '');
  const subscriber = new AlgorandSubscriber(
    {
      filters: [
        { name: SEALED_FILTER_NAME, filter: { appId: config.sealedAppId } },
      ],
      maxRoundsToSync: 25,
      syncBehaviour: 'sync-oldest-start-now',
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
          // Heartbeat: log lag vs tip every 500 rounds OR when caught up.
          // Lets ops distinguish "msg-watcher still backfilling" from "idle".
          if (config.heartbeat) config.heartbeat(w);
        },
      },
    },
    algod,
  );
  // The library's typings include a few methods we don't use — narrow to the
  // SubscriberLike shape so callers can swap in a fake during tests.
  return {
    on: (name, handler) => subscriber.on(name, handler as never),
    onError: (handler) => subscriber.onError(handler),
    start: () => subscriber.start(),
    stop: (reason) => subscriber.stop(reason),
  };
}

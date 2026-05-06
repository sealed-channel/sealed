/**
 * Real Algorand watcher for sealed-tor-indexer.
 *
 * Wraps `@algorandfoundation/algokit-subscriber` to monitor BOTH the alias-channel
 * app (757387707) and the sealed-message app (759175203) on a single subscriber
 * instance with two named filters, and emits a unified `'newMessage'` event
 * (`AlgorandMessageEvent`) per relevant on-chain message so `push-fanout.ts` can
 * dispatch pushes/WS broadcasts unchanged.
 *
 * On-chain encoding contract (verified against
 *   sealed_app/lib/chain/algorand_chain_client.dart, lines 41–80, 192–222, 348–382):
 *
 *   SEALED_MESSAGE_APP_ID (759175203n)
 *     send_message(byte[32] recipient_tag, byte[] ciphertext)void
 *       selector       = 0x2e70c311
 *       applicationArgs = [selector, recipient_tag(32), abiBytes(framed_ciphertext)]
 *       framed_ciphertext = senderEphemeralPubkey(32) || ciphertext
 *     send_alias_message(byte[32] recipient_tag, byte[32] sender_ephemeral, byte[] ciphertext)void
 *       selector       = 0x8940d487
 *       applicationArgs = [selector, recipient_tag(32), sender_ephemeral(32), abiBytes(ciphertext)]
 *     ABI dynamic-bytes (`byte[]`) encoding = 2-byte big-endian length || payload.
 *
 *   ALIAS_CHANNEL_APP_ID (757387707n)
 *     Used by sealed_app for invite / accept handshakes (alias_chat_service.dart);
 *     direct alias chat messages are routed through SEALED_MESSAGE_APP_ID via
 *     send_alias_message above. We still subscribe so any on-chain handshake
 *     events that should ping a registered viewKeyHash are surfaced; encoding
 *     for that app is treated heuristically (arg[1] as 32-byte tag, last arg as
 *     ABI dynamic bytes). If neither fits, the txn is ignored — push-fanout
 *     would have nothing to look up anyway.
 *
 * `viewKeyHash` (the key under which `push_tokens` is indexed) is derived as
 *   sha256(recipient_tag).toString('hex')      // 64 lowercase hex chars
 * matching the format `push/store.ts` validates and what the WS `auth.ts`
 * computes from the registered view pubkey. The Flutter client is responsible
 * for registering the matching hash on `/push/register`.
 *
 * Operational notes:
 *   - One subscriber, two filters (`alias-app-calls`, `message-app-calls`).
 *   - syncBehaviour: 'sync-oldest-start-now' — first run starts at chain tip;
 *     subsequent runs resume from the persisted watermark.
 *   - waitForBlockWhenAtTip + frequencyInSeconds:1 — library handles tip-wait.
 *   - Watermark persistence is delegated to `CursorStore` (SQLite, single-row).
 *   - Errors are logged via `subscriber.onError`; the library handles its own
 *     retry/backoff. We never crash the host process.
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

const ALIAS_FILTER_NAME = 'alias-app-calls';
const MESSAGE_FILTER_NAME = 'message-app-calls';

// ABI byte[] dynamic-bytes header is a 2-byte big-endian length prefix.
const ABI_DYNAMIC_BYTES_HEADER = 2;

// SealedMessage AppCall method selectors (first 4 bytes of sha512/256 of the
// canonical ABI signature). Mirrors sealed_app/lib/chain/algorand_chain_client.dart.
const SEND_MESSAGE_SELECTOR = Buffer.from([0x2e, 0x70, 0xc3, 0x11]);
const SEND_ALIAS_MESSAGE_SELECTOR = Buffer.from([0x89, 0x40, 0xd4, 0x87]);

export interface AlgorandWatcherOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  readonly appIds: readonly bigint[];
  readonly cursor: CursorStore;
  readonly startRound?: bigint;
  readonly pollIntervalMs?: number;
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
  aliasAppId: bigint;
  messageAppId: bigint;
  cursor: CursorStore;
  startRound?: bigint;
  frequencyInSeconds: number;
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
    logger,
    subscriberFactory,
  } = opts;

  if (appIds.length < 1 || appIds.length > 2) {
    throw new Error('algorand-watcher: expected 1 or 2 app IDs (alias + message)');
  }
  // Convention: appIds[0] = alias, appIds[1] = message.
  const aliasAppId = appIds[0];
  const messageAppId = appIds[1] ?? appIds[0];

  const emitter = new EventEmitter() as AlgorandWatcher;
  let subscriber: SubscriberLike | null = null;
  let started = false;
  let stopped = false;

  const factory = subscriberFactory ?? defaultSubscriberFactory;

  async function start(): Promise<void> {
    if (started) return;
    started = true;

    subscriber = factory({
      algodUrl,
      algodToken,
      aliasAppId,
      messageAppId,
      cursor,
      startRound,
      frequencyInSeconds: Math.max(1, Math.floor(pollIntervalMs / 1000)),
    });

    const handle = (filterName: string) => async (txn: SubscribedTxn) => {
      try {
        const event = mapTxnToEvent(txn, filterName, logger);
        if (event) emitter.emit('newMessage', event);
      } catch (err) {
        logger.error({ err, txId: txn.id }, 'algorand-watcher: failed to map txn');
      }
    };

    subscriber.on(ALIAS_FILTER_NAME, handle(ALIAS_FILTER_NAME));
    subscriber.on(MESSAGE_FILTER_NAME, handle(MESSAGE_FILTER_NAME));
    subscriber.onError((err) => {
      logger.error({ err }, 'algorand subscriber error');
    });

    logger.info(
      { aliasAppId: aliasAppId.toString(), messageAppId: messageAppId.toString() },
      'algorand-watcher: starting',
    );
    subscriber.start();
  }

  async function stop(): Promise<void> {
    if (!started || stopped) return;
    stopped = true;
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
 * when the txn does not encode a sealed-message-shaped payload (e.g. an
 * alias-channel handshake without a recipient_tag).
 */
export function mapTxnToEvent(
  txn: SubscribedTxn,
  filterName: string,
  logger: Logger,
): AlgorandMessageEvent | null {
  const appCall = txn.applicationTransaction;
  const appArgs = appCall?.applicationArgs;
  if (!appArgs || appArgs.length < 2) return null;

  const selector = Buffer.from(appArgs[0]);
  let recipientTagArg: Uint8Array | undefined;
  let senderEphArg: Uint8Array | undefined;
  let ciphertextRaw: Uint8Array | undefined;

  if (filterName === MESSAGE_FILTER_NAME) {
    if (selector.equals(SEND_MESSAGE_SELECTOR) && appArgs.length >= 3) {
      // [selector, recipientTag(32), abiBytes(senderEphPub(32) || ciphertext)]
      recipientTagArg = appArgs[1];
      const framed = stripAbiDynamicBytes(appArgs[2]);
      if (!framed || framed.length < 32) return null;
      senderEphArg = framed.subarray(0, 32);
      ciphertextRaw = framed.subarray(32);
    } else if (selector.equals(SEND_ALIAS_MESSAGE_SELECTOR) && appArgs.length >= 4) {
      // [selector, recipientTag(32), senderEphemeral(32), abiBytes(ciphertext)]
      recipientTagArg = appArgs[1];
      senderEphArg = appArgs[2];
      ciphertextRaw = stripAbiDynamicBytes(appArgs[3]);
    } else {
      // Unknown selector — most likely set_username / publish_pq_key. No push.
      return null;
    }
  } else if (filterName === ALIAS_FILTER_NAME) {
    // Alias-channel app encoding is intentionally heuristic: take the second
    // 32-byte arg as the recipient tag, third 32-byte arg as the sender
    // ephemeral pubkey, and the final dynamic-bytes arg as ciphertext.
    // Without a sender ephemeral we cannot trial-decrypt, so drop the txn.
    if (appArgs[1]?.length !== 32) return null;
    if (appArgs[2]?.length !== 32) return null;
    recipientTagArg = appArgs[1];
    senderEphArg = appArgs[2];
    const last = appArgs[appArgs.length - 1];
    ciphertextRaw = last && last.length > ABI_DYNAMIC_BYTES_HEADER
      ? stripAbiDynamicBytes(last)
      : last;
  } else {
    return null;
  }

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
        { name: ALIAS_FILTER_NAME, filter: { appId: config.aliasAppId } },
        { name: MESSAGE_FILTER_NAME, filter: { appId: config.messageAppId } },
      ],
      maxRoundsToSync: 100,
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

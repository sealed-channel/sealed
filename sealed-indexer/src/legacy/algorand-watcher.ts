/**
 * LEGACY Algorand watcher — sunset reads only.
 *
 * Preserved at M4 cutover. Watches ONLY the two legacy app IDs:
 *   - ALIAS_CHANNEL_APP_ID  (757387707n)
 *   - SEALED_MESSAGE_APP_ID (759175203n)
 *
 * Do NOT add the unified SEALED_APP_ID here. The unified watcher lives at
 * src/notifications/algorand-watcher.ts and handles all new traffic.
 *
 * This file exists solely so that the indexer can continue reading legacy
 * on-chain messages during the 90-day sunset window. It will be deleted in
 * phase H (task M27).
 *
 * @deprecated — phase H removes this file. Do not add new features here.
 */

import { EventEmitter } from 'events';
import type { Logger } from 'pino';
import algosdk from 'algosdk';
import { AlgorandSubscriber } from '@algorandfoundation/algokit-subscriber';
import type { CursorStore } from '../notifications/cursor-store';
import type { AlgorandMessageEvent } from '../notifications/chain-event';

const LEGACY_ALIAS_FILTER = 'legacy-alias-app-calls';
const LEGACY_MESSAGE_FILTER = 'legacy-message-app-calls';

// ABI byte[] dynamic-bytes header.
const ABI_DYNAMIC_BYTES_HEADER = 2;

// Hardcoded selectors for the legacy snake_case ABI surface.
const SEND_MESSAGE_SELECTOR = Buffer.from([0x2e, 0x70, 0xc3, 0x11]);
const SEND_ALIAS_MESSAGE_SELECTOR = Buffer.from([0x89, 0x40, 0xd4, 0x87]);

/** Legacy app IDs fixed at sunset cutover (M4). Never change these. */
export const LEGACY_ALIAS_APP_ID = 757387707n;
export const LEGACY_MESSAGE_APP_ID = 759175203n;

export interface LegacyAlgorandWatcherOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  readonly cursor: CursorStore;
  readonly startRound?: bigint;
  readonly pollIntervalMs?: number;
  readonly logger: Logger;
}

export interface LegacyAlgorandWatcher extends EventEmitter {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export function createLegacyAlgorandWatcher(opts: LegacyAlgorandWatcherOptions): LegacyAlgorandWatcher {
  const {
    algodUrl,
    algodToken = '',
    cursor,
    startRound,
    pollIntervalMs = 4000,
    logger,
  } = opts;

  const emitter = new EventEmitter() as LegacyAlgorandWatcher;
  let subscriber: ReturnType<typeof buildSubscriber> | null = null;
  let started = false;
  let stopped = false;

  function buildSubscriber() {
    const algod = new algosdk.Algodv2(algodToken, algodUrl, '');
    return new AlgorandSubscriber(
      {
        filters: [
          { name: LEGACY_ALIAS_FILTER, filter: { appId: LEGACY_ALIAS_APP_ID } },
          { name: LEGACY_MESSAGE_FILTER, filter: { appId: LEGACY_MESSAGE_APP_ID } },
        ],
        maxRoundsToSync: 25,
        syncBehaviour: 'sync-oldest-start-now',
        waitForBlockWhenAtTip: true,
        frequencyInSeconds: Math.max(1, Math.floor(pollIntervalMs / 1000)),
        watermarkPersistence: {
          get: async () => {
            const persisted = cursor.getRound();
            if (persisted !== null) return persisted;
            return startRound ?? 0n;
          },
          set: async (w: bigint) => {
            cursor.setRound(w);
          },
        },
      },
      algod,
    );
  }

  async function start(): Promise<void> {
    if (started) return;
    started = true;

    subscriber = buildSubscriber();

    const handle = (filterName: string) => async (txn: {
      id: string;
      sender?: string;
      roundTime?: number;
      confirmedRound?: bigint;
      applicationTransaction?: {
        applicationId?: bigint | number;
        applicationArgs?: ReadonlyArray<Uint8Array>;
      };
    }) => {
      try {
        const event = mapLegacyTxn(txn, filterName);
        if (event) emitter.emit('newMessage', event);
      } catch (err) {
        logger.error({ err, txId: txn.id }, 'legacy-algorand-watcher: failed to map txn');
      }
    };

    subscriber.on(LEGACY_ALIAS_FILTER, handle(LEGACY_ALIAS_FILTER) as never);
    subscriber.on(LEGACY_MESSAGE_FILTER, handle(LEGACY_MESSAGE_FILTER) as never);
    subscriber.onError((err) => {
      logger.error({ err }, 'legacy algorand subscriber error');
    });

    logger.info(
      { aliasAppId: LEGACY_ALIAS_APP_ID.toString(), messageAppId: LEGACY_MESSAGE_APP_ID.toString() },
      'legacy-algorand-watcher: starting (sunset reads only)',
    );
    subscriber.start();
  }

  async function stop(): Promise<void> {
    if (!started || stopped) return;
    stopped = true;
    if (subscriber) await subscriber.stop('shutdown');
    emitter.removeAllListeners('newMessage');
  }

  emitter.start = start;
  emitter.stop = stop;
  return emitter;
}

function mapLegacyTxn(
  txn: {
    id: string;
    sender?: string;
    roundTime?: number;
    confirmedRound?: bigint;
    applicationTransaction?: {
      applicationId?: bigint | number;
      applicationArgs?: ReadonlyArray<Uint8Array>;
    };
  },
  filterName: string,
): AlgorandMessageEvent | null {
  const appCall = txn.applicationTransaction;
  const appArgs = appCall?.applicationArgs;
  if (!appArgs || appArgs.length < 2) return null;

  let recipientTagArg: Uint8Array | undefined;
  let senderEphArg: Uint8Array | undefined;
  let ciphertextRaw: Uint8Array | undefined;

  if (filterName === LEGACY_MESSAGE_FILTER) {
    const selector = Buffer.from(appArgs[0]);
    if (selector.equals(SEND_MESSAGE_SELECTOR) && appArgs.length >= 3) {
      recipientTagArg = appArgs[1];
      const framed = stripAbi(appArgs[2]);
      if (!framed || framed.length < 32) return null;
      senderEphArg = framed.subarray(0, 32);
      ciphertextRaw = framed.subarray(32);
    } else if (selector.equals(SEND_ALIAS_MESSAGE_SELECTOR) && appArgs.length >= 4) {
      recipientTagArg = appArgs[1];
      senderEphArg = appArgs[2];
      ciphertextRaw = stripAbi(appArgs[3]);
    } else {
      return null;
    }
  } else if (filterName === LEGACY_ALIAS_FILTER) {
    if (appArgs[1]?.length !== 32 || appArgs[2]?.length !== 32) return null;
    recipientTagArg = appArgs[1];
    senderEphArg = appArgs[2];
    const last = appArgs[appArgs.length - 1];
    ciphertextRaw = last && last.length > ABI_DYNAMIC_BYTES_HEADER ? stripAbi(last) : last;
  } else {
    return null;
  }

  if (!recipientTagArg || recipientTagArg.length !== 32) return null;
  if (!senderEphArg || senderEphArg.length !== 32) return null;
  if (!ciphertextRaw || ciphertextRaw.length === 0) return null;

  const appId = appCall?.applicationId;
  return {
    recipientTag: Buffer.from(recipientTagArg),
    senderEphemeralPubkey: Buffer.from(senderEphArg),
    ciphertext: Buffer.from(ciphertextRaw),
    messageId: txn.id,
    timestamp: txn.roundTime ? txn.roundTime * 1000 : Date.now(),
    appId: appId === undefined ? undefined : typeof appId === 'bigint' ? appId : BigInt(appId),
    txId: txn.id,
    confirmedRound: txn.confirmedRound,
    sender: txn.sender,
  };
}

function stripAbi(arg: Uint8Array): Uint8Array {
  if (arg.length < ABI_DYNAMIC_BYTES_HEADER) return arg;
  const len = (arg[0] << 8) | arg[1];
  if (len + ABI_DYNAMIC_BYTES_HEADER !== arg.length) return arg;
  return arg.subarray(ABI_DYNAMIC_BYTES_HEADER);
}

/**
 * Single-app, multi-filter chain subscription.
 *
 * Wraps `@algorandfoundation/algokit-subscriber` with the wiring that used
 * to be duplicated across user-watcher.ts, username-watcher.ts, and
 * notifications/algorand-watcher.ts: cursor watermark persistence, error
 * logging, EventEmitter-style start/stop, and dispatch into per-method
 * decoders.
 *
 * One subscription = one Algorand app + one cursor row. Multiple methods
 * on the same app share a single algod polling loop; backfilling that app
 * replays all of its methods together (which is what we want — a release
 * of "alice" and a re-claim of "alice" are two events on the same app
 * that must be processed in order).
 *
 * Test seam: pass `subscriberFactory` to inject a fake SubscriberLike. The
 * default factory builds an algokit AlgorandSubscriber with the real algod
 * client. SubscriberLike is intentionally tiny so tests don't need to
 * fake the entire library surface.
 */

import { EventEmitter } from 'events';
import type { Logger } from 'pino';
import algosdk from 'algosdk';
import { AlgorandSubscriber } from '@algorandfoundation/algokit-subscriber';
import type { CursorStore } from '../notifications/cursor-store';
import { createStallWatchdog } from './stall-watchdog';
import {
  decodeAbiCall,
  type AbiArgSpec,
  type AbiCallSchema,
  type DecodedAbiCall,
  type SubscribedTxn,
} from './decode-abi-call';

export { decodeAbiCall };
export type { AbiArgSpec, AbiCallSchema, DecodedAbiCall, SubscribedTxn };

/** One method on a watched app. */
export interface ChainSubscriptionFilter<TArgs extends Record<string, AbiArgSpec>> {
  /** Internal name; surfaced to the subscriber library and used in logs. */
  name: string;
  /** Method-signature schema describing selector + named args. */
  schema: AbiCallSchema<TArgs>;
  /** ABI signature string, e.g. `claimUsername(byte[],byte[])void`. */
  methodSignature: string;
  /** Called for every txn that matches `schema`. Errors here are caught + logged. */
  onDecoded(decoded: DecodedAbiCall<TArgs>, raw: SubscribedTxn): void | Promise<void>;
}

/**
 * A non-ABI filter — used for payment txns (which have no method selector).
 * `algokitFilter` is passed straight to algokit-subscriber as the filter spec
 * (e.g. `{ type: 'pay', receiver: <addr> }`); `onTxn` receives the raw txn.
 */
export interface RawChainSubscriptionFilter {
  name: string;
  /** algokit-subscriber TransactionFilter spec. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  algokitFilter: Record<string, any>;
  onTxn(raw: SubscribedTxn): void | Promise<void>;
}

export interface ChainSubscriptionOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  /** App id to watch. All filters apply to this app. */
  readonly appId: bigint;
  /** Cursor row owned by this subscription. Do NOT share across subscriptions. */
  readonly cursor: CursorStore;
  /** First round to scan when no watermark is persisted. */
  readonly startRound?: bigint;
  /** Polling cadence; defaults to 5s to match historical watcher behaviour. */
  readonly frequencyInSeconds?: number;
  /**
   * Per-poll batch cap. Paid Nodely tier removes the 429 ceiling that
   * previously forced 25; 1000 lets backfill of ~3M rounds complete in
   * minutes instead of hours.
   */
  readonly maxRoundsToSync?: number;
  /** Stall watchdog: no watermark progress for this long → rebuild. Default 10 min. */
  readonly stallThresholdMs?: number;
  /** Stall watchdog check cadence. Default 30s. Exposed for tests. */
  readonly stallCheckIntervalMs?: number;
  readonly logger: Logger;
  // Filters are erased to `any` because each filter has its own `TArgs` and
  // we hold them in one array. The typed contract lives at construction
  // time — the schema generic flows through `addFilter`/onDecoded — so
  // callers never see the erased shape.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  readonly filters: ReadonlyArray<ChainSubscriptionFilter<any>>;
  /** Non-ABI (payment) filters applied to the same polling loop + cursor. */
  readonly rawFilters?: ReadonlyArray<RawChainSubscriptionFilter>;
  /** Test-only seam: inject a pre-built subscriber. */
  readonly subscriberFactory?: (cfg: SubscriberFactoryConfig) => SubscriberLike;
}

export interface ChainSubscription extends EventEmitter {
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
  appId: bigint;
  cursor: CursorStore;
  startRound?: bigint;
  frequencyInSeconds: number;
  maxRoundsToSync: number;
  filterNames: ReadonlyArray<{
    name: string;
    /** ABI method signature (ABI filters); omitted for raw filters. */
    methodSignature?: string;
    /** Explicit algokit filter spec (raw filters); overrides the appId/method default. */
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    algokitFilter?: Record<string, any>;
  }>;
  heartbeat?: (round: bigint) => void;
}

const DEFAULT_FREQUENCY_S = 5;
const DEFAULT_MAX_ROUNDS = 1000;

// Backoff before re-arming the subscriber after an unhandled poll-loop error.
const SUBSCRIBER_RESTART_BACKOFF_MS = 5000;

// Bound on waiting for a wedged subscriber to stop during a stall rebuild.
// `stop()` awaits the poll-loop promise, which may be stuck in a fetch that
// never settles — abandon the old instance rather than hang the rebuild.
const STALL_STOP_TIMEOUT_MS = 10_000;

export function createChainSubscription(opts: ChainSubscriptionOptions): ChainSubscription {
  const {
    algodUrl,
    algodToken = '',
    appId,
    cursor,
    startRound,
    frequencyInSeconds = DEFAULT_FREQUENCY_S,
    maxRoundsToSync = DEFAULT_MAX_ROUNDS,
    stallThresholdMs,
    stallCheckIntervalMs,
    logger,
    filters,
    rawFilters = [],
    subscriberFactory,
  } = opts;

  if (filters.length === 0 && rawFilters.length === 0) {
    throw new Error('createChainSubscription: at least one filter required');
  }

  const emitter = new EventEmitter() as ChainSubscription;
  let subscriber: SubscriberLike | null = null;
  let started = false;
  let stopped = false;

  const factory = subscriberFactory ?? defaultSubscriberFactory;

  function makeHandler(filter: ChainSubscriptionFilter<Record<string, AbiArgSpec>>) {
    return async (txn: SubscribedTxn): Promise<void> => {
      try {
        const decoded = decodeAbiCall(txn, filter.schema, logger);
        if (!decoded) return;
        await filter.onDecoded(decoded, txn);
      } catch (err) {
        logger.error(
          { err, txId: txn.id, filter: filter.name },
          'chain-subscription: handler threw',
        );
      }
    };
  }

  function makeRawHandler(filter: RawChainSubscriptionFilter) {
    return async (txn: SubscribedTxn): Promise<void> => {
      try {
        await filter.onTxn(txn);
      } catch (err) {
        logger.error(
          { err, txId: txn.id, filter: filter.name },
          'chain-subscription: raw handler threw',
        );
      }
    };
  }

  let lastHeartbeatRound = 0n;
  const heartbeat = (round: bigint): void => {
    // Every watermark persist counts as liveness, even when the round delta
    // is below the log throttle.
    watchdog.recordProgress();
    if (round - lastHeartbeatRound < 500n) return;
    lastHeartbeatRound = round;
    logger.info({ round: round.toString() }, 'watcher heartbeat');
  };

  function buildSubscriber(): SubscriberLike {
    const sub = factory({
      algodUrl,
      algodToken,
      appId,
      cursor,
      startRound,
      frequencyInSeconds,
      maxRoundsToSync,
      filterNames: [
        ...filters.map((f) => ({ name: f.name, methodSignature: f.methodSignature })),
        ...rawFilters.map((f) => ({ name: f.name, algokitFilter: f.algokitFilter })),
      ],
      heartbeat,
    });

    for (const filter of filters) {
      sub.on(filter.name, makeHandler(filter));
    }
    for (const filter of rawFilters) {
      sub.on(filter.name, makeRawHandler(filter));
    }
    sub.onError((err) => {
      logger.error({ err, appId: appId.toString() }, 'chain-subscription: subscriber error');
      // The algokit subscriber stops its poll loop on an unhandled error and
      // does not auto-restart. Re-arm after a short backoff so a transient
      // algod socket drop does not permanently silence this watcher. On restart
      // it resumes from the persisted watermark (at-least-once catch-up).
      // If the wedge is in the algod client itself (so re-arming this same
      // instance can't help), the stall watchdog rebuilds from scratch.
      if (stopped) return;
      setTimeout(() => {
        if (stopped || subscriber !== sub) return;
        try {
          logger.warn({ appId: appId.toString() }, 'chain-subscription: restarting subscriber after error');
          sub.start();
        } catch (restartErr) {
          logger.error({ err: restartErr }, 'chain-subscription: restart failed');
        }
      }, SUBSCRIBER_RESTART_BACKOFF_MS);
    });
    return sub;
  }

  const watchdog = createStallWatchdog({
    name: `chain-subscription:${appId.toString()}`,
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
        appId: appId.toString(),
        filters: [...filters.map((f) => f.name), ...rawFilters.map((f) => f.name)],
        startRound: startRound?.toString(),
        existingCursor: cursor.getRound()?.toString() ?? null,
      },
      'chain-subscription: starting',
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
  }

  emitter.start = start;
  emitter.stop = stop;
  return emitter;
}

function defaultSubscriberFactory(config: SubscriberFactoryConfig): SubscriberLike {
  const algod = new algosdk.Algodv2(config.algodToken, config.algodUrl, '');
  const subscriber = new AlgorandSubscriber(
    {
      filters: config.filterNames.map((f) => ({
        name: f.name,
        filter: f.algokitFilter ?? {
          appId: config.appId,
          methodSignature: f.methodSignature,
        },
      })),
      maxRoundsToSync: config.maxRoundsToSync,
      // 'sync-oldest' walks history from watermark/startRound rather than
      // skipping to tip — required for historical backfill.
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
          if (config.heartbeat) config.heartbeat(w);
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

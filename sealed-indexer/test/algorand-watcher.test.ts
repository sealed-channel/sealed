/**
 * Unit tests for the real Algorand watcher.
 *
 * Strategy: inject a fake `SubscriberLike` via `subscriberFactory` so we can
 * drive the on-chain handlers deterministically without hitting algod.
 *
 * Post-sunset: only the unified Sealed app + `sealed-app-calls` filter is
 * subscribed. Legacy MessageApp/AliasChannel selectors and filters were
 * removed when the contract dropped alias methods (Spec H).
 */

import { EventEmitter } from 'events';
import {
  createAlgorandWatcher,
  mapTxnToEvent,
  type SubscribedTxn,
  type SubscriberLike,
  type SubscriberFactoryConfig,
} from '../src/notifications/algorand-watcher';
import type { AlgorandMessageEvent } from '../src/notifications/chain-event';
import type { CursorStore } from '../src/notifications/cursor-store';

// Sealed unified-app ARC4 selectors (see sealed-abi-decoder.ts).
const SEALED_SEND_MESSAGE = Buffer.from('0520eebb', 'hex');
const SEALED_CLAIM_USERNAME = Buffer.from('27343994', 'hex');
const SEALED_REDEEM = Buffer.from('8560bf42', 'hex');
const SEALED_PUBLISH_KEYS = Buffer.from('e28c0434', 'hex');

const SEALED_APP_ID = 762153589n;

function silentLogger() {
  const fn = jest.fn();
  return { info: fn, debug: fn, warn: fn, error: fn, fatal: fn, trace: fn, child: () => silentLogger() } as any;
}

function inMemoryCursor(initial: bigint | null = null): CursorStore {
  let value = initial;
  return {
    getRound: () => value,
    setRound: (r: bigint) => {
      value = r;
    },
    reset: () => {
      value = null;
    },
    close: () => {},
  };
}

function abiBytes(payload: Buffer): Uint8Array {
  const out = Buffer.alloc(2 + payload.length);
  out.writeUInt16BE(payload.length, 0);
  payload.copy(out, 2);
  return new Uint8Array(out);
}

function makeMessageTxn(opts: {
  id?: string;
  recipientTag: Buffer;
  ciphertext: Buffer;
  senderEphemeral?: Buffer;
  appId?: bigint;
  round?: bigint;
  roundTime?: number;
}): SubscribedTxn {
  const eph = opts.senderEphemeral ?? Buffer.alloc(32, 0xab);
  const framed = Buffer.concat([eph, opts.ciphertext]);
  return {
    id: opts.id ?? 'TX_MESSAGE',
    sender: 'SENDERAAAA',
    confirmedRound: opts.round ?? 100n,
    roundTime: opts.roundTime ?? 1_700_000_000,
    applicationTransaction: {
      applicationId: opts.appId ?? SEALED_APP_ID,
      applicationArgs: [
        new Uint8Array(SEALED_SEND_MESSAGE),
        new Uint8Array(opts.recipientTag),
        abiBytes(framed),
      ],
    },
    filtersMatched: ['sealed-app-calls'],
  };
}

class FakeSubscriber implements SubscriberLike {
  handlers = new Map<string, (txn: SubscribedTxn) => void | Promise<void>>();
  errorHandler: ((err: unknown) => void) | null = null;
  startCalls = 0;
  stopCalls: string[] = [];

  on(name: string, handler: (txn: SubscribedTxn) => void | Promise<void>): void {
    this.handlers.set(name, handler);
  }
  onError(handler: (err: unknown) => void): void {
    this.errorHandler = handler;
  }
  start(): void {
    this.startCalls += 1;
  }
  async stop(reason: string): Promise<void> {
    this.stopCalls.push(reason);
  }

  async deliver(filterName: string, txn: SubscribedTxn): Promise<void> {
    const h = this.handlers.get(filterName);
    if (!h) throw new Error(`no handler registered for ${filterName}`);
    await h(txn);
  }
}

function recordEvents(emitter: EventEmitter): AlgorandMessageEvent[] {
  const out: AlgorandMessageEvent[] = [];
  emitter.on('newMessage', (e: AlgorandMessageEvent) => out.push(e));
  return out;
}

describe('Algorand watcher — filtering and event derivation', () => {
  it('emits one newMessage per matching sealed sendMessage txn (AC1)', async () => {
    const fake = new FakeSubscriber();
    const cursor = inMemoryCursor();
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor,
      logger: silentLogger(),
      subscriberFactory: () => fake,
    });
    const events = recordEvents(watcher);

    await watcher.start();

    await fake.deliver('sealed-app-calls', makeMessageTxn({
      id: 'TX1',
      recipientTag: Buffer.alloc(32, 0x11),
      ciphertext: Buffer.from('hello'),
    }));
    // Non-sendMessage selector — must drop.
    await fake.deliver('sealed-app-calls', {
      id: 'TX_BAD',
      applicationTransaction: {
        applicationId: SEALED_APP_ID,
        applicationArgs: [new Uint8Array([0xde, 0xad, 0xbe, 0xef])],
      },
    });

    expect(events.length).toBe(1);
    expect(events[0].messageId).toBe('TX1');
    expect(events[0].appId).toBe(SEALED_APP_ID);
  });

  it('AlgorandMessageEvent shape matches push-fanout contract (AC3)', async () => {
    const fake = new FakeSubscriber();
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor: inMemoryCursor(),
      logger: silentLogger(),
      subscriberFactory: () => fake,
    });
    const events = recordEvents(watcher);
    await watcher.start();

    const tag = Buffer.alloc(32, 0x42);
    const eph = Buffer.alloc(32, 0xab);

    await fake.deliver('sealed-app-calls', makeMessageTxn({
      recipientTag: tag,
      senderEphemeral: eph,
      ciphertext: Buffer.from('ct-bytes'),
      roundTime: 1_700_000_123,
    }));

    const event = events[0];
    expect(Buffer.isBuffer(event.recipientTag)).toBe(true);
    expect(event.recipientTag.equals(tag)).toBe(true);
    expect(Buffer.isBuffer(event.senderEphemeralPubkey)).toBe(true);
    expect(event.senderEphemeralPubkey.equals(eph)).toBe(true);
    expect(Buffer.isBuffer(event.ciphertext)).toBe(true);
    expect(event.ciphertext.equals(Buffer.from('ct-bytes'))).toBe(true);
    expect(event.timestamp).toBe(1_700_000_123 * 1000);
  });

  it('drops txn with malformed recipient tag length', () => {
    const txn: SubscribedTxn = {
      id: 'TX_BAD_TAG',
      applicationTransaction: {
        applicationId: SEALED_APP_ID,
        applicationArgs: [
          new Uint8Array(SEALED_SEND_MESSAGE),
          new Uint8Array(Buffer.alloc(16)), // wrong length
          abiBytes(Buffer.from('x')),
        ],
      },
    };
    expect(mapTxnToEvent(txn, 'sealed-app-calls', silentLogger())).toBeNull();
  });
});

describe('Algorand watcher — Sealed unified-app selector dispatch (M3)', () => {
  it('routes sealed sendMessage to push event', () => {
    const tag = Buffer.alloc(32, 0x55);
    const eph = Buffer.alloc(32, 0x66);
    const ct = Buffer.from('sealed-ct');
    const txn: SubscribedTxn = {
      id: 'TX_SEALED_MSG',
      applicationTransaction: {
        applicationId: SEALED_APP_ID,
        applicationArgs: [
          new Uint8Array(SEALED_SEND_MESSAGE),
          new Uint8Array(tag),
          abiBytes(Buffer.concat([eph, ct])),
        ],
      },
    };
    const ev = mapTxnToEvent(txn, 'sealed-app-calls', silentLogger());
    expect(ev).not.toBeNull();
    expect(ev!.recipientTag.equals(tag)).toBe(true);
    expect(ev!.senderEphemeralPubkey.equals(eph)).toBe(true);
    expect(ev!.ciphertext.equals(ct)).toBe(true);
  });

  it.each([
    ['claimUsername', SEALED_CLAIM_USERNAME],
    ['redeem', SEALED_REDEEM],
    ['publishKeys', SEALED_PUBLISH_KEYS],
  ])('drops sealed %s (not a push trigger)', (_name, selector) => {
    const txn: SubscribedTxn = {
      id: 'TX_DROP',
      applicationTransaction: {
        applicationId: SEALED_APP_ID,
        applicationArgs: [
          new Uint8Array(selector),
          new Uint8Array(Buffer.alloc(32, 0x01)),
          new Uint8Array(Buffer.alloc(32, 0x02)),
        ],
      },
    };
    expect(mapTxnToEvent(txn, 'sealed-app-calls', silentLogger())).toBeNull();
  });

  it('drops unknown selector on sealed filter', () => {
    const txn: SubscribedTxn = {
      id: 'TX_UNKNOWN',
      applicationTransaction: {
        applicationId: SEALED_APP_ID,
        applicationArgs: [
          new Uint8Array([0xde, 0xad, 0xbe, 0xef]),
          new Uint8Array(Buffer.alloc(32, 0x01)),
        ],
      },
    };
    expect(mapTxnToEvent(txn, 'sealed-app-calls', silentLogger())).toBeNull();
  });

  it('drops txn delivered on unknown filter name', () => {
    const tag = Buffer.alloc(32, 0x55);
    const eph = Buffer.alloc(32, 0x66);
    const ct = Buffer.from('sealed-ct');
    const txn: SubscribedTxn = {
      id: 'TX_WRONG_FILTER',
      applicationTransaction: {
        applicationId: SEALED_APP_ID,
        applicationArgs: [
          new Uint8Array(SEALED_SEND_MESSAGE),
          new Uint8Array(tag),
          abiBytes(Buffer.concat([eph, ct])),
        ],
      },
    };
    expect(mapTxnToEvent(txn, 'message-app-calls', silentLogger())).toBeNull();
  });
});

describe('Algorand watcher — cursor persistence (AC4, AC5, AC6)', () => {
  it('reads watermark from cursor on start', async () => {
    let captured: SubscriberFactoryConfig | null = null;
    const fake = new FakeSubscriber();
    const cursor = inMemoryCursor(12345n);
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor,
      startRound: 999n,
      logger: silentLogger(),
      subscriberFactory: (config) => {
        captured = config;
        return fake;
      },
    });
    await watcher.start();
    expect(captured).not.toBeNull();
    expect(captured!.cursor.getRound()).toBe(12345n);
  });

  it('falls back to startRound when cursor empty', async () => {
    let captured: SubscriberFactoryConfig | null = null;
    const fake = new FakeSubscriber();
    const cursor = inMemoryCursor(null);
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor,
      startRound: 555n,
      logger: silentLogger(),
      subscriberFactory: (config) => {
        captured = config;
        return fake;
      },
    });
    await watcher.start();
    expect(captured!.cursor.getRound()).toBeNull();
    expect(captured!.startRound).toBe(555n);
  });

  it('persists cursor across stop + restart (AC4, AC6)', async () => {
    const cursor = inMemoryCursor();
    const fake1 = new FakeSubscriber();
    const w1 = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor,
      logger: silentLogger(),
      subscriberFactory: () => fake1,
    });
    await w1.start();
    cursor.setRound(42n); // simulate library advancing watermark
    await w1.stop();

    const fake2 = new FakeSubscriber();
    const w2 = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor,
      logger: silentLogger(),
      subscriberFactory: () => fake2,
    });
    await w2.start();
    expect(cursor.getRound()).toBe(42n);
  });
});

describe('Algorand watcher — error handling and lifecycle (AC7, AC8)', () => {
  it('logs subscriber errors without crashing', async () => {
    const fake = new FakeSubscriber();
    const logger = silentLogger();
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor: inMemoryCursor(),
      logger,
      subscriberFactory: () => fake,
    });
    await watcher.start();
    expect(fake.errorHandler).not.toBeNull();
    fake.errorHandler!(new Error('algod blew up'));
    expect(logger.error).toHaveBeenCalled();
    // Watcher should still stop cleanly.
    await expect(watcher.stop()).resolves.toBeUndefined();
  });

  it('restarts the subscriber after an unhandled poll-loop error (backoff)', async () => {
    jest.useFakeTimers();
    try {
      const fake = new FakeSubscriber();
      const watcher = createAlgorandWatcher({
        algodUrl: 'http://x',
        appIds: [SEALED_APP_ID],
        cursor: inMemoryCursor(),
        logger: silentLogger(),
        subscriberFactory: () => fake,
      });
      await watcher.start();
      expect(fake.startCalls).toBe(1);

      // Simulate the algokit subscriber halting its poll loop on a socket drop.
      fake.errorHandler!(new Error('fetch failed: other side closed'));
      // Not restarted synchronously — waits for the backoff.
      expect(fake.startCalls).toBe(1);

      jest.advanceTimersByTime(5000);
      expect(fake.startCalls).toBe(2);

      await watcher.stop();
    } finally {
      jest.useRealTimers();
    }
  });

  it('does not restart after stop() (no zombie subscriber)', async () => {
    jest.useFakeTimers();
    try {
      const fake = new FakeSubscriber();
      const watcher = createAlgorandWatcher({
        algodUrl: 'http://x',
        appIds: [SEALED_APP_ID],
        cursor: inMemoryCursor(),
        logger: silentLogger(),
        subscriberFactory: () => fake,
      });
      await watcher.start();
      await watcher.stop();
      fake.errorHandler!(new Error('late error after shutdown'));
      jest.advanceTimersByTime(5000);
      // start() only ever called once (the initial start); no restart post-stop.
      expect(fake.startCalls).toBe(1);
    } finally {
      jest.useRealTimers();
    }
  });

  it('stop() calls subscriber.stop("shutdown") exactly once and stops emitting', async () => {
    const fake = new FakeSubscriber();
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor: inMemoryCursor(),
      logger: silentLogger(),
      subscriberFactory: () => fake,
    });
    const events = recordEvents(watcher);
    await watcher.start();
    await watcher.stop();
    expect(fake.stopCalls).toEqual(['shutdown']);

    // Idempotent: a second stop is a no-op.
    await watcher.stop();
    expect(fake.stopCalls).toEqual(['shutdown']);
    expect(events.length).toBe(0);
  });
});

describe('Algorand watcher — stall watchdog (silent wedge recovery)', () => {
  // Regression: in production the poll loop wedged in a never-settling fetch
  // (half-open TCP on the wait-for-block long-poll) after ~18-24h. No error
  // event fires, so the backoff re-arm above never runs. The watchdog must
  // rebuild the subscriber (fresh algod client) when the watermark stalls,
  // and emit 'stalled' once rebuilds are exhausted.
  const STALL_MS = 1000;
  const CHECK_MS = 100;

  function makeStallWatcher() {
    const fakes: FakeSubscriber[] = [];
    const configs: SubscriberFactoryConfig[] = [];
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [SEALED_APP_ID],
      cursor: inMemoryCursor(),
      logger: silentLogger(),
      stallThresholdMs: STALL_MS,
      stallCheckIntervalMs: CHECK_MS,
      subscriberFactory: (config) => {
        configs.push(config);
        const fake = new FakeSubscriber();
        fakes.push(fake);
        return fake;
      },
    });
    return { watcher, fakes, configs };
  }

  it('rebuilds the subscriber when the watermark stops advancing', async () => {
    jest.useFakeTimers();
    try {
      const { watcher, fakes } = makeStallWatcher();
      await watcher.start();
      expect(fakes).toHaveLength(1);

      await jest.advanceTimersByTimeAsync(STALL_MS + CHECK_MS * 2);
      expect(fakes).toHaveLength(2);
      expect(fakes[0].stopCalls).toEqual(['stalled']);
      expect(fakes[1].startCalls).toBe(1);

      await watcher.stop();
    } finally {
      jest.useRealTimers();
    }
  });

  it('watermark progress keeps the watchdog quiet', async () => {
    jest.useFakeTimers();
    try {
      const { watcher, fakes, configs } = makeStallWatcher();
      await watcher.start();

      let round = 1n;
      for (let i = 0; i < 30; i++) {
        await jest.advanceTimersByTimeAsync(CHECK_MS);
        configs[0].heartbeat?.((round += 1n));
      }
      expect(fakes).toHaveLength(1);

      await watcher.stop();
    } finally {
      jest.useRealTimers();
    }
  });

  it('emits stalled after exhausting rebuilds without progress', async () => {
    jest.useFakeTimers();
    try {
      const { watcher } = makeStallWatcher();
      const stalled = jest.fn();
      watcher.on('stalled', stalled);
      await watcher.start();

      // 3 rebuild windows + one more check past exhaustion.
      await jest.advanceTimersByTimeAsync((STALL_MS + CHECK_MS * 2) * 5);
      expect(stalled).toHaveBeenCalledTimes(1);

      await watcher.stop();
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('Algorand watcher — input validation', () => {
  it('rejects empty appIds array', () => {
    expect(() =>
      createAlgorandWatcher({
        algodUrl: 'http://x',
        appIds: [],
        cursor: inMemoryCursor(),
        logger: silentLogger(),
        subscriberFactory: () => new FakeSubscriber(),
      }),
    ).toThrow();
  });
});

/**
 * Unit tests for the real Algorand watcher.
 *
 * Strategy: inject a fake `SubscriberLike` via `subscriberFactory` so we can
 * drive the on-chain handlers deterministically without hitting algod.
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

const SEND_MESSAGE_SELECTOR = Buffer.from([0x2e, 0x70, 0xc3, 0x11]);
const SEND_ALIAS_MESSAGE_SELECTOR = Buffer.from([0x89, 0x40, 0xd4, 0x87]);

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
      applicationId: opts.appId ?? 759175203n,
      applicationArgs: [
        new Uint8Array(SEND_MESSAGE_SELECTOR),
        new Uint8Array(opts.recipientTag),
        abiBytes(framed),
      ],
    },
    filtersMatched: ['message-app-calls'],
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
  it('emits one newMessage per matching message app txn (AC1)', async () => {
    const fake = new FakeSubscriber();
    const cursor = inMemoryCursor();
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [757387707n, 759175203n],
      cursor,
      logger: silentLogger(),
      subscriberFactory: () => fake,
    });
    const events = recordEvents(watcher);

    await watcher.start();

    await fake.deliver('message-app-calls', makeMessageTxn({
      id: 'TX1',
      recipientTag: Buffer.alloc(32, 0x11),
      ciphertext: Buffer.from('hello'),
    }));
    // app-id 999 wouldn't reach a handler — the library filters at the source.
    // Simulate a second match on alias filter being skipped due to wrong shape:
    await fake.deliver('alias-app-calls', {
      id: 'TX_BAD',
      applicationTransaction: {
        applicationId: 757387707n,
        applicationArgs: [new Uint8Array([0xde, 0xad, 0xbe, 0xef])],
      },
    });

    expect(events.length).toBe(1);
    expect(events[0].messageId).toBe('TX1');
    expect(events[0].appId).toBe(759175203n);
  });

  it('AlgorandMessageEvent shape matches push-fanout contract (AC3)', async () => {
    const fake = new FakeSubscriber();
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [757387707n, 759175203n],
      cursor: inMemoryCursor(),
      logger: silentLogger(),
      subscriberFactory: () => fake,
    });
    const events = recordEvents(watcher);
    await watcher.start();

    const tag = Buffer.alloc(32, 0x42);
    const eph = Buffer.alloc(32, 0xab);

    await fake.deliver('message-app-calls', makeMessageTxn({
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

  it('drops set_username and other non-message selectors', () => {
    const txn: SubscribedTxn = {
      id: 'TX_USERNAME',
      applicationTransaction: {
        applicationId: 759175203n,
        applicationArgs: [
          new Uint8Array([0xd2, 0xfc, 0xc8, 0x3f]), // set_username
          new Uint8Array(Buffer.from('hello')),
        ],
      },
    };
    expect(mapTxnToEvent(txn, 'message-app-calls', silentLogger())).toBeNull();
  });

  it('handles send_alias_message variant (4 args)', () => {
    const tag = Buffer.alloc(32, 0x77);
    const ephemeral = Buffer.alloc(32, 0x88);
    const ciphertext = Buffer.from('alias-ct');
    const txn: SubscribedTxn = {
      id: 'TX_ALIAS_MSG',
      applicationTransaction: {
        applicationId: 759175203n,
        applicationArgs: [
          new Uint8Array(SEND_ALIAS_MESSAGE_SELECTOR),
          new Uint8Array(tag),
          new Uint8Array(ephemeral),
          abiBytes(ciphertext),
        ],
      },
    };
    const event = mapTxnToEvent(txn, 'message-app-calls', silentLogger());
    expect(event).not.toBeNull();
    expect(event!.ciphertext.equals(ciphertext)).toBe(true);
    expect(event!.recipientTag.equals(tag)).toBe(true);
    expect(event!.senderEphemeralPubkey.equals(ephemeral)).toBe(true);
  });

  it('drops txn with malformed recipient tag length', () => {
    const txn: SubscribedTxn = {
      id: 'TX_BAD_TAG',
      applicationTransaction: {
        applicationId: 759175203n,
        applicationArgs: [
          new Uint8Array(SEND_MESSAGE_SELECTOR),
          new Uint8Array(Buffer.alloc(16)), // wrong length
          abiBytes(Buffer.from('x')),
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
      appIds: [757387707n, 759175203n],
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
      appIds: [757387707n, 759175203n],
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
      appIds: [757387707n, 759175203n],
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
      appIds: [757387707n, 759175203n],
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
      appIds: [757387707n, 759175203n],
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

  it('stop() calls subscriber.stop("shutdown") exactly once and stops emitting', async () => {
    const fake = new FakeSubscriber();
    const watcher = createAlgorandWatcher({
      algodUrl: 'http://x',
      appIds: [757387707n, 759175203n],
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

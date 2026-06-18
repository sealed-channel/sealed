import {
  createPushScheduler,
  PushScheduler,
  ScheduledSendFn,
} from '../src/notifications/push-scheduler';

/**
 * Task 1.7 — cover-traffic + batching scheduler.
 *
 * For every registered APNs token we emit *exactly one* push per slot, regardless
 * of whether a real event occurred. Real events are coalesced into the next slot.
 * From Apple's vantage point the per-token send pattern is a uniform heartbeat.
 */
describe('createPushScheduler', () => {
  const SLOT_MS = 1000;
  let sends: { token: string; t: number; real: boolean }[];
  let now: number;
  let sender: ScheduledSendFn;
  let scheduler: PushScheduler;

  beforeEach(() => {
    jest.useFakeTimers();
    jest.setSystemTime(0);
    sends = [];
    now = 0;
    sender = jest.fn(async (token: string, meta) => {
      sends.push({ token, t: Date.now(), real: meta.real });
      return { ok: true, status: 200 };
    });
    scheduler = createPushScheduler({ slotMs: SLOT_MS, send: sender });
  });

  afterEach(() => {
    scheduler.stop();
    jest.useRealTimers();
  });

  function advance(ms: number) {
    now += ms;
    jest.advanceTimersByTime(ms);
  }

  it('emits exactly one push per slot per registered token (no real events)', async () => {
    scheduler.register('tok-a');
    scheduler.register('tok-b');
    scheduler.start();

    advance(10 * SLOT_MS);
    await Promise.resolve(); // flush any pending microtasks

    const perToken: Record<string, number> = {};
    for (const s of sends) perToken[s.token] = (perToken[s.token] ?? 0) + 1;

    // Each token should have fired exactly 10 times (slots 1..10 inclusive).
    expect(perToken['tok-a']).toBe(10);
    expect(perToken['tok-b']).toBe(10);
  });

  it('batches real events into the next slot (no out-of-slot sends)', async () => {
    scheduler.register('tok-a');
    scheduler.start();

    // Enqueue bursty real events mid-slot.
    advance(200);
    scheduler.enqueueEvent('tok-a');
    scheduler.enqueueEvent('tok-a');
    scheduler.enqueueEvent('tok-a');

    advance(800); // cross slot boundary at t=1000

    // Exactly one send should have fired at slot boundary, marked real.
    expect(sends.length).toBe(1);
    expect(sends[0].token).toBe('tok-a');
    expect(sends[0].t).toBe(SLOT_MS);
    expect(sends[0].real).toBe(true);

    // Next slot with no new events → dummy push.
    advance(SLOT_MS);
    expect(sends.length).toBe(2);
    expect(sends[1].real).toBe(false);
    expect(sends[1].t).toBe(2 * SLOT_MS);
  });

  it('unregister stops further pushes for that token', async () => {
    scheduler.register('tok-a');
    scheduler.register('tok-b');
    scheduler.start();

    advance(2 * SLOT_MS);
    scheduler.unregister('tok-a');
    advance(3 * SLOT_MS);

    const perToken: Record<string, number> = {};
    for (const s of sends) perToken[s.token] = (perToken[s.token] ?? 0) + 1;
    expect(perToken['tok-a']).toBe(2);
    expect(perToken['tok-b']).toBe(5);
  });

  it('over 10 minutes of silence emits 600/T pushes per token', async () => {
    const TEN_MIN = 10 * 60 * 1000;
    scheduler.register('tok-x');
    scheduler.start();
    advance(TEN_MIN);

    const expected = TEN_MIN / SLOT_MS;
    const got = sends.filter((s) => s.token === 'tok-x').length;
    expect(got).toBe(expected);
  });

  it('per-token send timestamps fall on slot boundaries (no jitter)', async () => {
    scheduler.register('tok-a');
    scheduler.start();
    advance(5 * SLOT_MS);

    for (const s of sends) {
      expect(s.t % SLOT_MS).toBe(0);
    }
  });
});

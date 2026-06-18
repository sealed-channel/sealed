/**
 * Unit tests for the stall watchdog (src/chain/stall-watchdog.ts).
 *
 * Regression target: watchers wedging silently after ~18-24h in production.
 * The algokit subscriber poll loop can hang in a never-settling fetch without
 * emitting an error, so the error re-arm path never runs. The watchdog must
 * (1) rebuild the subscriber when the watermark stops advancing and
 * (2) give up — once — after N rebuilds without progress, so the host
 * process can exit and let docker restart the container.
 */

import { createStallWatchdog } from '../src/chain/stall-watchdog';

function silentLogger() {
  const fn = jest.fn();
  return { info: fn, debug: fn, warn: fn, error: fn, fatal: fn, trace: fn, child: () => silentLogger() } as any;
}

const THRESHOLD = 1000;
const CHECK = 100;

describe('stall watchdog', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  function make(overrides: Partial<Parameters<typeof createStallWatchdog>[0]> = {}) {
    const rebuild = jest.fn().mockResolvedValue(undefined);
    const onGiveUp = jest.fn();
    const dog = createStallWatchdog({
      name: 'test-watcher',
      logger: silentLogger(),
      stallThresholdMs: THRESHOLD,
      checkIntervalMs: CHECK,
      maxRebuilds: 3,
      rebuild,
      onGiveUp,
      ...overrides,
    });
    return { dog, rebuild, onGiveUp };
  }

  it('rebuilds when the watermark stops advancing past the threshold', async () => {
    const { dog, rebuild } = make();
    dog.start();
    await jest.advanceTimersByTimeAsync(THRESHOLD + CHECK * 2);
    expect(rebuild).toHaveBeenCalledTimes(1);
    dog.stop();
  });

  it('does not rebuild while progress keeps arriving', async () => {
    const { dog, rebuild } = make();
    dog.start();
    for (let i = 0; i < 30; i++) {
      await jest.advanceTimersByTimeAsync(CHECK);
      dog.recordProgress();
    }
    expect(rebuild).not.toHaveBeenCalled();
    dog.stop();
  });

  it('gives up exactly once after maxRebuilds consecutive silent stalls', async () => {
    const { dog, rebuild, onGiveUp } = make();
    dog.start();
    // Each stall window triggers one rebuild; no progress in between.
    await jest.advanceTimersByTimeAsync((THRESHOLD + CHECK * 2) * 5);
    expect(rebuild).toHaveBeenCalledTimes(3);
    expect(onGiveUp).toHaveBeenCalledTimes(1);
    // Further time passes — still no extra give-up or rebuilds.
    await jest.advanceTimersByTimeAsync(THRESHOLD * 3);
    expect(onGiveUp).toHaveBeenCalledTimes(1);
    expect(rebuild).toHaveBeenCalledTimes(3);
    dog.stop();
  });

  it('progress after a rebuild resets the escalation counter', async () => {
    const { dog, rebuild, onGiveUp } = make();
    dog.start();
    await jest.advanceTimersByTimeAsync(THRESHOLD + CHECK * 2);
    expect(rebuild).toHaveBeenCalledTimes(1);
    expect(dog.status().consecutiveRebuilds).toBe(1);

    dog.recordProgress();
    expect(dog.status().consecutiveRebuilds).toBe(0);

    // A later stall starts the ladder from scratch — no premature give-up.
    await jest.advanceTimersByTimeAsync((THRESHOLD + CHECK * 2) * 2);
    expect(onGiveUp).not.toHaveBeenCalled();
    dog.stop();
  });

  it('a hanging rebuild does not stack concurrent rebuilds', async () => {
    let resolveRebuild: () => void = () => {};
    const rebuild = jest.fn(
      () => new Promise<void>((resolve) => (resolveRebuild = resolve)),
    );
    const { dog, onGiveUp } = make({ rebuild });
    dog.start();
    await jest.advanceTimersByTimeAsync(THRESHOLD + CHECK * 5);
    expect(rebuild).toHaveBeenCalledTimes(1);
    resolveRebuild();
    await jest.advanceTimersByTimeAsync(0);
    expect(onGiveUp).not.toHaveBeenCalled();
    dog.stop();
  });

  it('stop() halts checking', async () => {
    const { dog, rebuild } = make();
    dog.start();
    dog.stop();
    await jest.advanceTimersByTimeAsync(THRESHOLD * 5);
    expect(rebuild).not.toHaveBeenCalled();
  });
});

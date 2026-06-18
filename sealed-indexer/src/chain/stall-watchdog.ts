/**
 * Stall watchdog for chain watchers.
 *
 * The algokit subscriber's poll loop can wedge WITHOUT emitting an error:
 * the wait-for-block long-poll (`statusAfterBlock`) and the in-poll algod
 * fetches run on Node's global fetch with no request timeout, so a half-open
 * TCP connection (NAT/conntrack mapping dropped without RST, LB idle reap)
 * leaves the loop awaiting a promise that never settles. `onError` never
 * fires, the error re-arm path never runs, and the watcher is silently dead
 * until the process is restarted.
 *
 * Re-arming via `subscriber.start()` is also not enough when the wedge lives
 * in the algod HTTP client's socket pool — the same client is reused. The
 * only reliable recovery is to rebuild the subscriber (and with it a fresh
 * algod client / socket pool).
 *
 * This watchdog watches watermark progress (every successful poll persists
 * the watermark, and Algorand rounds advance ~every 3s, so at tip progress is
 * continuous) and escalates:
 *
 *   1. No progress for `stallThresholdMs`  → call `rebuild()` (caller tears
 *      down the old subscriber and builds a fresh one).
 *   2. `maxRebuilds` consecutive rebuilds with no progress in between
 *      → call `onGiveUp()` once. The process-level wiring (index.ts) maps
 *      this to a fatal log + process.exit(1) so the container supervisor
 *      (`restart: unless-stopped`) recreates the whole process — the same
 *      remedy as a manual `docker compose restart`, automated.
 *
 * Thresholds are generous on purpose: a legitimate 1000-round backfill poll
 * persists its watermark at the end of each poll, and even on a Pi over WAN
 * a single poll finishes well under the 10-minute default.
 */

import type { Logger } from 'pino';

export interface StallWatchdogOptions {
  /** Name used in log lines, e.g. 'msg-watcher'. */
  readonly name: string;
  readonly logger: Logger;
  /** No watermark progress for this long → rebuild. Default 10 min. */
  readonly stallThresholdMs?: number;
  /** How often to check for staleness. Default 30s. */
  readonly checkIntervalMs?: number;
  /** Consecutive no-progress rebuilds before giving up. Default 3. */
  readonly maxRebuilds?: number;
  /** Tear down the wedged subscriber and start a fresh one. */
  rebuild(): Promise<void>;
  /** Last resort — typically wired to a fatal exit by the host process. */
  onGiveUp(): void;
}

export interface StallWatchdog {
  /** Call on every watermark persist (i.e. every successful poll). */
  recordProgress(): void;
  start(): void;
  stop(): void;
  /** Introspection for health endpoints / tests. */
  status(): { lastProgressAt: number; consecutiveRebuilds: number };
}

const DEFAULT_STALL_THRESHOLD_MS = 10 * 60 * 1000;
const DEFAULT_CHECK_INTERVAL_MS = 30 * 1000;
const DEFAULT_MAX_REBUILDS = 3;

export function createStallWatchdog(opts: StallWatchdogOptions): StallWatchdog {
  const {
    name,
    logger,
    stallThresholdMs = DEFAULT_STALL_THRESHOLD_MS,
    checkIntervalMs = DEFAULT_CHECK_INTERVAL_MS,
    maxRebuilds = DEFAULT_MAX_REBUILDS,
    rebuild,
    onGiveUp,
  } = opts;

  let lastProgressAt = 0;
  let consecutiveRebuilds = 0;
  let timer: NodeJS.Timeout | null = null;
  let rebuilding = false;
  let gaveUp = false;

  async function check(): Promise<void> {
    if (rebuilding || gaveUp) return;
    const stalledForMs = Date.now() - lastProgressAt;
    if (stalledForMs <= stallThresholdMs) return;

    if (consecutiveRebuilds >= maxRebuilds) {
      gaveUp = true;
      logger.error(
        { watcher: name, stalledForMs, consecutiveRebuilds },
        'stall-watchdog: rebuilds exhausted without progress — giving up',
      );
      onGiveUp();
      return;
    }

    rebuilding = true;
    consecutiveRebuilds += 1;
    logger.warn(
      { watcher: name, stalledForMs, attempt: consecutiveRebuilds, maxRebuilds },
      'stall-watchdog: no watermark progress — rebuilding subscriber',
    );
    try {
      await rebuild();
      // Fresh window for the new subscriber; consecutiveRebuilds only resets
      // on real progress so repeated silent stalls still escalate.
      lastProgressAt = Date.now();
    } catch (err) {
      logger.error({ err, watcher: name }, 'stall-watchdog: rebuild failed');
    } finally {
      rebuilding = false;
    }
  }

  return {
    recordProgress(): void {
      lastProgressAt = Date.now();
      consecutiveRebuilds = 0;
    },
    start(): void {
      if (timer) return;
      lastProgressAt = Date.now();
      timer = setInterval(() => void check(), checkIntervalMs);
      timer.unref?.();
    },
    stop(): void {
      if (timer) clearInterval(timer);
      timer = null;
    },
    status() {
      return { lastProgressAt, consecutiveRebuilds };
    },
  };
}

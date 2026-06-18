/**
 * Task 1.7 — cover-traffic + batching push scheduler.
 *
 * Privacy goal: deny Apple the "user X just received a message at time T"
 * side channel. The scheduler emits exactly one silent-APNs push per slot
 * per registered device token. Real Algorand events are coalesced into the
 * next slot; if there are no real events the scheduler sends a dummy push
 * of indistinguishable shape. From Apple's observation point, every
 * registered device sees a uniform heartbeat.
 *
 * The actual byte-for-byte payload constancy is enforced by the sender
 * (see ohttp-apns.ts, Task 1.6) — this module is timing-only.
 */

export interface ScheduledSendMeta {
  /** True if at least one real event was queued for this token in this slot. */
  real: boolean;
}

export type ScheduledSendFn = (
  token: string,
  meta: ScheduledSendMeta
) => Promise<{ ok: boolean; status: number }>;

export interface PushScheduler {
  register(token: string): void;
  unregister(token: string): void;
  enqueueEvent(token: string): void;
  start(): void;
  stop(): void;
}

export interface PushSchedulerOptions {
  /** Slot interval in milliseconds. Apple's push budget must be respected; 30_000–60_000 is a reasonable production range. */
  slotMs: number;
  send: ScheduledSendFn;
}

export function createPushScheduler(opts: PushSchedulerOptions): PushScheduler {
  const { slotMs, send } = opts;

  const tokens = new Set<string>();
  const pendingReal = new Set<string>();
  let timer: NodeJS.Timeout | null = null;

  async function tick() {
    // Snapshot the set so unregister() during iteration is safe.
    const snapshot = Array.from(tokens);
    for (const token of snapshot) {
      const real = pendingReal.delete(token);
      // Fire-and-forget; the sender returns a promise but scheduling does
      // not gate on delivery — the next slot runs regardless.
      void send(token, { real });
    }
  }

  return {
    register(token: string) {
      tokens.add(token);
    },

    unregister(token: string) {
      tokens.delete(token);
      pendingReal.delete(token);
    },

    enqueueEvent(token: string) {
      if (tokens.has(token)) {
        pendingReal.add(token);
      }
    },

    start() {
      if (timer) return;
      timer = setInterval(tick, slotMs);
    },

    stop() {
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
    },
  };
}

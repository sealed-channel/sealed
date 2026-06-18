/**
 * On-chain `postRoot` watcher.
 *
 * Subscribes to the unified Sealed app and ingests `postRoot(byte[32],uint64)`
 * calls into the local roots registry (SPEC-snark-redeem-B §4 + §6 / Task 6).
 *
 * Uses its own cursor row so a roots-only backfill rewind does not replay
 * unrelated message-event push notifications.
 *
 * Logging discipline: counts + rounds + truncated root prefixes only — we
 * never log full root bytes, admin identity, or anything user-correlatable.
 */

import { EventEmitter } from 'events';
import type { Logger } from 'pino';
import type { CursorStore } from '../notifications/cursor-store';
import type { RootsStore } from './roots-store';
import {
  createChainSubscription,
  type AbiCallSchema,
  type ChainSubscription,
  type DecodedAbiCall,
  type SubscribedTxn,
} from '../chain/chain-subscription';

// Selector = sha512/256("postRoot(byte[32],uint64)void")[0..4] = 0x3141f410.
const POST_ROOT_SELECTOR = Buffer.from([0x31, 0x41, 0xf4, 0x10]);
const POST_ROOT_METHOD = 'postRoot(byte[32],uint64)void';

const POST_ROOT_SCHEMA = {
  selector: POST_ROOT_SELECTOR,
  args: {
    root: { kind: 'fixedBytes' as const, len: 32 },
    denomination: { kind: 'fixedBytes' as const, len: 8 },
  },
  // postRoot logs ARC28 events, not a sender prefix. Skip sender-log check.
  requireSenderLog: false,
} satisfies AbiCallSchema<{
  root: { kind: 'fixedBytes'; len: number };
  denomination: { kind: 'fixedBytes'; len: number };
}>;

export interface RootsWatcherOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  readonly sealedAppId: bigint;
  readonly cursor: CursorStore;
  readonly store: RootsStore;
  readonly startRound?: bigint;
  readonly logger: Logger;
  /** Test seam — same shape as chain-subscription. */
  readonly subscriberFactory?: Parameters<typeof createChainSubscription>[0]['subscriberFactory'];
}

export type RootsWatcher = ChainSubscription;

/** Big-endian 8-byte → JS number (uint64; safe up to 2^53−1 for denom). */
function readUint64BE(b: Uint8Array): number {
  const buf = Buffer.from(b);
  const hi = buf.readUInt32BE(0);
  const lo = buf.readUInt32BE(4);
  // Denominations live in the cs base-unit space (well under 2^53).
  return hi * 0x1_0000_0000 + lo;
}

function bytesToHex(b: Uint8Array): string {
  return Buffer.from(b).toString('hex');
}

export function createRootsWatcher(opts: RootsWatcherOptions): RootsWatcher {
  const { logger, store, sealedAppId, ...rest } = opts;

  const filter = {
    name: 'post-root-calls',
    methodSignature: POST_ROOT_METHOD,
    schema: POST_ROOT_SCHEMA,
    onDecoded: (
      decoded: DecodedAbiCall<typeof POST_ROOT_SCHEMA.args>,
      txn: SubscribedTxn,
    ) => {
      const root = bytesToHex(decoded.args.root);
      const denomination = readUint64BE(decoded.args.denomination);
      const postedRound = Number(decoded.confirmedRound ?? 0n);
      if (denomination <= 0 || postedRound <= 0) {
        // Mirrors the on-chain assertion (denom > 0). Defensive; the contract
        // already rejects these so we should never see them in practice.
        logger.warn(
          { rootPrefix: root.slice(0, 8), denomination, postedRound },
          'roots-watcher: ignoring postRoot with non-positive denom/round',
        );
        return;
      }
      try {
        store.upsertRoot({ root, denomination, postedRound });
      } catch (err) {
        logger.error(
          { err, rootPrefix: root.slice(0, 8), txId: txn.id },
          'roots-watcher: failed to persist root',
        );
        return;
      }
      logger.info(
        {
          rootPrefix: root.slice(0, 8),
          denomination,
          postedRound,
        },
        'roots-watcher: ingested postRoot',
      );
    },
  };

  const sub: ChainSubscription = createChainSubscription({
    algodUrl: rest.algodUrl,
    algodToken: rest.algodToken,
    appId: sealedAppId,
    cursor: rest.cursor,
    startRound: rest.startRound,
    logger,
    filters: [filter],
    subscriberFactory: opts.subscriberFactory,
  });

  return sub;
}

// Exported for tests + external callers that want to verify selector / schema.
export const POST_ROOT_METHOD_SIGNATURE = POST_ROOT_METHOD;
export { POST_ROOT_SELECTOR, POST_ROOT_SCHEMA };

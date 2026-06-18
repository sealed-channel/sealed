/**
 * On-chain user-directory watcher — unified Sealed app (app ID 762153589).
 *
 * Watches five ABI methods on the unified Sealed contract:
 *   claimUsername(byte[])void        selector 0x27343994
 *   publishKeys(byte[32],byte[32],byte[])void  selector 0xe28c0434
 *   releaseUsername()void            selector 0xec03af64
 *   redeemAndPublish(byte[],byte[32],byte[32],byte[])void  selector 0xcd60ea68
 *   setBio(byte[])void               selector 0xf428f47a
 *
 * Uses its OWN cursor row ('user_cursor') so backfill rewinds do not replay
 * message-event notifications from the main watcher.
 *
 * claimUsername and publishKeys are independent txns; the store handles
 * partial rows (either column-set may arrive first). releaseUsername nulls
 * the username column.
 */

import { EventEmitter } from 'events';
import type { Logger } from 'pino';
import type { CursorStore } from '../notifications/cursor-store';
import type { UserDirectoryStore } from './user-store';
import {
  createChainSubscription,
  decodeAbiCall,
  type AbiCallSchema,
  type ChainSubscription,
  type DecodedAbiCall,
  type SubscribedTxn,
  type SubscriberFactoryConfig,
  type SubscriberLike,
} from '../chain/chain-subscription';

export type { SubscribedTxn, SubscriberLike };

/** Test-shim alias kept for backward compat with existing tests. */
export interface SubscriberFactoryConfig_Legacy {
  algodUrl: string;
  algodToken: string;
  messageAppId: bigint;
  cursor: CursorStore;
  startRound?: bigint;
  frequencyInSeconds: number;
}

// ---------------------------------------------------------------------------
// claimUsername(byte[])void  —  selector sha512/256("claimUsername(byte[])void")[0..4]
// ---------------------------------------------------------------------------
const CLAIM_USERNAME_SELECTOR = Buffer.from([0x27, 0x34, 0x39, 0x94]);
const CLAIM_USERNAME_METHOD = 'claimUsername(byte[])void';

const CLAIM_USERNAME_SCHEMA = {
  selector: CLAIM_USERNAME_SELECTOR,
  args: {
    username: { kind: 'dynBytes' as const, minLen: 1, maxLen: 64 },
  },
  requireSenderLog: true,
} satisfies AbiCallSchema<{
  username: { kind: 'dynBytes'; minLen: number; maxLen: number };
}>;

// ---------------------------------------------------------------------------
// publishKeys(byte[32],byte[32],byte[])void  —  selector 0xe28c0434
// ---------------------------------------------------------------------------
const PUBLISH_KEYS_SELECTOR = Buffer.from([0xe2, 0x8c, 0x04, 0x34]);
const PUBLISH_KEYS_METHOD = 'publishKeys(byte[32],byte[32],byte[])void';

const PUBLISH_KEYS_SCHEMA = {
  selector: PUBLISH_KEYS_SELECTOR,
  args: {
    encryptionPubkey: { kind: 'fixedBytes' as const, len: 32 },
    scanPubkey: { kind: 'fixedBytes' as const, len: 32 },
    pqPubkey: { kind: 'dynBytes' as const, minLen: 32, maxLen: 2048 },
  },
  requireSenderLog: true,
} satisfies AbiCallSchema<{
  encryptionPubkey: { kind: 'fixedBytes'; len: number };
  scanPubkey: { kind: 'fixedBytes'; len: number };
  pqPubkey: { kind: 'dynBytes'; minLen: number; maxLen: number };
}>;

// ---------------------------------------------------------------------------
// releaseUsername()void  —  selector 0xec03af64
// ---------------------------------------------------------------------------
const RELEASE_USERNAME_SELECTOR = Buffer.from([0xec, 0x03, 0xaf, 0x64]);
const RELEASE_USERNAME_METHOD = 'releaseUsername()void';

const RELEASE_USERNAME_SCHEMA = {
  selector: RELEASE_USERNAME_SELECTOR,
  args: {},
  requireSenderLog: false,
} satisfies AbiCallSchema<Record<string, never>>;

// ---------------------------------------------------------------------------
// redeemAndPublish(byte[],byte[32],byte[32],byte[])void  —  selector 0xcd60ea68
// ---------------------------------------------------------------------------
const REDEEM_AND_PUBLISH_SELECTOR = Buffer.from([0xcd, 0x60, 0xea, 0x68]);
const REDEEM_AND_PUBLISH_METHOD = 'redeemAndPublish(byte[],byte[32],byte[32],byte[])void';

const REDEEM_AND_PUBLISH_SCHEMA = {
  selector: REDEEM_AND_PUBLISH_SELECTOR,
  args: {
    preimage: { kind: 'dynBytes' as const, minLen: 16, maxLen: 16 },
    encryptionPubkey: { kind: 'fixedBytes' as const, len: 32 },
    scanPubkey: { kind: 'fixedBytes' as const, len: 32 },
    pqPubkey: { kind: 'dynBytes' as const, minLen: 32, maxLen: 2048 },
  },
  requireSenderLog: true,
} satisfies AbiCallSchema<{
  preimage: { kind: 'dynBytes'; minLen: number; maxLen: number };
  encryptionPubkey: { kind: 'fixedBytes'; len: number };
  scanPubkey: { kind: 'fixedBytes'; len: number };
  pqPubkey: { kind: 'dynBytes'; minLen: number; maxLen: number };
}>;

// ---------------------------------------------------------------------------
// setBio(byte[])void  —  selector sha512/256("setBio(byte[])void")[0..4]
// ---------------------------------------------------------------------------
const SET_BIO_SELECTOR = Buffer.from([0xf4, 0x28, 0xf4, 0x7a]);
const SET_BIO_METHOD = 'setBio(byte[])void';

/** Mirrors contract BIO_MAX — bytes of UTF-8. Empty arg = clear. */
const BIO_MAX_BYTES = 160;

const SET_BIO_SCHEMA = {
  selector: SET_BIO_SELECTOR,
  args: {
    bio: { kind: 'dynBytes' as const, minLen: 0, maxLen: BIO_MAX_BYTES },
  },
  requireSenderLog: true,
} satisfies AbiCallSchema<{
  bio: { kind: 'dynBytes'; minLen: number; maxLen: number };
}>;

// ---------------------------------------------------------------------------

export interface UserWatcherOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  /** Unified Sealed app id. */
  readonly messageAppId: bigint;
  readonly cursor: CursorStore;
  readonly store: UserDirectoryStore;
  readonly startRound?: bigint;
  readonly pollIntervalMs?: number;
  readonly logger: Logger;
  /** Test-only seam: inject a pre-built subscriber. */
  readonly subscriberFactory?: (config: SubscriberFactoryConfig_Legacy) => SubscriberLike;
}

export interface UserWatcher extends EventEmitter {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export function createUserWatcher(opts: UserWatcherOptions): UserWatcher {
  const { logger, store, subscriberFactory, ...rest } = opts;

  const claimFilter = {
    name: 'claim-username-calls',
    methodSignature: CLAIM_USERNAME_METHOD,
    schema: CLAIM_USERNAME_SCHEMA,
    onDecoded: (decoded: DecodedAbiCall<typeof CLAIM_USERNAME_SCHEMA.args>, txn: SubscribedTxn) => {
      let username: string;
      try {
        username = new TextDecoder('utf-8', { fatal: true }).decode(decoded.args.username);
      } catch {
        logger.debug({ txId: decoded.txId }, 'user-watcher: skipping non-utf8 username in claimUsername');
        return;
      }
      if (!username) return;
      const observedAt = decoded.roundTime ? decoded.roundTime * 1000 : Date.now();
      store.upsertUsername(decoded.sender, username, observedAt);
      // eslint-disable-next-line no-console
      console.log(
        `[user-watcher] ✅ CLAIMED username="${username}" owner=${decoded.sender} round=${txn.confirmedRound?.toString() ?? '?'} txId=${txn.id}`,
      );
      logger.info(
        { owner: decoded.sender, username, round: txn.confirmedRound?.toString(), txId: txn.id },
        'user-watcher: upserted username from claimUsername',
      );
    },
  };

  const publishKeysFilter = {
    name: 'publish-keys-calls',
    methodSignature: PUBLISH_KEYS_METHOD,
    schema: PUBLISH_KEYS_SCHEMA,
    onDecoded: (decoded: DecodedAbiCall<typeof PUBLISH_KEYS_SCHEMA.args>, txn: SubscribedTxn) => {
      const encPubkey = Buffer.from(decoded.args.encryptionPubkey);
      const scanPubkey = Buffer.from(decoded.args.scanPubkey);
      const pqPubkey = Buffer.from(decoded.args.pqPubkey);
      const observedAt = decoded.roundTime ? decoded.roundTime * 1000 : Date.now();
      const pqPublishedRound = decoded.confirmedRound ? Number(decoded.confirmedRound) : null;
      store.upsertKeys(decoded.sender, encPubkey, scanPubkey, pqPubkey, pqPublishedRound, observedAt);
      // eslint-disable-next-line no-console
      console.log(
        `[user-watcher] 🔑 PUBLISHED KEYS owner=${decoded.sender} round=${txn.confirmedRound?.toString() ?? '?'} txId=${txn.id}`,
      );
      logger.info(
        { owner: decoded.sender, round: txn.confirmedRound?.toString(), txId: txn.id },
        'user-watcher: upserted keys from publishKeys',
      );
    },
  };

  const releaseFilter = {
    name: 'release-username-calls',
    methodSignature: RELEASE_USERNAME_METHOD,
    schema: RELEASE_USERNAME_SCHEMA,
    onDecoded: (decoded: DecodedAbiCall<typeof RELEASE_USERNAME_SCHEMA.args>, txn: SubscribedTxn) => {
      const observedAt = decoded.roundTime ? decoded.roundTime * 1000 : Date.now();
      store.clearUsername(decoded.sender, observedAt);
      // eslint-disable-next-line no-console
      console.log(
        `[user-watcher] 🗑️ RELEASED username owner=${decoded.sender} round=${txn.confirmedRound?.toString() ?? '?'} txId=${txn.id}`,
      );
      logger.info(
        { owner: decoded.sender, round: txn.confirmedRound?.toString(), txId: txn.id },
        'user-watcher: cleared username from releaseUsername',
      );
    },
  };

  const redeemAndPublishFilter = {
    name: 'redeem-and-publish-calls',
    methodSignature: REDEEM_AND_PUBLISH_METHOD,
    schema: REDEEM_AND_PUBLISH_SCHEMA,
    onDecoded: (decoded: DecodedAbiCall<typeof REDEEM_AND_PUBLISH_SCHEMA.args>, txn: SubscribedTxn) => {
      const encPubkey = Buffer.from(decoded.args.encryptionPubkey);
      const scanPubkey = Buffer.from(decoded.args.scanPubkey);
      const pqPubkey = Buffer.from(decoded.args.pqPubkey);
      const observedAt = decoded.roundTime ? decoded.roundTime * 1000 : Date.now();
      const pqPublishedRound = decoded.confirmedRound ? Number(decoded.confirmedRound) : null;
      store.upsertKeys(decoded.sender, encPubkey, scanPubkey, pqPubkey, pqPublishedRound, observedAt);
      // eslint-disable-next-line no-console
      console.log(
        `[user-watcher] 💰🔑 REDEEMED+PUBLISHED owner=${decoded.sender} round=${txn.confirmedRound?.toString() ?? '?'} txId=${txn.id}`,
      );
      logger.info(
        { owner: decoded.sender, round: txn.confirmedRound?.toString(), txId: txn.id },
        'user-watcher: upserted keys from redeemAndPublish',
      );
    },
  };

  const setBioFilter = {
    name: 'set-bio-calls',
    methodSignature: SET_BIO_METHOD,
    schema: SET_BIO_SCHEMA,
    onDecoded: (decoded: DecodedAbiCall<typeof SET_BIO_SCHEMA.args>, txn: SubscribedTxn) => {
      let bio: string;
      try {
        bio = new TextDecoder('utf-8', { fatal: true }).decode(decoded.args.bio);
      } catch {
        logger.debug({ txId: decoded.txId }, 'user-watcher: skipping non-utf8 bio in setBio');
        return;
      }
      const observedAt = decoded.roundTime ? decoded.roundTime * 1000 : Date.now();
      store.upsertBio(decoded.sender, bio.length > 0 ? bio : null, observedAt);
      // Deliberately no bio contents in logs — directory data, not a change feed.
      logger.info(
        { owner: decoded.sender, cleared: bio.length === 0, round: txn.confirmedRound?.toString(), txId: txn.id },
        'user-watcher: upserted bio from setBio',
      );
    },
  };

  const sub: ChainSubscription = createChainSubscription({
    algodUrl: rest.algodUrl,
    algodToken: rest.algodToken,
    appId: rest.messageAppId,
    cursor: rest.cursor,
    startRound: rest.startRound,
    logger,
    filters: [claimFilter, publishKeysFilter, releaseFilter, redeemAndPublishFilter, setBioFilter],
    subscriberFactory: subscriberFactory ? adaptLegacyFactory(subscriberFactory) : undefined,
  });

  return sub as UserWatcher;
}

function adaptLegacyFactory(
  legacy: (cfg: SubscriberFactoryConfig_Legacy) => SubscriberLike,
): (cfg: SubscriberFactoryConfig) => SubscriberLike {
  return (cfg) =>
    legacy({
      algodUrl: cfg.algodUrl,
      algodToken: cfg.algodToken ?? '',
      messageAppId: cfg.appId,
      cursor: cfg.cursor,
      startRound: cfg.startRound,
      frequencyInSeconds: cfg.frequencyInSeconds,
    });
}

// ---------------------------------------------------------------------------
// Exported decode helpers (kept for tests / external callers)
// ---------------------------------------------------------------------------

export interface DecodedClaimUsername {
  ownerPubkey: string;
  username: string;
  observedAt: number;
}

export function decodeClaimUsername(txn: SubscribedTxn, logger: Logger): DecodedClaimUsername | null {
  const decoded = decodeAbiCall(txn, CLAIM_USERNAME_SCHEMA, logger);
  if (!decoded) return null;
  let username: string;
  try {
    username = new TextDecoder('utf-8', { fatal: true }).decode(decoded.args.username);
  } catch {
    return null;
  }
  if (!username) return null;
  return {
    ownerPubkey: decoded.sender,
    username,
    observedAt: decoded.roundTime ? decoded.roundTime * 1000 : Date.now(),
  };
}

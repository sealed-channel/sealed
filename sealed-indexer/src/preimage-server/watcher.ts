/**
 * CommitmentsSold watcher.
 *
 * Subscribes to `purchaseCodes(uint64,byte[32])void` app-call txns on the
 * monetization-v1 contract. For each match:
 *
 *   1. Extract `deliveryPubkey` (X25519, 32B) from the call args.
 *   2. Find the txn log entry that decodes as a `CommitmentsSold` ARC28
 *      event; that gives us `commitments[]` and `purchasedAtRound`.
 *   3. Look up every commitment hash in sqlite. If any is missing, or any
 *      is not in `available` status, the whole purchase is skipped with a
 *      warning — partial deliveries are forbidden by design so that a
 *      buyer never sees a half-batch ciphertext.
 *   4. Seal `{ codes, purchasedAtRound }` for the buyer's `deliveryPubkey`
 *      using `crypto.sealForDelivery` (HPKE base mode). The same ciphertext
 *      bytes are written into every row's `c:` cell — `delivery_key_sha256`
 *      is the join key the delivery endpoint uses.
 *   5. Call `store.markSold` per commitment. The store's status guard
 *      makes the whole flow idempotent: replaying the event on watcher
 *      restart will see every row already `sold` and write nothing.
 *
 * The watcher does NOT mark rows `delivered` — that happens on the first
 * `GET /delivery/<hex>` fetch (separate slice).
 *
 * Cursor: a `watcher_checkpoint` row (managed by `PreimageStore`) carries
 * the last successfully processed round across restarts. A tiny private
 * adapter exposes it as the `CursorStore` shape `createChainSubscription`
 * expects.
 */

import { createHash } from 'node:crypto';
import { EventEmitter } from 'events';
import type { Logger } from 'pino';
import algosdk from 'algosdk';
import {
  createChainSubscription,
  type AbiCallSchema,
  type ChainSubscription,
  type ChainSubscriptionFilter,
  type DecodedAbiCall,
  type RawChainSubscriptionFilter,
  type SubscribedTxn,
  type SubscriberFactoryConfig,
  type SubscriberLike,
} from '../chain/chain-subscription';
import type { CursorStore } from '../notifications/cursor-store';
import { sealForDelivery, type DeliveryPayload } from './crypto';
import { parseCommitmentsSoldEvent, type CommitmentsSoldEvent } from './events';
import type { PreimageStore } from './db';
import { processPaymentDelivery, type PaymentTxn } from './payment-delivery';

const PURCHASE_CODES_METHOD = 'purchaseCodes(uint64,byte[32])void';

const PURCHASE_CODES_SELECTOR: Buffer = Buffer.from(
  new algosdk.ABIMethod({
    name: 'purchaseCodes',
    args: [
      { type: 'uint64', name: 'qty' },
      { type: 'byte[32]', name: 'deliveryPubkey' },
    ],
    returns: { type: 'void' },
  }).getSelector(),
);

const PURCHASE_CODES_SCHEMA = {
  selector: PURCHASE_CODES_SELECTOR,
  args: {
    qty: { kind: 'fixedBytes' as const, len: 8 },
    deliveryPubkey: { kind: 'fixedBytes' as const, len: 32 },
  },
  requireSenderLog: false,
} satisfies AbiCallSchema<{
  qty: { kind: 'fixedBytes'; len: number };
  deliveryPubkey: { kind: 'fixedBytes'; len: number };
}>;

export interface PreimageWatcherOptions {
  readonly algodUrl: string;
  readonly algodToken?: string;
  readonly appId: bigint;
  readonly store: PreimageStore;
  readonly logger: Logger;
  readonly startRound?: bigint;
  readonly pollIntervalMs?: number;
  readonly maxRoundsToSync?: number;
  /**
   * SNARK-sold: treasury (app account) address whose incoming payments
   * trigger delivery. When set together with `priceMicroAlgos`, a payment
   * watcher is added alongside the legacy `purchaseCodes` watcher.
   */
  readonly treasuryAddress?: string;
  /** Per-code price (µAlgos); required to derive qty from a payment amount. */
  readonly priceMicroAlgos?: bigint;
  /** Test-only: inject a SubscriberLike to drive synthetic txns. */
  readonly subscriberFactory?: (cfg: SubscriberFactoryConfig) => SubscriberLike;
}

export interface PreimageWatcher extends EventEmitter {
  start(): Promise<void>;
  stop(): Promise<void>;
}

function cursorFromStore(store: PreimageStore): CursorStore {
  // Reset is currently never called by chain-subscription during normal
  // operation; if a future path requires it, persist a sentinel.
  let resetSentinel = false;
  return {
    getRound: () => (resetSentinel ? null : store.getWatcherCheckpoint()),
    setRound: (r) => {
      resetSentinel = false;
      store.setWatcherCheckpoint(r);
    },
    reset: () => {
      resetSentinel = true;
    },
    close: () => {
      /* shared handle; closed by the owning store */
    },
  };
}

function sha256(bytes: Uint8Array): Uint8Array {
  return new Uint8Array(createHash('sha256').update(bytes).digest());
}

function findCommitmentsSoldEvent(
  txn: SubscribedTxn,
  logger: Logger,
): CommitmentsSoldEvent | null {
  const logs = txn.logs ?? [];
  for (const entry of logs) {
    const bytes = typeof entry === 'string' ? Buffer.from(entry, 'base64') : entry;
    const buf = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    const decoded = parseCommitmentsSoldEvent(buf);
    if (decoded) return decoded;
  }
  logger.warn({ txId: txn.id }, 'preimage-watcher: purchaseCodes txn with no CommitmentsSold event');
  return null;
}

interface CollectedRows {
  rows: { commitmentHash: Uint8Array; code: string }[];
}

/**
 * Look up every commitment in the event. Returns `null` (and logs why) if
 * ANY row is missing or not `available` — partial deliveries are by
 * design forbidden.
 */
function collectRowsForEvent(
  event: CommitmentsSoldEvent,
  store: PreimageStore,
  logger: Logger,
  txId: string,
): CollectedRows | null {
  const rows: CollectedRows['rows'] = [];
  for (const commitment of event.commitments) {
    const row = store.getByCommitment(commitment);
    if (!row) {
      logger.warn(
        { txId, commitmentPrefix: Buffer.from(commitment.subarray(0, 4)).toString('hex') },
        'preimage-watcher: commitment not found in store — skipping whole event',
      );
      return null;
    }
    if (row.status !== 'available') {
      logger.info(
        { txId, status: row.status },
        'preimage-watcher: commitment already past available — skipping whole event (idempotent)',
      );
      return null;
    }
    if (!row.code) {
      logger.error(
        { txId },
        'preimage-watcher: row has no code (data corruption) — skipping whole event',
      );
      return null;
    }
    rows.push({ commitmentHash: row.commitmentHash, code: row.code });
  }
  return { rows };
}

async function handlePurchaseCodesCall(
  decoded: DecodedAbiCall<typeof PURCHASE_CODES_SCHEMA.args>,
  txn: SubscribedTxn,
  store: PreimageStore,
  logger: Logger,
): Promise<void> {
  const deliveryPubkey = new Uint8Array(decoded.args.deliveryPubkey);

  const event = findCommitmentsSoldEvent(txn, logger);
  if (!event) return;

  // Defense in depth: the contract already binds deliveryPubkey to the
  // call args and emits the same bytes in the event. A mismatch would
  // mean either the watcher saw a stale event or the contract was
  // upgraded — refuse rather than guess which key to seal under.
  if (!Buffer.from(deliveryPubkey).equals(Buffer.from(event.deliveryPubkey))) {
    logger.warn(
      { txId: txn.id },
      'preimage-watcher: deliveryPubkey mismatch between call args and event — skipping',
    );
    return;
  }

  const collected = collectRowsForEvent(event, store, logger, txn.id);
  if (!collected) return;

  const payload: DeliveryPayload = {
    codes: collected.rows.map((r) => r.code),
    purchasedAtRound: event.purchasedAtRound,
  };
  const ciphertext = await sealForDelivery(payload, deliveryPubkey);
  const deliveryKeySha256 = sha256(deliveryPubkey);

  let updated = 0;
  for (const r of collected.rows) {
    const n = store.markSold({
      commitmentHash: r.commitmentHash,
      soldAtRound: event.purchasedAtRound,
      deliveryKeySha256,
      ciphertext,
    });
    updated += n;
  }

  logger.info(
    {
      txId: txn.id,
      buyer: event.buyer,
      purchasedAtRound: event.purchasedAtRound.toString(),
      commitments: collected.rows.length,
      updated,
    },
    'preimage-watcher: sealed delivery and stamped rows sold',
  );
}

function noteToBytes(note: Uint8Array | string | undefined): Uint8Array | null {
  if (note === undefined || note === null) return null;
  if (typeof note === 'string') {
    try {
      return new Uint8Array(Buffer.from(note, 'base64'));
    } catch {
      return null;
    }
  }
  return note instanceof Uint8Array ? note : new Uint8Array(note);
}

function extractPaymentTxn(txn: SubscribedTxn): PaymentTxn | null {
  const pay = txn.paymentTransaction;
  if (!pay) return null;
  return {
    txid: txn.id,
    sender: txn.sender,
    amountMicroAlgos: pay.amount === undefined ? 0n : BigInt(pay.amount),
    note: noteToBytes(txn.note),
    round: txn.confirmedRound ?? 0n,
  };
}

export function createPreimageWatcher(opts: PreimageWatcherOptions): PreimageWatcher {
  const { logger, store, subscriberFactory, treasuryAddress, priceMicroAlgos, ...rest } = opts;

  const filter: ChainSubscriptionFilter<typeof PURCHASE_CODES_SCHEMA.args> = {
    name: 'purchase-codes-calls',
    methodSignature: PURCHASE_CODES_METHOD,
    schema: PURCHASE_CODES_SCHEMA,
    onDecoded: (decoded, txn) =>
      handlePurchaseCodesCall(decoded, txn, store, logger).catch((err) => {
        logger.error(
          { err: err instanceof Error ? err.message : String(err), txId: txn.id },
          'preimage-watcher: handler threw',
        );
      }),
  };

  // SNARK-sold: when a treasury address + price are configured, watch plain
  // payments to the treasury and deliver a pre-generated SNARK code per
  // payment (decoupled from the on-chain sale pool).
  const rawFilters: RawChainSubscriptionFilter[] = [];
  if (treasuryAddress && priceMicroAlgos !== undefined) {
    const seal = (codes: string[], pub: Uint8Array, round: bigint): Promise<Uint8Array> =>
      sealForDelivery({ codes, purchasedAtRound: round }, pub);
    rawFilters.push({
      name: 'treasury-payments',
      algokitFilter: { type: algosdk.TransactionType.pay, receiver: treasuryAddress },
      onTxn: async (txn) => {
        const payment = extractPaymentTxn(txn);
        if (!payment) return;
        await processPaymentDelivery(payment, { store, priceMicroAlgos, seal, sha256, logger });
      },
    });
    logger.info({ treasuryAddress, priceMicroAlgos: priceMicroAlgos.toString() }, 'preimage-watcher: SNARK-sold payment watcher enabled');
  }

  const sub: ChainSubscription = createChainSubscription({
    algodUrl: rest.algodUrl,
    algodToken: rest.algodToken,
    appId: rest.appId,
    cursor: cursorFromStore(store),
    startRound: rest.startRound,
    frequencyInSeconds:
      rest.pollIntervalMs !== undefined ? Math.max(1, Math.round(rest.pollIntervalMs / 1000)) : undefined,
    maxRoundsToSync: rest.maxRoundsToSync,
    logger,
    filters: [filter],
    rawFilters,
    subscriberFactory,
  });

  return sub as PreimageWatcher;
}

export { PURCHASE_CODES_METHOD, PURCHASE_CODES_SELECTOR };

/**
 * SNARK-sold delivery handler.
 *
 * Decouples the paid top-up from the on-chain sale pool: the buyer sends a
 * plain payment to the treasury (the app account) carrying their 32-byte
 * delivery pubkey in the txn note. This handler turns one such payment into
 * a sealed code delivery, with the money-safety guards that matter:
 *
 *   - Idempotency: each `payment_txid` reserves inventory at most once
 *     (PRIMARY KEY on `payment_deliveries`). Replays recover the ciphertext
 *     rather than re-allocating codes.
 *   - Atomic reservation: `reserveAndPick` claims `qty` rows in one sqlite
 *     transaction; a shortfall rolls the whole claim back.
 *   - Exact pricing: `amount` must equal `price × qty` with `qty ≥ 1`.
 *   - No silent loss: bad note / bad amount / empty stock are recorded in
 *     `unfulfilled_payments` for MANUAL refund — we never keep the money and
 *     deliver nothing without a trace, and there is NO refund hot key here.
 *
 * The HPKE seal is async, so reservation (sync sqlite txn) happens first and
 * the ciphertext is written afterwards via `fillCiphertext`. A crash between
 * the two leaves rows `sold` with NULL ciphertext + the txid recorded; the
 * replay path re-seals from the still-present codes and fills it in.
 */

import type { Logger } from 'pino';
import {
  DuplicatePaymentError,
  InsufficientInventoryError,
  type PreimageStore,
} from './db';

export type PaymentDeliveryResult =
  | 'delivered'
  | 'duplicate'
  | 'recovered'
  | 'unfulfilled:bad_note'
  | 'unfulfilled:bad_amount'
  | 'unfulfilled:insufficient_inventory';

export interface PaymentTxn {
  txid: string;
  sender?: string;
  amountMicroAlgos: bigint;
  /** Raw txn note; expected to be exactly the 32-byte X25519 delivery pubkey. */
  note: Uint8Array | null;
  round: bigint;
}

export interface PaymentDeliveryDeps {
  store: PreimageStore;
  priceMicroAlgos: bigint;
  /** HPKE seal of the code list to the buyer's delivery pubkey. */
  seal: (codes: string[], deliveryPubkey: Uint8Array, round: bigint) => Promise<Uint8Array>;
  sha256: (bytes: Uint8Array) => Uint8Array;
  logger: Logger;
}

const DELIVERY_PUBKEY_LEN = 32;

export async function processPaymentDelivery(
  payment: PaymentTxn,
  deps: PaymentDeliveryDeps,
): Promise<PaymentDeliveryResult> {
  const { store, priceMicroAlgos, seal, sha256, logger } = deps;
  const { txid, sender, amountMicroAlgos, note, round } = payment;

  // 1. Note must be exactly the 32-byte delivery pubkey.
  if (!note || note.length !== DELIVERY_PUBKEY_LEN) {
    store.recordUnfulfilled({ paymentTxid: txid, sender, amount: amountMicroAlgos, reason: 'bad_note', round });
    logger.warn({ txId: txid, noteLen: note?.length ?? 0 }, 'payment-delivery: bad/absent note → unfulfilled');
    return 'unfulfilled:bad_note';
  }
  const deliveryPubkey = note;
  const deliveryKey = sha256(deliveryPubkey);

  // 2. Amount must be an exact multiple of price, qty ≥ 1.
  if (priceMicroAlgos <= 0n) throw new Error('priceMicroAlgos must be positive');
  if (amountMicroAlgos < priceMicroAlgos || amountMicroAlgos % priceMicroAlgos !== 0n) {
    store.recordUnfulfilled({ paymentTxid: txid, sender, amount: amountMicroAlgos, reason: 'bad_amount', round });
    logger.warn(
      { txId: txid, amount: amountMicroAlgos.toString(), price: priceMicroAlgos.toString() },
      'payment-delivery: amount not an exact multiple of price → unfulfilled',
    );
    return 'unfulfilled:bad_amount';
  }
  const qty = Number(amountMicroAlgos / priceMicroAlgos);

  // 3. Idempotency / crash recovery: already reserved?
  const existing = store.getPaymentDelivery(txid);
  if (existing) {
    if (store.hasCiphertext(existing.deliveryKeySha256)) return 'duplicate';
    // Reserved but ciphertext never written (crash between reserve and seal).
    const codes = store.getCodesByDeliveryKey(existing.deliveryKeySha256);
    if (codes.length === 0) {
      logger.error({ txId: txid }, 'payment-delivery: reserved txid has no recoverable codes');
      return 'duplicate';
    }
    const ciphertext = await seal(codes, deliveryPubkey, existing.round);
    store.fillCiphertext(existing.deliveryKeySha256, ciphertext);
    logger.info({ txId: txid }, 'payment-delivery: recovered ciphertext for prior reservation');
    return 'recovered';
  }

  // 4. Atomically reserve qty codes.
  let codes: string[];
  try {
    codes = store.reserveAndPick({ paymentTxid: txid, deliveryKeySha256: deliveryKey, qty, soldAtRound: round, round });
  } catch (err) {
    if (err instanceof InsufficientInventoryError) {
      store.recordUnfulfilled({ paymentTxid: txid, sender, amount: amountMicroAlgos, reason: 'insufficient_inventory', round });
      logger.warn(
        { txId: txid, available: err.available, requested: err.requested },
        'payment-delivery: insufficient inventory → unfulfilled (manual refund)',
      );
      return 'unfulfilled:insufficient_inventory';
    }
    if (err instanceof DuplicatePaymentError) {
      // Lost a race to reserve the same txid; treat as already processed.
      return 'duplicate';
    }
    throw err;
  }

  // 5. Seal + persist ciphertext (outside the sqlite txn — HPKE is async).
  const ciphertext = await seal(codes, deliveryPubkey, round);
  store.fillCiphertext(deliveryKey, ciphertext);
  logger.info({ txId: txid, qty }, 'payment-delivery: reserved + sealed delivery');
  return 'delivered';
}

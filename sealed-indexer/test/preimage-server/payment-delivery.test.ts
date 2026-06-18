import { createHash } from 'node:crypto';
import type { Logger } from 'pino';
import {
  createPreimageStore,
  DuplicatePaymentError,
  InsufficientInventoryError,
  type PreimageStore,
} from '../../src/preimage-server/db';
import {
  processPaymentDelivery,
  type PaymentTxn,
} from '../../src/preimage-server/payment-delivery';

const sha256 = (b: Uint8Array): Uint8Array =>
  new Uint8Array(createHash('sha256').update(b).digest());

// Silent logger stub — we assert on outcomes/state, not log lines.
const logger = {
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
} as unknown as Logger;

const PUB_A = new Uint8Array(32).fill(0x07);
const PUB_B = new Uint8Array(32).fill(0x09);
const PRICE = 1000n;

// Deterministic non-HPKE seal: real HPKE roundtrip is covered by crypto.test.ts.
let sealCalls = 0;
const seal = async (codes: string[]): Promise<Uint8Array> => {
  sealCalls++;
  return new Uint8Array([codes.length, ...codes.join('|').split('').map((c) => c.charCodeAt(0) & 0xff)]);
};

function seed(store: PreimageStore, n: number): void {
  for (let i = 0; i < n; i++) {
    const hash = new Uint8Array(32).fill((i % 250) + 1);
    hash[31] = i & 0xff; // keep hashes unique
    const pre = new Uint8Array(16).fill((i % 250) + 1);
    const code = `CODE${String(i).padStart(12, '0')}`.slice(0, 16);
    store.insertAvailable(hash, pre, code);
  }
}

function payment(over: Partial<PaymentTxn> = {}): PaymentTxn {
  return {
    txid: 'TX1',
    sender: 'SENDER',
    amountMicroAlgos: PRICE,
    note: PUB_A,
    round: 100n,
    ...over,
  };
}

function deps(store: PreimageStore) {
  return { store, priceMicroAlgos: PRICE, seal, sha256, logger };
}

describe('preimage-server db — inventory ops', () => {
  let store: PreimageStore;
  beforeEach(() => {
    store = createPreimageStore(':memory:');
  });
  afterEach(() => store.close());

  test('countAvailable reflects seeded rows', () => {
    expect(store.countAvailable()).toBe(0);
    seed(store, 5);
    expect(store.countAvailable()).toBe(5);
  });

  test('reserveAndPick marks rows sold and returns codes', () => {
    seed(store, 3);
    const dk = sha256(PUB_A);
    const codes = store.reserveAndPick({
      paymentTxid: 'TX1',
      deliveryKeySha256: dk,
      qty: 2,
      soldAtRound: 100n,
      round: 100n,
    });
    expect(codes).toHaveLength(2);
    expect(store.countAvailable()).toBe(1);
    expect(store.getCodesByDeliveryKey(dk).sort()).toEqual(codes.sort());
  });

  test('reserveAndPick rolls back fully on shortfall', () => {
    seed(store, 1);
    expect(() =>
      store.reserveAndPick({
        paymentTxid: 'TX1',
        deliveryKeySha256: sha256(PUB_A),
        qty: 2,
        soldAtRound: 100n,
        round: 100n,
      }),
    ).toThrow(InsufficientInventoryError);
    // Nothing consumed, txid not recorded → retry possible.
    expect(store.countAvailable()).toBe(1);
    expect(store.getPaymentDelivery('TX1')).toBeNull();
  });

  test('reserveAndPick rejects a duplicate txid', () => {
    seed(store, 3);
    store.reserveAndPick({ paymentTxid: 'TX1', deliveryKeySha256: sha256(PUB_A), qty: 1, soldAtRound: 100n, round: 100n });
    expect(() =>
      store.reserveAndPick({ paymentTxid: 'TX1', deliveryKeySha256: sha256(PUB_B), qty: 1, soldAtRound: 100n, round: 100n }),
    ).toThrow(DuplicatePaymentError);
    expect(store.countAvailable()).toBe(2); // only the first reservation consumed
  });
});

describe('processPaymentDelivery', () => {
  let store: PreimageStore;
  beforeEach(() => {
    store = createPreimageStore(':memory:');
    sealCalls = 0;
  });
  afterEach(() => store.close());

  test('happy path: delivers and seals', async () => {
    seed(store, 5);
    const r = await processPaymentDelivery(payment({ amountMicroAlgos: PRICE * 2n }), deps(store));
    expect(r).toBe('delivered');
    expect(store.countAvailable()).toBe(3);
    const ct = store.getCiphertextByDeliveryKey(sha256(PUB_A));
    expect(ct).not.toBeNull();
    expect(ct!.length).toBeGreaterThan(0);
  });

  test('bad note (wrong length) → unfulfilled, no inventory consumed', async () => {
    seed(store, 2);
    const r = await processPaymentDelivery(payment({ note: new Uint8Array(31) }), deps(store));
    expect(r).toBe('unfulfilled:bad_note');
    expect(store.countAvailable()).toBe(2);
  });

  test('amount not an exact multiple of price → unfulfilled', async () => {
    seed(store, 2);
    const r = await processPaymentDelivery(payment({ amountMicroAlgos: PRICE + 1n }), deps(store));
    expect(r).toBe('unfulfilled:bad_amount');
    expect(store.countAvailable()).toBe(2);
  });

  test('amount below one unit → unfulfilled', async () => {
    seed(store, 2);
    const r = await processPaymentDelivery(payment({ amountMicroAlgos: 0n }), deps(store));
    expect(r).toBe('unfulfilled:bad_amount');
  });

  test('insufficient inventory → unfulfilled, recorded for refund', async () => {
    seed(store, 1);
    const r = await processPaymentDelivery(payment({ amountMicroAlgos: PRICE * 2n }), deps(store));
    expect(r).toBe('unfulfilled:insufficient_inventory');
    // Atomic: the single available code is NOT consumed.
    expect(store.countAvailable()).toBe(1);
  });

  test('replay of the same txid does not re-allocate', async () => {
    seed(store, 5);
    const p = payment({ amountMicroAlgos: PRICE * 2n });
    expect(await processPaymentDelivery(p, deps(store))).toBe('delivered');
    expect(store.countAvailable()).toBe(3);
    const r2 = await processPaymentDelivery(p, deps(store));
    expect(r2).toBe('duplicate');
    expect(store.countAvailable()).toBe(3); // unchanged
  });

  test('two buys of the last code: one delivered, one unfulfilled', async () => {
    seed(store, 1);
    const r1 = await processPaymentDelivery(payment({ txid: 'TXA', note: PUB_A }), deps(store));
    const r2 = await processPaymentDelivery(payment({ txid: 'TXB', note: PUB_B }), deps(store));
    expect([r1, r2].sort()).toEqual(['delivered', 'unfulfilled:insufficient_inventory'].sort());
    expect(store.countAvailable()).toBe(0);
  });

  test('crash recovery: reserved-but-unsealed txid re-seals on replay', async () => {
    seed(store, 2);
    const dk = sha256(PUB_A);
    // Simulate a crash after reservation but before fillCiphertext.
    store.reserveAndPick({ paymentTxid: 'TX1', deliveryKeySha256: dk, qty: 1, soldAtRound: 100n, round: 100n });
    expect(store.hasCiphertext(dk)).toBe(false);
    const r = await processPaymentDelivery(payment(), deps(store));
    expect(r).toBe('recovered');
    expect(store.hasCiphertext(dk)).toBe(true);
    expect(sealCalls).toBe(1);
  });
});

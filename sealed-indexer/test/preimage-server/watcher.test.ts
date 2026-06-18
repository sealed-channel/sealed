import pino from 'pino';
import algosdk from 'algosdk';
import type { Logger } from 'pino';

import type {
  SubscribedTxn,
  SubscriberFactoryConfig,
  SubscriberLike,
} from '../../src/chain/chain-subscription';
import { commitmentFromCode, preimageFromCode } from '../../src/preimage-server/codes';
import {
  generateDeliveryKeypairForTest,
  openForDelivery,
} from '../../src/preimage-server/crypto';
import { createPreimageStore, type PreimageStore } from '../../src/preimage-server/db';
import { encodeCommitmentsSoldEvent } from '../../src/preimage-server/events';
import {
  PURCHASE_CODES_SELECTOR,
  createPreimageWatcher,
} from '../../src/preimage-server/watcher';

interface TestSubscriber extends SubscriberLike {
  feed(filterName: string, txn: SubscribedTxn): Promise<void>;
  capturedError: unknown;
}

function makeTestSubscriber(): TestSubscriber {
  const handlers = new Map<string, (txn: SubscribedTxn) => void | Promise<void>>();
  const sub: TestSubscriber = {
    on(name, handler) {
      handlers.set(name, handler);
    },
    onError(_h) {
      /* unused — test always inspects exceptions via `feed` */
    },
    start() {
      /* no-op */
    },
    async stop() {
      /* no-op */
    },
    async feed(filterName, txn) {
      const h = handlers.get(filterName);
      if (!h) throw new Error(`no handler registered for ${filterName}`);
      await h(txn);
    },
    capturedError: null,
  };
  return sub;
}

function buildPurchaseCodesTxn(args: {
  buyer: string;
  deliveryPubkey: Uint8Array;
  commitments: Uint8Array[];
  purchasedAtRound: bigint;
  qty?: number;
  appId?: bigint;
  txId?: string;
  omitEventLog?: boolean;
  overrideEventDeliveryPubkey?: Uint8Array;
}): SubscribedTxn {
  const qty = args.qty ?? args.commitments.length;
  const qtyBytes = new Uint8Array(8);
  new DataView(qtyBytes.buffer).setBigUint64(0, BigInt(qty));

  const eventBuyerKey = args.overrideEventDeliveryPubkey ?? args.deliveryPubkey;
  const eventBytes = args.omitEventLog
    ? null
    : encodeCommitmentsSoldEvent({
        buyer: args.buyer,
        deliveryPubkey: eventBuyerKey,
        commitments: args.commitments,
        purchasedAtRound: args.purchasedAtRound,
      });

  return {
    id: args.txId ?? 'TXTEST',
    sender: args.buyer,
    confirmedRound: args.purchasedAtRound,
    roundTime: 1_700_000_000,
    logs: eventBytes ? [eventBytes] : [],
    applicationTransaction: {
      applicationId: args.appId ?? 12345n,
      applicationArgs: [
        new Uint8Array(PURCHASE_CODES_SELECTOR),
        qtyBytes,
        args.deliveryPubkey,
      ],
    },
  };
}

function silentLogger(): Logger {
  return pino({ level: 'silent' });
}

const APP_ID = 12345n;

describe('preimage-server watcher (purchaseCodes → CommitmentsSold → seal + markSold)', () => {
  let store: PreimageStore;

  beforeEach(() => {
    store = createPreimageStore(':memory:');
  });
  afterEach(() => {
    store.close();
  });

  describe('happy path', () => {
    test('seals a single code and stamps the row sold', async () => {
      const code = '0123456789ABCDEF';
      const commitment = commitmentFromCode(code);
      const preimage = preimageFromCode(code);
      store.insertAvailable(commitment, preimage, code);

      const { publicKey, privateKey } = await generateDeliveryKeypairForTest();
      const buyer = algosdk.encodeAddress(new Uint8Array(32).fill(0x11));

      const subscriber = makeTestSubscriber();
      const watcher = createPreimageWatcher({
        algodUrl: 'http://unused',
        appId: APP_ID,
        store,
        logger: silentLogger(),
        subscriberFactory: (_cfg: SubscriberFactoryConfig) => subscriber,
      });
      await watcher.start();

      const txn = buildPurchaseCodesTxn({
        buyer,
        deliveryPubkey: publicKey,
        commitments: [commitment],
        purchasedAtRound: 1000n,
      });
      await subscriber.feed('purchase-codes-calls', txn);

      const row = store.getByCommitment(commitment)!;
      expect(row.status).toBe('sold');
      expect(row.soldAtRound).toBe(1000n);
      expect(row.ciphertext).not.toBeNull();
      expect(row.deliveryKeySha256).not.toBeNull();
      // Plaintext + code are preserved through `sold`; cleared on `delivered`.
      expect(row.code).toBe(code);

      const decoded = await openForDelivery(row.ciphertext!, privateKey);
      expect(decoded.codes).toEqual([code]);
      expect(decoded.purchasedAtRound).toBe(1000n);
    });

    test('seals N codes into one ciphertext shared across N rows', async () => {
      const codes = ['0123456789ABCDEF', 'GHJKMNPQRSTVWXYZ', 'ZZZZZZZZZZZZZZZZ'];
      const commitments: Uint8Array[] = [];
      for (const c of codes) {
        const com = commitmentFromCode(c);
        store.insertAvailable(com, preimageFromCode(c), c);
        commitments.push(com);
      }

      const { publicKey, privateKey } = await generateDeliveryKeypairForTest();
      const buyer = algosdk.encodeAddress(new Uint8Array(32).fill(0x22));

      const subscriber = makeTestSubscriber();
      const watcher = createPreimageWatcher({
        algodUrl: 'http://unused',
        appId: APP_ID,
        store,
        logger: silentLogger(),
        subscriberFactory: () => subscriber,
      });
      await watcher.start();

      await subscriber.feed(
        'purchase-codes-calls',
        buildPurchaseCodesTxn({
          buyer,
          deliveryPubkey: publicKey,
          commitments,
          purchasedAtRound: 2000n,
        }),
      );

      // Every row marked sold, every row has the same ciphertext bytes.
      const rows = commitments.map((c) => store.getByCommitment(c)!);
      for (const r of rows) {
        expect(r.status).toBe('sold');
        expect(r.soldAtRound).toBe(2000n);
      }
      const firstCiphertext = Buffer.from(rows[0].ciphertext!);
      for (const r of rows) {
        expect(firstCiphertext.equals(Buffer.from(r.ciphertext!))).toBe(true);
      }

      const decoded = await openForDelivery(rows[0].ciphertext!, privateKey);
      expect(decoded.codes).toEqual(codes);
      expect(decoded.purchasedAtRound).toBe(2000n);
    });
  });

  describe('idempotency', () => {
    test('replaying the same event does not double-write', async () => {
      const code = '0123456789ABCDEF';
      const commitment = commitmentFromCode(code);
      store.insertAvailable(commitment, preimageFromCode(code), code);

      const { publicKey } = await generateDeliveryKeypairForTest();
      const buyer = algosdk.encodeAddress(new Uint8Array(32).fill(0x33));
      const subscriber = makeTestSubscriber();
      const watcher = createPreimageWatcher({
        algodUrl: 'http://unused',
        appId: APP_ID,
        store,
        logger: silentLogger(),
        subscriberFactory: () => subscriber,
      });
      await watcher.start();

      const txn = buildPurchaseCodesTxn({
        buyer,
        deliveryPubkey: publicKey,
        commitments: [commitment],
        purchasedAtRound: 3000n,
      });

      await subscriber.feed('purchase-codes-calls', txn);
      const firstRow = store.getByCommitment(commitment)!;
      const firstCt = Buffer.from(firstRow.ciphertext!);

      // Same event again — row is already sold; markSold guard rejects.
      await subscriber.feed('purchase-codes-calls', txn);
      const secondRow = store.getByCommitment(commitment)!;
      expect(secondRow.soldAtRound).toBe(3000n);
      expect(Buffer.from(secondRow.ciphertext!).equals(firstCt)).toBe(true);
    });
  });

  describe('partial / inconsistent purchases', () => {
    test('aborts whole event if ANY commitment is unknown — no rows touched', async () => {
      const code = '0123456789ABCDEF';
      const knownCommitment = commitmentFromCode(code);
      store.insertAvailable(knownCommitment, preimageFromCode(code), code);

      const unknownCommitment = new Uint8Array(32).fill(0x77);

      const { publicKey } = await generateDeliveryKeypairForTest();
      const buyer = algosdk.encodeAddress(new Uint8Array(32).fill(0x44));
      const subscriber = makeTestSubscriber();
      const watcher = createPreimageWatcher({
        algodUrl: 'http://unused',
        appId: APP_ID,
        store,
        logger: silentLogger(),
        subscriberFactory: () => subscriber,
      });
      await watcher.start();

      await subscriber.feed(
        'purchase-codes-calls',
        buildPurchaseCodesTxn({
          buyer,
          deliveryPubkey: publicKey,
          commitments: [knownCommitment, unknownCommitment],
          purchasedAtRound: 4000n,
        }),
      );

      const row = store.getByCommitment(knownCommitment)!;
      // The known row stays untouched: partial delivery would leak one code
      // without delivering the rest.
      expect(row.status).toBe('available');
      expect(row.ciphertext).toBeNull();
    });

    test('skips when a row is already sold', async () => {
      const code = '0123456789ABCDEF';
      const commitment = commitmentFromCode(code);
      store.insertAvailable(commitment, preimageFromCode(code), code);

      const { publicKey } = await generateDeliveryKeypairForTest();
      const buyer = algosdk.encodeAddress(new Uint8Array(32).fill(0x55));
      const subscriber = makeTestSubscriber();
      const watcher = createPreimageWatcher({
        algodUrl: 'http://unused',
        appId: APP_ID,
        store,
        logger: silentLogger(),
        subscriberFactory: () => subscriber,
      });
      await watcher.start();

      // First purchase succeeds.
      await subscriber.feed(
        'purchase-codes-calls',
        buildPurchaseCodesTxn({
          buyer,
          deliveryPubkey: publicKey,
          commitments: [commitment],
          purchasedAtRound: 5000n,
        }),
      );

      // A second event lists the same commitment — should be skipped, not
      // re-encrypted to a different key.
      const { publicKey: otherKey } = await generateDeliveryKeypairForTest();
      const before = store.getByCommitment(commitment)!;
      const beforeCt = Buffer.from(before.ciphertext!);
      await subscriber.feed(
        'purchase-codes-calls',
        buildPurchaseCodesTxn({
          buyer,
          deliveryPubkey: otherKey,
          commitments: [commitment],
          purchasedAtRound: 6000n,
        }),
      );
      const after = store.getByCommitment(commitment)!;
      expect(after.soldAtRound).toBe(5000n);
      expect(Buffer.from(after.ciphertext!).equals(beforeCt)).toBe(true);
    });
  });

  describe('malformed txns', () => {
    test('purchaseCodes txn with no CommitmentsSold log is skipped', async () => {
      const code = '0123456789ABCDEF';
      const commitment = commitmentFromCode(code);
      store.insertAvailable(commitment, preimageFromCode(code), code);
      const { publicKey } = await generateDeliveryKeypairForTest();
      const buyer = algosdk.encodeAddress(new Uint8Array(32).fill(0x66));
      const subscriber = makeTestSubscriber();
      const watcher = createPreimageWatcher({
        algodUrl: 'http://unused',
        appId: APP_ID,
        store,
        logger: silentLogger(),
        subscriberFactory: () => subscriber,
      });
      await watcher.start();

      await subscriber.feed(
        'purchase-codes-calls',
        buildPurchaseCodesTxn({
          buyer,
          deliveryPubkey: publicKey,
          commitments: [commitment],
          purchasedAtRound: 7000n,
          omitEventLog: true,
        }),
      );

      expect(store.getByCommitment(commitment)!.status).toBe('available');
    });

    test('deliveryPubkey mismatch between call args and event aborts the purchase', async () => {
      const code = '0123456789ABCDEF';
      const commitment = commitmentFromCode(code);
      store.insertAvailable(commitment, preimageFromCode(code), code);

      const a = await generateDeliveryKeypairForTest();
      const b = await generateDeliveryKeypairForTest();
      const buyer = algosdk.encodeAddress(new Uint8Array(32).fill(0x77));
      const subscriber = makeTestSubscriber();
      const watcher = createPreimageWatcher({
        algodUrl: 'http://unused',
        appId: APP_ID,
        store,
        logger: silentLogger(),
        subscriberFactory: () => subscriber,
      });
      await watcher.start();

      await subscriber.feed(
        'purchase-codes-calls',
        buildPurchaseCodesTxn({
          buyer,
          deliveryPubkey: a.publicKey,
          commitments: [commitment],
          purchasedAtRound: 8000n,
          overrideEventDeliveryPubkey: b.publicKey,
        }),
      );

      expect(store.getByCommitment(commitment)!.status).toBe('available');
    });
  });
});

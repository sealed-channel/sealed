import { createPreimageStore, PreimageStore } from '../../src/preimage-server/db';

const HASH_A = new Uint8Array(32).fill(0xa1);
const HASH_B = new Uint8Array(32).fill(0xb2);
const PREIMAGE_A = new Uint8Array(16).fill(0x11);
const PREIMAGE_B = new Uint8Array(16).fill(0x22);
const CODE_A = '0123456789ABCDEF';
const CODE_B = 'GHJKMNPQRSTVWXYZ';
const DELIVERY_KEY_X = new Uint8Array(32).fill(0xcc);
const DELIVERY_KEY_Y = new Uint8Array(32).fill(0xdd);
const CIPHERTEXT_X = new Uint8Array([1, 2, 3, 4, 5]);
const CIPHERTEXT_Y = new Uint8Array([9, 9, 9]);

const toHex = (b: Uint8Array): string =>
  Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');

describe('preimage-server db', () => {
  let store: PreimageStore;

  beforeEach(() => {
    store = createPreimageStore(':memory:');
  });

  afterEach(() => {
    store.close();
  });

  describe('schema + insertAvailable', () => {
    test('inserts and round-trips a row', () => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      const row = store.getByCommitment(HASH_A);
      expect(row).not.toBeNull();
      expect(toHex(row!.commitmentHash)).toBe(toHex(HASH_A));
      expect(toHex(row!.preimage!)).toBe(toHex(PREIMAGE_A));
      expect(row!.status).toBe('available');
      expect(row!.soldAtRound).toBeNull();
      expect(row!.ciphertext).toBeNull();
      expect(row!.deliveryKeySha256).toBeNull();
      expect(row!.deliveredAtRound).toBeNull();
    });

    test('returns null for an unknown commitment', () => {
      expect(store.getByCommitment(HASH_A)).toBeNull();
    });

    test('rejects a duplicate commitment_hash', () => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      expect(() => store.insertAvailable(HASH_A, PREIMAGE_B, CODE_B)).toThrow(/UNIQUE/);
    });

    test('rejects wrong-size commitment_hash, preimage, or code', () => {
      expect(() => store.insertAvailable(new Uint8Array(31), PREIMAGE_A, CODE_A)).toThrow(
        /commitmentHash must be 32/,
      );
      expect(() => store.insertAvailable(HASH_A, new Uint8Array(15), CODE_A)).toThrow(
        /preimage must be 16/,
      );
      expect(() => store.insertAvailable(HASH_A, PREIMAGE_A, 'TOO-SHORT')).toThrow(
        /code must be a 16-char string/,
      );
    });

    test('persists the code as written and exposes it on the row', () => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      const row = store.getByCommitment(HASH_A);
      expect(row).not.toBeNull();
      expect(row!.code).toBe(CODE_A);
    });
  });

  describe('markSold (available → sold)', () => {
    beforeEach(() => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
    });

    test('transitions available → sold and stamps every field', () => {
      const changes = store.markSold({
        commitmentHash: HASH_A,
        soldAtRound: 1_000_000n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
      expect(changes).toBe(1);

      const row = store.getByCommitment(HASH_A)!;
      expect(row.status).toBe('sold');
      expect(row.soldAtRound).toBe(1_000_000n);
      expect(toHex(row.deliveryKeySha256!)).toBe(toHex(DELIVERY_KEY_X));
      expect(toHex(row.ciphertext!)).toBe(toHex(CIPHERTEXT_X));
      // Plaintext is preserved until delivery.
      expect(toHex(row.preimage!)).toBe(toHex(PREIMAGE_A));
    });

    test('is idempotent — replaying the same event is a no-op', () => {
      store.markSold({
        commitmentHash: HASH_A,
        soldAtRound: 1_000_000n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
      const changes = store.markSold({
        commitmentHash: HASH_A,
        soldAtRound: 9_999_999n,
        deliveryKeySha256: DELIVERY_KEY_Y,
        ciphertext: CIPHERTEXT_Y,
      });
      expect(changes).toBe(0);

      const row = store.getByCommitment(HASH_A)!;
      expect(row.soldAtRound).toBe(1_000_000n);
      expect(toHex(row.deliveryKeySha256!)).toBe(toHex(DELIVERY_KEY_X));
      expect(toHex(row.ciphertext!)).toBe(toHex(CIPHERTEXT_X));
    });

    test('returns 0 changes for unknown commitment hash', () => {
      const changes = store.markSold({
        commitmentHash: HASH_B,
        soldAtRound: 5n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
      expect(changes).toBe(0);
    });

    test('rejects malformed inputs', () => {
      expect(() =>
        store.markSold({
          commitmentHash: HASH_A,
          soldAtRound: -1n,
          deliveryKeySha256: DELIVERY_KEY_X,
          ciphertext: CIPHERTEXT_X,
        }),
      ).toThrow(/soldAtRound must be non-negative/);
      expect(() =>
        store.markSold({
          commitmentHash: HASH_A,
          soldAtRound: 1n,
          deliveryKeySha256: new Uint8Array(31),
          ciphertext: CIPHERTEXT_X,
        }),
      ).toThrow(/deliveryKeySha256 must be 32/);
      expect(() =>
        store.markSold({
          commitmentHash: HASH_A,
          soldAtRound: 1n,
          deliveryKeySha256: DELIVERY_KEY_X,
          ciphertext: new Uint8Array(0),
        }),
      ).toThrow(/ciphertext must be non-empty/);
    });
  });

  describe('multi-code purchase (multiple rows share a delivery key)', () => {
    test('markSold stamps each row independently; both queryable by delivery key', () => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      store.insertAvailable(HASH_B, PREIMAGE_B, CODE_B);

      store.markSold({
        commitmentHash: HASH_A,
        soldAtRound: 42n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
      store.markSold({
        commitmentHash: HASH_B,
        soldAtRound: 42n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });

      const ct = store.getCiphertextByDeliveryKey(DELIVERY_KEY_X);
      expect(ct).not.toBeNull();
      expect(toHex(ct!)).toBe(toHex(CIPHERTEXT_X));
    });
  });

  describe('markDelivered (sold → delivered)', () => {
    beforeEach(() => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      store.markSold({
        commitmentHash: HASH_A,
        soldAtRound: 42n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
    });

    test('transitions sold → delivered and clears the preimage AND code', () => {
      const changes = store.markDelivered(DELIVERY_KEY_X, 99n);
      expect(changes).toBe(1);

      const row = store.getByCommitment(HASH_A)!;
      expect(row.status).toBe('delivered');
      expect(row.deliveredAtRound).toBe(99n);
      expect(row.preimage).toBeNull();
      expect(row.code).toBeNull();
      // Ciphertext stays so re-fetches are idempotent.
      expect(toHex(row.ciphertext!)).toBe(toHex(CIPHERTEXT_X));
    });

    test('is idempotent — re-fetching the same delivery key is a no-op', () => {
      store.markDelivered(DELIVERY_KEY_X, 99n);
      const changes = store.markDelivered(DELIVERY_KEY_X, 500n);
      expect(changes).toBe(0);
      const row = store.getByCommitment(HASH_A)!;
      expect(row.deliveredAtRound).toBe(99n);
    });

    test('does not touch rows still in `available` status', () => {
      store.insertAvailable(HASH_B, PREIMAGE_B, CODE_B);
      const changes = store.markDelivered(DELIVERY_KEY_Y, 100n);
      expect(changes).toBe(0);
      expect(store.getByCommitment(HASH_B)!.status).toBe('available');
    });

    test('delivers all rows sharing the same delivery key in one call', () => {
      store.insertAvailable(HASH_B, PREIMAGE_B, CODE_B);
      store.markSold({
        commitmentHash: HASH_B,
        soldAtRound: 42n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
      const changes = store.markDelivered(DELIVERY_KEY_X, 99n);
      expect(changes).toBe(2);
      expect(store.getByCommitment(HASH_A)!.status).toBe('delivered');
      expect(store.getByCommitment(HASH_B)!.status).toBe('delivered');
    });
  });

  describe('getCiphertextByDeliveryKey', () => {
    test('returns null for an unknown delivery key', () => {
      expect(store.getCiphertextByDeliveryKey(DELIVERY_KEY_X)).toBeNull();
    });

    test('returns ciphertext for sold rows', () => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      store.markSold({
        commitmentHash: HASH_A,
        soldAtRound: 1n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
      const ct = store.getCiphertextByDeliveryKey(DELIVERY_KEY_X);
      expect(toHex(ct!)).toBe(toHex(CIPHERTEXT_X));
    });

    test('returns ciphertext for already-delivered rows (idempotent fetch)', () => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      store.markSold({
        commitmentHash: HASH_A,
        soldAtRound: 1n,
        deliveryKeySha256: DELIVERY_KEY_X,
        ciphertext: CIPHERTEXT_X,
      });
      store.markDelivered(DELIVERY_KEY_X, 2n);
      const ct = store.getCiphertextByDeliveryKey(DELIVERY_KEY_X);
      expect(toHex(ct!)).toBe(toHex(CIPHERTEXT_X));
    });

    test('does not expose ciphertext for available (unsold) rows', () => {
      store.insertAvailable(HASH_A, PREIMAGE_A, CODE_A);
      expect(store.getCiphertextByDeliveryKey(DELIVERY_KEY_X)).toBeNull();
    });
  });

  describe('watcher_checkpoint', () => {
    test('starts unset', () => {
      expect(store.getWatcherCheckpoint()).toBeNull();
    });

    test('round-trips a bigint round', () => {
      store.setWatcherCheckpoint(63_622_000n);
      expect(store.getWatcherCheckpoint()).toBe(63_622_000n);
    });

    test('upsert overwrites prior value', () => {
      store.setWatcherCheckpoint(1n);
      store.setWatcherCheckpoint(2n);
      expect(store.getWatcherCheckpoint()).toBe(2n);
    });

    test('rejects negative rounds', () => {
      expect(() => store.setWatcherCheckpoint(-1n)).toThrow(/non-negative/);
    });

    test('survives values past Number.MAX_SAFE_INTEGER', () => {
      const big = BigInt(Number.MAX_SAFE_INTEGER) + 12345n;
      store.setWatcherCheckpoint(big);
      expect(store.getWatcherCheckpoint()).toBe(big);
    });
  });
});

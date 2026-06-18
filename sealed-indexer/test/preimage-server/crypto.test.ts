import {
  AEAD_TAG_LEN,
  KEM_ENC_LEN,
  WIRE_VERSION,
  generateDeliveryKeypairForTest,
  openForDelivery,
  sealForDelivery,
  type DeliveryPayload,
} from '../../src/preimage-server/crypto';

const SAMPLE: DeliveryPayload = {
  codes: ['0123-4567-89AB-CDEF', 'ZZZZ-ZZZZ-ZZZZ-ZZZZ'],
  purchasedAtRound: 1_234_567n,
};

describe('preimage-server crypto (HPKE base / X25519 / HKDF-SHA256 / ChaCha20-Poly1305)', () => {
  describe('sealForDelivery + openForDelivery roundtrip', () => {
    test('encrypts and the matching private key decrypts the same payload', async () => {
      const { publicKey, privateKey } = await generateDeliveryKeypairForTest();
      const wire = await sealForDelivery(SAMPLE, publicKey);
      const opened = await openForDelivery(wire, privateKey);
      expect(opened.codes).toEqual(SAMPLE.codes);
      expect(opened.purchasedAtRound).toBe(SAMPLE.purchasedAtRound);
    });

    test('preserves a uint64 round past Number.MAX_SAFE_INTEGER', async () => {
      const { publicKey, privateKey } = await generateDeliveryKeypairForTest();
      const big = BigInt(Number.MAX_SAFE_INTEGER) + 9_999n;
      const wire = await sealForDelivery(
        { codes: ['XXXX-XXXX-XXXX-XXXX'], purchasedAtRound: big },
        publicKey,
      );
      const opened = await openForDelivery(wire, privateKey);
      expect(opened.purchasedAtRound).toBe(big);
    });

    test('encrypting the same payload twice yields different ciphertexts (fresh ephemeral)', async () => {
      const { publicKey } = await generateDeliveryKeypairForTest();
      const a = await sealForDelivery(SAMPLE, publicKey);
      const b = await sealForDelivery(SAMPLE, publicKey);
      expect(Buffer.from(a).equals(Buffer.from(b))).toBe(false);
    });
  });

  describe('wire format shape', () => {
    test('version byte = 0x01 at offset 0', async () => {
      const { publicKey } = await generateDeliveryKeypairForTest();
      const wire = await sealForDelivery(SAMPLE, publicKey);
      expect(wire[0]).toBe(WIRE_VERSION);
    });

    test('total length = 1 + 32 + plaintext_len + 16 (tag)', async () => {
      const { publicKey } = await generateDeliveryKeypairForTest();
      const wire = await sealForDelivery(SAMPLE, publicKey);
      const expectedPlaintextLen = new TextEncoder().encode(
        JSON.stringify({
          codes: SAMPLE.codes,
          purchasedAtRound: SAMPLE.purchasedAtRound.toString(),
        }),
      ).length;
      expect(wire.length).toBe(1 + KEM_ENC_LEN + expectedPlaintextLen + AEAD_TAG_LEN);
    });
  });

  describe('input validation', () => {
    test('rejects deliveryPubkey of wrong size', async () => {
      await expect(sealForDelivery(SAMPLE, new Uint8Array(31))).rejects.toThrow(
        /deliveryPubkey must be 32/,
      );
    });

    test('rejects an all-zero deliveryPubkey', async () => {
      await expect(sealForDelivery(SAMPLE, new Uint8Array(32))).rejects.toThrow(
        /must not be all-zero/,
      );
    });

    test('rejects an empty codes list', async () => {
      const { publicKey } = await generateDeliveryKeypairForTest();
      await expect(
        sealForDelivery({ codes: [], purchasedAtRound: 1n }, publicKey),
      ).rejects.toThrow(/non-empty array/);
    });

    test('rejects a negative purchasedAtRound', async () => {
      const { publicKey } = await generateDeliveryKeypairForTest();
      await expect(
        sealForDelivery({ codes: ['x'], purchasedAtRound: -1n }, publicKey),
      ).rejects.toThrow(/non-negative bigint/);
    });
  });

  describe('decrypt failure modes', () => {
    test('wrong recipient private key fails open', async () => {
      const a = await generateDeliveryKeypairForTest();
      const b = await generateDeliveryKeypairForTest();
      const wire = await sealForDelivery(SAMPLE, a.publicKey);
      await expect(openForDelivery(wire, b.privateKey)).rejects.toThrow();
    });

    test('tampered ciphertext fails the AEAD tag check', async () => {
      const { publicKey, privateKey } = await generateDeliveryKeypairForTest();
      const wire = await sealForDelivery(SAMPLE, publicKey);
      const tampered = new Uint8Array(wire);
      // Flip the last byte (inside the Poly1305 tag).
      tampered[tampered.length - 1] ^= 0xff;
      await expect(openForDelivery(tampered, privateKey)).rejects.toThrow();
    });

    test('wrong version byte is rejected before AEAD work', async () => {
      const { publicKey, privateKey } = await generateDeliveryKeypairForTest();
      const wire = await sealForDelivery(SAMPLE, publicKey);
      const bad = new Uint8Array(wire);
      bad[0] = 0x02;
      await expect(openForDelivery(bad, privateKey)).rejects.toThrow(/unsupported wire version: 2/);
    });

    test('truncated wire is rejected before AEAD work', async () => {
      const { privateKey } = await generateDeliveryKeypairForTest();
      const tooShort = new Uint8Array(1 + KEM_ENC_LEN + AEAD_TAG_LEN - 1);
      tooShort[0] = WIRE_VERSION;
      await expect(openForDelivery(tooShort, privateKey)).rejects.toThrow(/wire too short/);
    });

    test('wrong-size privkey is rejected', async () => {
      const { publicKey } = await generateDeliveryKeypairForTest();
      const wire = await sealForDelivery(SAMPLE, publicKey);
      await expect(openForDelivery(wire, new Uint8Array(31))).rejects.toThrow(
        /deliveryPrivkey must be 32/,
      );
    });
  });
});

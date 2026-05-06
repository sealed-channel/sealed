/**
 * Tests for dispatcher sealed-box token decryption.
 *
 * Protocol (must mirror sealed_app/lib/remote/indexer_client.dart _encryptToken):
 *  - envelope = eph_pub(32) || ciphertext(256) || mac(16)  = 304 bytes (base64)
 *  - shared   = X25519(eph_priv, dispatcher_pub) = X25519(dispatcher_priv, eph_pub)
 *  - nonce    = blake2b512(eph_pub || dispatcher_pub)[0..12]
 *  - key      = HKDF-SHA256(ikm=shared, salt=eph_pub||dispatcher_pub, info="sealed-push-token-v1", L=32)
 *  - padded   = u16be(token.length) || token_utf8 || zero_pad   (total 256 bytes)
 *  - cipher   = AES-256-GCM(key, nonce, padded) → (ciphertext256, mac16)
 */
import { createDispatcherDecryptor, sealTokenForTest } from '../src/push/dispatcher-seal';
import nacl from 'tweetnacl';
import { hkdfSync, createHash, createCipheriv } from 'crypto';

function genKeypair() {
  const seed = Buffer.from(nacl.randomBytes(32));
  const pub = Buffer.from(nacl.scalarMult.base(new Uint8Array(seed)));
  return { priv: seed, pub };
}

describe('dispatcher-seal', () => {
  describe('createDispatcherDecryptor', () => {
    it('round-trips a short ascii token sealed by the test helper', () => {
      const dispatcher = genKeypair();
      const decrypt = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcher.priv,
        dispatcherPubKey: dispatcher.pub,
      });
      const envelope = sealTokenForTest('hello-token', dispatcher.pub);
      expect(decrypt(envelope)).toBe('hello-token');
    });

    it('round-trips a realistic FCM-length token', () => {
      const dispatcher = genKeypair();
      const decrypt = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcher.priv,
        dispatcherPubKey: dispatcher.pub,
      });
      const fcmLike = 'd' + 'A'.repeat(162) + ':APA91b' + 'X'.repeat(80);
      const envelope = sealTokenForTest(fcmLike, dispatcher.pub);
      expect(decrypt(envelope)).toBe(fcmLike);
    });

    it('produces 304-byte envelopes', () => {
      const dispatcher = genKeypair();
      const envelope = sealTokenForTest('x', dispatcher.pub);
      expect(envelope.length).toBe(304);
    });

    it('rejects truncated envelopes', () => {
      const dispatcher = genKeypair();
      const decrypt = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcher.priv,
        dispatcherPubKey: dispatcher.pub,
      });
      const envelope = sealTokenForTest('x', dispatcher.pub);
      expect(() => decrypt(envelope.subarray(0, 303))).toThrow(/length/i);
    });

    it('rejects tampered ciphertext (GCM auth fails)', () => {
      const dispatcher = genKeypair();
      const decrypt = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcher.priv,
        dispatcherPubKey: dispatcher.pub,
      });
      const envelope = Buffer.from(sealTokenForTest('x', dispatcher.pub));
      envelope[40] ^= 0x01; // flip a ciphertext byte
      expect(() => decrypt(envelope)).toThrow();
    });

    it('rejects tampered ephemeral pub key', () => {
      const dispatcher = genKeypair();
      const decrypt = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcher.priv,
        dispatcherPubKey: dispatcher.pub,
      });
      const envelope = Buffer.from(sealTokenForTest('x', dispatcher.pub));
      envelope[0] ^= 0x01;
      expect(() => decrypt(envelope)).toThrow();
    });

    it('rejects envelope sealed for a different dispatcher key', () => {
      const dispatcherA = genKeypair();
      const dispatcherB = genKeypair();
      const decrypt = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcherA.priv,
        dispatcherPubKey: dispatcherA.pub,
      });
      const envelope = sealTokenForTest('x', dispatcherB.pub);
      expect(() => decrypt(envelope)).toThrow();
    });

    it('rejects empty token', () => {
      const dispatcher = genKeypair();
      expect(() => sealTokenForTest('', dispatcher.pub)).toThrow(/empty/i);
    });

    it('rejects token longer than 254 bytes (length prefix is 2 bytes, total padded 256)', () => {
      const dispatcher = genKeypair();
      const huge = 'x'.repeat(255);
      expect(() => sealTokenForTest(huge, dispatcher.pub)).toThrow(/too long/i);
    });

    it('throws on wrong dispatcher private-key length', () => {
      expect(() =>
        createDispatcherDecryptor({
          dispatcherPrivKey: Buffer.alloc(31),
          dispatcherPubKey: Buffer.alloc(32),
        }),
      ).toThrow(/length/i);
    });
  });

  describe('cross-language fixture parity', () => {
    /**
     * Independent reference encryptor written with primitive Node crypto,
     * structurally identical to what the Dart implementation must produce.
     * If this test passes, a Dart implementation following the same recipe
     * will produce envelopes the server can decrypt.
     */
    function referenceEncrypt(token: string, dispatcherPub: Buffer): Buffer {
      const ephSeed = Buffer.from(nacl.randomBytes(32));
      const ephPub = Buffer.from(nacl.scalarMult.base(new Uint8Array(ephSeed)));
      const shared = Buffer.from(
        nacl.scalarMult(new Uint8Array(ephSeed), new Uint8Array(dispatcherPub)),
      );
      const salt = Buffer.concat([ephPub, dispatcherPub]);
      const key = Buffer.from(
        hkdfSync('sha256', shared, salt, Buffer.from('sealed-push-token-v1'), 32),
      );
      const nonce = createHash('blake2b512').update(salt).digest().subarray(0, 12);

      const tokenBytes = Buffer.from(token, 'utf8');
      const padded = Buffer.alloc(256);
      padded.writeUInt16BE(tokenBytes.length, 0);
      tokenBytes.copy(padded, 2);

      const cipher = createCipheriv('aes-256-gcm', key, nonce);
      const ct = Buffer.concat([cipher.update(padded), cipher.final()]);
      const mac = cipher.getAuthTag();
      return Buffer.concat([ephPub, ct, mac]);
    }

    it('decrypts envelopes produced by a primitive reference encryptor', () => {
      const dispatcher = genKeypair();
      const decrypt = createDispatcherDecryptor({
        dispatcherPrivKey: dispatcher.priv,
        dispatcherPubKey: dispatcher.pub,
      });
      const tok = 'cross-lang-token-1234';
      const envelope = referenceEncrypt(tok, dispatcher.pub);
      expect(envelope.length).toBe(304);
      expect(decrypt(envelope)).toBe(tok);
    });
  });
});

/**
 * Unit tests for view-keys trial-decrypt primitives.
 *
 * Pins the byte-exact contract with sealed_app's CryptoService:
 *   - HMAC label "sealed-recipient-tag-v1"
 *   - X25519 ECDH via tweetnacl
 *   - constant-time tag compare
 */

import { createHmac } from 'crypto';
import nacl from 'tweetnacl';
import {
  CRYPTO_CONSTANTS,
  computeRecipientTag,
  computeSharedSecret,
  computeKemDiscoveryTag,
  constantTimeEquals,
  derivePublicKey,
  isMessageForViewKey,
  validateRecipientTag,
  validateX25519Key,
} from '../src/notifications/view-keys';

function clampedRandomScalar(): Buffer {
  const priv = Buffer.from(nacl.randomBytes(32));
  priv[0] &= 248;
  priv[31] &= 127;
  priv[31] |= 64;
  return priv;
}

function pubFromPriv(priv: Buffer): Buffer {
  return Buffer.from(nacl.scalarMult.base(new Uint8Array(priv)));
}

describe('validateX25519Key', () => {
  it('accepts a 32-byte non-zero buffer', () => {
    expect(validateX25519Key(Buffer.alloc(32, 0x01))).toBe(true);
  });

  it('rejects all-zero 32-byte buffer', () => {
    expect(validateX25519Key(Buffer.alloc(32, 0))).toBe(false);
  });

  it('rejects wrong length', () => {
    expect(validateX25519Key(Buffer.alloc(31, 0xff))).toBe(false);
    expect(validateX25519Key(Buffer.alloc(33, 0xff))).toBe(false);
  });

  it('rejects empty buffer', () => {
    expect(validateX25519Key(Buffer.alloc(0))).toBe(false);
  });
});

describe('validateRecipientTag', () => {
  it('accepts a 32-byte buffer (any contents)', () => {
    expect(validateRecipientTag(Buffer.alloc(32, 0))).toBe(true);
    expect(validateRecipientTag(Buffer.alloc(32, 0xab))).toBe(true);
  });

  it('rejects wrong length', () => {
    expect(validateRecipientTag(Buffer.alloc(16))).toBe(false);
    expect(validateRecipientTag(Buffer.alloc(64))).toBe(false);
  });
});

describe('constantTimeEquals', () => {
  it('returns true for identical buffers', () => {
    const a = Buffer.from('41'.repeat(32), 'hex');
    const b = Buffer.from('41'.repeat(32), 'hex');
    expect(constantTimeEquals(a, b)).toBe(true);
  });

  it('returns false for differing buffers of equal length', () => {
    const a = Buffer.alloc(32, 0x01);
    const b = Buffer.alloc(32, 0x02);
    expect(constantTimeEquals(a, b)).toBe(false);
  });

  it('returns false for different lengths (no leak via length difference)', () => {
    const a = Buffer.alloc(32, 0x01);
    const b = Buffer.alloc(33, 0x01);
    expect(constantTimeEquals(a, b)).toBe(false);
  });

  it('detects a single-byte difference at any position', () => {
    const a = Buffer.alloc(32, 0x01);
    for (let i = 0; i < 32; i++) {
      const b = Buffer.alloc(32, 0x01);
      b[i] = 0x02;
      expect(constantTimeEquals(a, b)).toBe(false);
    }
  });
});

describe('derivePublicKey', () => {
  it('matches scalarMult.base for a clamped private key', () => {
    const priv = clampedRandomScalar();
    const pub = derivePublicKey(priv);
    const expected = Buffer.from(nacl.scalarMult.base(new Uint8Array(priv)));
    expect(pub.equals(expected)).toBe(true);
    expect(pub.length).toBe(32);
  });

  it('throws on wrong length private key', () => {
    expect(() => derivePublicKey(Buffer.alloc(31))).toThrow(/Invalid private key length/);
  });
});

describe('computeSharedSecret', () => {
  it('is symmetric — Alice·B == Bob·A', () => {
    const aPriv = clampedRandomScalar();
    const aPub = pubFromPriv(aPriv);
    const bPriv = clampedRandomScalar();
    const bPub = pubFromPriv(bPriv);

    const ab = computeSharedSecret(aPriv, bPub);
    const ba = computeSharedSecret(bPriv, aPub);
    expect(ab.equals(ba)).toBe(true);
    expect(ab.length).toBe(32);
  });

  it('throws on wrong-length keys', () => {
    expect(() => computeSharedSecret(Buffer.alloc(31), Buffer.alloc(32))).toThrow(
      /Invalid private key length/,
    );
    expect(() => computeSharedSecret(Buffer.alloc(32), Buffer.alloc(31))).toThrow(
      /Invalid public key length/,
    );
  });
});

describe('computeRecipientTag', () => {
  it('matches HMAC-SHA256(sharedSecret, "sealed-recipient-tag-v1")', () => {
    const shared = Buffer.alloc(32, 0x42);
    const tag = computeRecipientTag(shared);
    const expected = createHmac('sha256', shared)
      .update(CRYPTO_CONSTANTS.RECIPIENT_TAG_INFO)
      .digest();
    expect(tag.equals(expected)).toBe(true);
    expect(tag.length).toBe(32);
  });

  it('uses the exact label string "sealed-recipient-tag-v1"', () => {
    expect(CRYPTO_CONSTANTS.RECIPIENT_TAG_INFO).toBe('sealed-recipient-tag-v1');
  });

  it('throws on wrong-length shared secret', () => {
    expect(() => computeRecipientTag(Buffer.alloc(16))).toThrow(/Invalid shared secret length/);
  });
});

describe('isMessageForViewKey', () => {
  it('returns true for the intended recipient (positive match)', () => {
    const recipientPriv = clampedRandomScalar();
    const recipientPub = pubFromPriv(recipientPriv);
    const senderEphPriv = clampedRandomScalar();
    const senderEphPub = pubFromPriv(senderEphPriv);

    // Sender computes the tag against the recipient's view pubkey.
    const senderShared = computeSharedSecret(senderEphPriv, recipientPub);
    const tag = computeRecipientTag(senderShared);

    expect(isMessageForViewKey(recipientPriv, senderEphPub, tag)).toBe(true);
  });

  it('returns false for an unrelated recipient (negative match)', () => {
    const recipientPriv = clampedRandomScalar();
    const recipientPub = pubFromPriv(recipientPriv);
    const strangerPriv = clampedRandomScalar();
    const senderEphPriv = clampedRandomScalar();
    const senderEphPub = pubFromPriv(senderEphPriv);

    // Tag is for `recipient`, but we trial-decrypt with `stranger`.
    const senderShared = computeSharedSecret(senderEphPriv, recipientPub);
    const tag = computeRecipientTag(senderShared);

    expect(isMessageForViewKey(strangerPriv, senderEphPub, tag)).toBe(false);
  });

  it('returns false for a tampered tag (single-byte flip)', () => {
    const recipientPriv = clampedRandomScalar();
    const recipientPub = pubFromPriv(recipientPriv);
    const senderEphPriv = clampedRandomScalar();
    const senderEphPub = pubFromPriv(senderEphPriv);
    const tag = computeRecipientTag(computeSharedSecret(senderEphPriv, recipientPub));

    const tampered = Buffer.from(tag);
    tampered[0] ^= 0x01;
    expect(isMessageForViewKey(recipientPriv, senderEphPub, tampered)).toBe(false);
  });

  it('throws on malformed view private key (wrong length)', () => {
    expect(() =>
      isMessageForViewKey(Buffer.alloc(16), Buffer.alloc(32, 0xff), Buffer.alloc(32)),
    ).toThrow(/Invalid view private key/);
  });

  it('throws on all-zero view private key', () => {
    expect(() =>
      isMessageForViewKey(Buffer.alloc(32, 0), Buffer.alloc(32, 0xff), Buffer.alloc(32)),
    ).toThrow(/Invalid view private key/);
  });

  it('throws on malformed sender ephemeral pubkey', () => {
    expect(() =>
      isMessageForViewKey(Buffer.alloc(32, 0x01), Buffer.alloc(31, 0xff), Buffer.alloc(32)),
    ).toThrow(/Invalid sender encryption pubkey/);
  });

  it('throws on all-zero sender ephemeral pubkey', () => {
    expect(() =>
      isMessageForViewKey(Buffer.alloc(32, 0x01), Buffer.alloc(32, 0), Buffer.alloc(32)),
    ).toThrow(/Invalid sender encryption pubkey/);
  });

  it('throws on malformed recipient tag (wrong length)', () => {
    expect(() =>
      isMessageForViewKey(Buffer.alloc(32, 0x01), Buffer.alloc(32, 0xff), Buffer.alloc(16)),
    ).toThrow(/Invalid recipient tag/);
  });

  it('is deterministic — same inputs yield same result', () => {
    const recipientPriv = clampedRandomScalar();
    const recipientPub = pubFromPriv(recipientPriv);
    const senderEphPriv = clampedRandomScalar();
    const senderEphPub = pubFromPriv(senderEphPriv);
    const tag = computeRecipientTag(computeSharedSecret(senderEphPriv, recipientPub));

    for (let i = 0; i < 5; i++) {
      expect(isMessageForViewKey(recipientPriv, senderEphPub, tag)).toBe(true);
    }
  });
});

describe('golden vectors — internal/fixtures/recipient-tag-vectors.json', () => {
  // Formula: HMAC-SHA256(X25519(viewPriv, senderEphPub), "sealed-recipient-tag-v1")
  // Vectors generated by programs/sealed and cross-verified by sealed_app CryptoService.
  const vectors = [
    { n: 0, viewPriv: '0101010101010101010101010101010101010101010101010101010101010101', senderEphPub: 'ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59', recipientTag: '3794f879f822514d5ce4f288496551a559df94ff4096fd5e31ba663a9af74e89' },
    { n: 1, viewPriv: '0303030303030303030303030303030303030303030303030303030303030303', senderEphPub: 'ac01b2209e86354fb853237b5de0f4fab13c7fcbf433a61c019369617fecf10b', recipientTag: 'cc4e300d32df73f542e5bdcbe4c3905b01b5091cdaf2b2e58a997f777a7ceaa8' },
    { n: 2, viewPriv: '0505050505050505050505050505050505050505050505050505050505050505', senderEphPub: 'f5b2d6e60f9477e310c2982daaa6c9136c108a1777c5947e448fa37d68174557', recipientTag: '7b1a042925de92476ae53e6745c547829ae739f13e7103eebfbc35fa7805885d' },
    { n: 3, viewPriv: '0707070707070707070707070707070707070707070707070707070707070707', senderEphPub: '31d4ab6aceec961137917037936e60716fac573afe94d9da84a8020448dfc112', recipientTag: '0a7b6ee6967dcd2cb1fb1736821659b5d4704b4b1d3c124c9b4047b5b6564fc6' },
    { n: 4, viewPriv: '0909090909090909090909090909090909090909090909090909090909090909', senderEphPub: 'f77ff4b10788bfdca62ca0bb160d427cf5762d85f2b5cad6807ec9c3febbde09', recipientTag: 'b0b8f62d18811f54c43379476e8f3d2ecb1b7efd40dc5f6a5c14e9504a6136be' },
    { n: 5, viewPriv: '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b', senderEphPub: '97c3b10b4d6c133a78ea5dcc1cf6421d3f81ae37b1f628ce14ca6fce7730f333', recipientTag: '833edc150ac53829508fbc70af6c5cb37d11258b194aa5cfb775610c382bc135' },
    { n: 6, viewPriv: '0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d', senderEphPub: '5855784cb3c8c796d84ac93e8f4a53dab0bb31e80960042cfa87f03a4293b308', recipientTag: '65e4a84634a704191a37296bf0d1c9ff754a5aa5e36c95e5fd3ce993bb87ca1a' },
    { n: 7, viewPriv: '0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f', senderEphPub: '781faab908430150daccdd6f9d6c5086e34f73a93ebbaa271765e5036edfc519', recipientTag: '0b80a84b65f22fe50a5b93e6c1c1839a0d9392719e885a7653e7d1829a18d5da' },
    { n: 8, viewPriv: '1111111111111111111111111111111111111111111111111111111111111111', senderEphPub: '052a50773ac8d91773f2dc9662e12f0defe915e415b8a1c8e20a5a3d6ab2b843', recipientTag: 'e41d2f26baaf8710aca67b8ca7bcdec67dd319594f24c6017f0daeb87d2d5c81' },
    { n: 9, viewPriv: '1313131313131313131313131313131313131313131313131313131313131313', senderEphPub: '18a6f8c1a7fddf22bd410138f79f7298cd38d1d0a542d4266d556be8609d8862', recipientTag: 'a421e1c51a39e83f94419670d84b8ae45514648435f51289ad493d01f6c5ca44' },
  ] as const;

  it.each(vectors)('vector n=%i reproduces expected recipientTag', ({ n, viewPriv, senderEphPub, recipientTag }) => {
    void n; // index only for label
    const priv = Buffer.from(viewPriv, 'hex');
    const eph = Buffer.from(senderEphPub, 'hex');
    const expected = Buffer.from(recipientTag, 'hex');

    const shared = computeSharedSecret(priv, eph);
    const tag = computeRecipientTag(shared);

    expect(tag.toString('hex')).toBe(expected.toString('hex'));
  });

  it('isMessageForViewKey positive match for all 10 vectors', () => {
    for (const { viewPriv, senderEphPub, recipientTag } of vectors) {
      const priv = Buffer.from(viewPriv, 'hex');
      const eph = Buffer.from(senderEphPub, 'hex');
      const tag = Buffer.from(recipientTag, 'hex');
      expect(isMessageForViewKey(priv, eph, tag)).toBe(true);
    }
  });
});

describe('computeKemDiscoveryTag', () => {
  // Canonical vector — MUST stay byte-exact with sealed_app's
  // MessageKemHandshake.computeKemDiscoveryTag:
  //   HMAC-SHA256("sealed-kem-init-tag-v1", utf8(sender)||utf8(recipient))
  it('matches the canonical known-answer vector', () => {
    const tag = computeKemDiscoveryTag('SENDERWALLET', 'RECIPWALLET');
    expect(tag.toString('hex')).toBe(
      '37d155a88ea42fedd1b0a330021f1d11315be56536118c948ffb8cbd29040680',
    );
    expect(tag).toHaveLength(32);
  });

  it('is order-sensitive (sender‖recipient is not commutative)', () => {
    const ab = computeKemDiscoveryTag('SENDERWALLET', 'RECIPWALLET');
    const ba = computeKemDiscoveryTag('RECIPWALLET', 'SENDERWALLET');
    expect(ab.toString('hex')).not.toBe(ba.toString('hex'));
  });

  it('is deterministic', () => {
    expect(computeKemDiscoveryTag('A', 'B').toString('hex')).toBe(
      computeKemDiscoveryTag('A', 'B').toString('hex'),
    );
  });
});

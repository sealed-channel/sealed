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

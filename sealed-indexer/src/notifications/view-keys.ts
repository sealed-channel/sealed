/**
 * Cryptographic operations for view-key matching (trial-decrypt).
 *
 * Ported from /Users/kgor/sealed/indexer-service/src/crypto/view-keys.ts and
 * trimmed to the surface the tor-indexer's push-fanout actually needs.
 *
 * MUST stay byte-exact with sealed_app's CryptoService:
 *   - computeRecipientTag(sharedSecret) = HMAC-SHA256(sharedSecret, "sealed-recipient-tag-v1")
 *   - shared_secret = X25519(view_priv, sender_ephemeral_pub)
 *   - isMessageForViewKey(view_priv, sender_eph_pub, tag) compares HMAC ⨂ tag in constant time.
 *
 * Source of truth: sealed_app/lib/services/crypto_service.dart
 *   - computeRecipientTag (line 213)
 *   - isMessageForMe      (line 253)
 */

import { createHmac } from 'crypto';
import nacl from 'tweetnacl';

export const CRYPTO_CONSTANTS = {
  RECIPIENT_TAG_INFO: 'sealed-recipient-tag-v1',
  X25519_PUBLIC_KEY_SIZE: 32,
  X25519_PRIVATE_KEY_SIZE: 32,
  RECIPIENT_TAG_SIZE: 32,
} as const;

/** A 32-byte X25519 key (public or private). Empty / all-zero → invalid. */
export function validateX25519Key(key: Buffer): boolean {
  if (!key || key.length !== CRYPTO_CONSTANTS.X25519_PUBLIC_KEY_SIZE) return false;
  for (let i = 0; i < key.length; i++) if (key[i] !== 0) return true;
  return false;
}

export const validateViewKey = validateX25519Key;
export const validateSenderPubkey = validateX25519Key;

export function validateRecipientTag(tag: Buffer): boolean {
  return Boolean(tag) && tag.length === CRYPTO_CONSTANTS.RECIPIENT_TAG_SIZE;
}

/**
 * X25519 ECDH. Mirrors sealed_app's `_x25519.sharedSecretKey(...)`.
 */
export function computeSharedSecret(privateKey: Buffer, publicKey: Buffer): Buffer {
  if (privateKey.length !== CRYPTO_CONSTANTS.X25519_PRIVATE_KEY_SIZE) {
    throw new Error(`Invalid private key length: ${privateKey.length}, expected 32`);
  }
  if (publicKey.length !== CRYPTO_CONSTANTS.X25519_PUBLIC_KEY_SIZE) {
    throw new Error(`Invalid public key length: ${publicKey.length}, expected 32`);
  }
  const out = nacl.scalarMult(new Uint8Array(privateKey), new Uint8Array(publicKey));
  return Buffer.from(out);
}

/**
 * HMAC-SHA256(sharedSecret, "sealed-recipient-tag-v1") → 32 bytes.
 */
export function computeRecipientTag(sharedSecret: Buffer): Buffer {
  if (sharedSecret.length !== 32) {
    throw new Error(`Invalid shared secret length: ${sharedSecret.length}, expected 32`);
  }
  return createHmac('sha256', sharedSecret).update(CRYPTO_CONSTANTS.RECIPIENT_TAG_INFO).digest();
}

/**
 * Trial-decrypt: does this on-chain (recipientTag, senderEphemeralPubkey) pair
 * belong to the holder of `viewPrivateKey`? Constant-time compare on the tag.
 */
export function isMessageForViewKey(
  viewPrivateKey: Buffer,
  senderEncryptionPubkey: Buffer,
  recipientTag: Buffer,
): boolean {
  if (!validateViewKey(viewPrivateKey)) throw new Error('Invalid view private key');
  if (!validateSenderPubkey(senderEncryptionPubkey)) throw new Error('Invalid sender encryption pubkey');
  if (!validateRecipientTag(recipientTag)) throw new Error('Invalid recipient tag');

  const sharedSecret = computeSharedSecret(viewPrivateKey, senderEncryptionPubkey);
  const expected = computeRecipientTag(sharedSecret);
  return constantTimeEquals(expected, recipientTag);
}

export function constantTimeEquals(a: Buffer, b: Buffer): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/**
 * Derive X25519 public key from a 32-byte seed/private key. Used to verify
 * that a registered (view_priv, view_pub) pair is consistent at /push/register.
 */
export function derivePublicKey(privateKey: Buffer): Buffer {
  if (privateKey.length !== CRYPTO_CONSTANTS.X25519_PRIVATE_KEY_SIZE) {
    throw new Error(`Invalid private key length: ${privateKey.length}, expected 32`);
  }
  const pub = nacl.scalarMult.base(new Uint8Array(privateKey));
  return Buffer.from(pub);
}

/** HMAC key for the KEM handshake discovery tag. */
export const KEM_INIT_TAG_INFO = 'sealed-kem-init-tag-v1';

/**
 * Deterministic KEM handshake discovery tag.
 *
 * MUST stay byte-exact with sealed_app's
 * `MessageKemHandshake.computeKemDiscoveryTag`:
 *   HMAC-SHA256(key = "sealed-kem-init-tag-v1",
 *               data = utf8(senderWallet) || utf8(recipientWallet))
 *
 * Source of truth:
 *   sealed_app/lib/features/messaging/message_kem_handshake.dart (computeKemDiscoveryTag)
 *
 * Unlike the ECDH `recipient_tag`, this tag is keyed on the two wallet address
 * strings (sender = on-chain app-call sender, recipient = the registering
 * user). First-contact handshake frames carry this tag with a zeroed X25519
 * ephemeral, so the ECDH trial-decrypt path cannot match them — the fanout
 * uses this helper for the KEM branch instead.
 */
export function computeKemDiscoveryTag(
  senderWallet: string,
  recipientWallet: string,
): Buffer {
  return createHmac('sha256', KEM_INIT_TAG_INFO)
    .update(Buffer.concat([Buffer.from(senderWallet, 'utf8'), Buffer.from(recipientWallet, 'utf8')]))
    .digest();
}

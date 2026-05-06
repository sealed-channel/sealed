/**
 * Sealed-box style dispatcher token decryption.
 *
 * Inverse of sealed_app/lib/remote/indexer_client.dart _encryptToken.
 *
 * Envelope (304 bytes total, base64 in transport):
 *   eph_pub(32) || ciphertext(256) || mac(16)
 *
 * Crypto recipe (must stay byte-exact with the Flutter client):
 *   shared = X25519(eph_priv, dispatcher_pub) = X25519(dispatcher_priv, eph_pub)
 *   salt   = eph_pub || dispatcher_pub                        (64 bytes)
 *   nonce  = blake2b512(salt)[0..12]                          (12 bytes)
 *   key    = HKDF-SHA256(ikm=shared, salt=salt,
 *                        info="sealed-push-token-v1", L=32)   (32 bytes)
 *   padded = u16be(token.length) || token_utf8 || zero_pad    (256 bytes)
 *   (ct, mac) = AES-256-GCM(key, nonce, padded)
 */

import { createHash, createCipheriv, createDecipheriv, hkdfSync } from 'crypto';
import nacl from 'tweetnacl';

const ENVELOPE_SIZE = 304;
const EPH_PUB_SIZE = 32;
const CIPHERTEXT_SIZE = 256;
const MAC_SIZE = 16;
const PADDED_TOKEN_SIZE = 256;
const KEY_SIZE = 32;
const NONCE_SIZE = 12;
const HKDF_INFO = Buffer.from('sealed-push-token-v1');
const MAX_TOKEN_BYTES = PADDED_TOKEN_SIZE - 2; // 2 bytes for u16be length prefix

export interface DispatcherDecryptorOptions {
  dispatcherPrivKey: Buffer;
  dispatcherPubKey: Buffer;
}

export type DispatcherDecryptor = (envelope: Buffer) => string;

export function createDispatcherDecryptor(opts: DispatcherDecryptorOptions): DispatcherDecryptor {
  if (opts.dispatcherPrivKey.length !== 32) {
    throw new Error(`Invalid dispatcher private key length: ${opts.dispatcherPrivKey.length}`);
  }
  if (opts.dispatcherPubKey.length !== 32) {
    throw new Error(`Invalid dispatcher public key length: ${opts.dispatcherPubKey.length}`);
  }
  const dispatcherPriv = Buffer.from(opts.dispatcherPrivKey);
  const dispatcherPub = Buffer.from(opts.dispatcherPubKey);

  return (envelope: Buffer): string => {
    if (!Buffer.isBuffer(envelope)) {
      throw new Error('Envelope must be a Buffer');
    }
    if (envelope.length !== ENVELOPE_SIZE) {
      throw new Error(`Invalid envelope length: ${envelope.length}, expected ${ENVELOPE_SIZE}`);
    }

    const ephPub = envelope.subarray(0, EPH_PUB_SIZE);
    const ciphertext = envelope.subarray(EPH_PUB_SIZE, EPH_PUB_SIZE + CIPHERTEXT_SIZE);
    const mac = envelope.subarray(EPH_PUB_SIZE + CIPHERTEXT_SIZE);

    const shared = Buffer.from(
      nacl.scalarMult(new Uint8Array(dispatcherPriv), new Uint8Array(ephPub)),
    );
    const salt = Buffer.concat([ephPub, dispatcherPub]);
    const nonce = deriveNonce(salt);
    const key = deriveKey(shared, salt);

    const decipher = createDecipheriv('aes-256-gcm', key, nonce);
    decipher.setAuthTag(mac);
    const padded = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    if (padded.length !== PADDED_TOKEN_SIZE) {
      throw new Error(`Decrypted plaintext has wrong size: ${padded.length}`);
    }

    const tokenLen = padded.readUInt16BE(0);
    if (tokenLen === 0 || tokenLen > MAX_TOKEN_BYTES) {
      throw new Error(`Invalid token length in plaintext: ${tokenLen}`);
    }
    return padded.subarray(2, 2 + tokenLen).toString('utf8');
  };
}

/**
 * Test-only encryptor that produces envelopes the decryptor accepts. NOT
 * used in production; the production encryptor lives in the Flutter client.
 */
export function sealTokenForTest(token: string, dispatcherPub: Buffer): Buffer {
  if (dispatcherPub.length !== 32) {
    throw new Error(`Invalid dispatcher pub key length: ${dispatcherPub.length}`);
  }
  const tokenBytes = Buffer.from(token, 'utf8');
  if (tokenBytes.length === 0) {
    throw new Error('Token must not be empty');
  }
  if (tokenBytes.length > MAX_TOKEN_BYTES) {
    throw new Error(`Token too long: ${tokenBytes.length}, max ${MAX_TOKEN_BYTES}`);
  }

  const ephSeed = Buffer.from(nacl.randomBytes(32));
  const ephPub = Buffer.from(nacl.scalarMult.base(new Uint8Array(ephSeed)));
  const shared = Buffer.from(
    nacl.scalarMult(new Uint8Array(ephSeed), new Uint8Array(dispatcherPub)),
  );
  const salt = Buffer.concat([ephPub, dispatcherPub]);
  const nonce = deriveNonce(salt);
  const key = deriveKey(shared, salt);

  const padded = Buffer.alloc(PADDED_TOKEN_SIZE);
  padded.writeUInt16BE(tokenBytes.length, 0);
  tokenBytes.copy(padded, 2);

  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  const ct = Buffer.concat([cipher.update(padded), cipher.final()]);
  const mac = cipher.getAuthTag();
  if (ct.length !== CIPHERTEXT_SIZE || mac.length !== MAC_SIZE) {
    throw new Error(`Unexpected GCM output sizes ct=${ct.length} mac=${mac.length}`);
  }
  return Buffer.concat([ephPub, ct, mac]);
}

function deriveNonce(salt: Buffer): Buffer {
  return createHash('blake2b512').update(salt).digest().subarray(0, NONCE_SIZE);
}

function deriveKey(shared: Buffer, salt: Buffer): Buffer {
  const out = hkdfSync('sha256', shared, salt, HKDF_INFO, KEY_SIZE);
  return Buffer.from(out);
}

export const DISPATCHER_SEAL_CONSTANTS = {
  ENVELOPE_SIZE,
  EPH_PUB_SIZE,
  CIPHERTEXT_SIZE,
  MAC_SIZE,
  PADDED_TOKEN_SIZE,
  KEY_SIZE,
  NONCE_SIZE,
  HKDF_INFO_STRING: 'sealed-push-token-v1',
  MAX_TOKEN_BYTES,
} as const;

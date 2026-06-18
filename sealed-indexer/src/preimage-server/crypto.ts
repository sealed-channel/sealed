/**
 * Encrypt redeem-code deliveries for the LP buyer.
 *
 * Construction: HPKE base mode (RFC 9180) with the ciphersuite
 *
 *   DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / ChaCha20Poly1305
 *
 * which matches the primitives the LP author committed to in
 * `~/Desktop/sealed-lp/sealed-landing-page/LP-INTEGRATION.md`.
 *
 * Wire format (all bytes, no length prefixes — enc is fixed-width):
 *
 *   version (1B = 0x01) || enc (32B) || aead_output (plaintext_len + 16B tag)
 *
 *   - `version`     forward-compat domain separator; bumped if the construction
 *                   changes. Open() rejects any other value.
 *   - `enc`         HPKE encapsulated key (X25519 ephemeral public key).
 *   - `aead_output` ChaCha20-Poly1305 ciphertext concatenated with the
 *                   16-byte authentication tag.
 *
 * HPKE `info` is `"sealed.codes.v1"` (UTF-8), also bumped on construction
 * changes — gives KDF-level domain separation in addition to the version
 * byte. HPKE `aad` is empty.
 *
 * Plaintext is UTF-8 JSON:
 *
 *   { "codes": ["XXXX-XXXX-XXXX-XXXX", ...],
 *     "purchasedAtRound": "<uint64 as decimal string>" }
 *
 * `purchasedAtRound` is a string so uint64 round numbers survive the JSON
 * round-trip without losing precision.
 *
 * KEEP IN SYNC with the LP-side decrypter — golden roundtrip tests live in
 * test/preimage-server/crypto.test.ts. The LP author MUST mirror the
 * version byte, the info string, the aad-is-empty choice, and the
 * plaintext schema.
 */

import type { CipherSuite } from 'hpke-js';

export const WIRE_VERSION = 0x01;
export const WIRE_INFO = new TextEncoder().encode('sealed.codes.v1');
export const KEM_ENC_LEN = 32; // X25519 public key size
export const AEAD_TAG_LEN = 16; // ChaCha20-Poly1305 Poly1305 tag

export interface DeliveryPayload {
  codes: string[];
  purchasedAtRound: bigint;
}

let cachedSuite: Promise<CipherSuite> | null = null;

async function getSuite(): Promise<CipherSuite> {
  if (!cachedSuite) {
    cachedSuite = (async (): Promise<CipherSuite> => {
      const hpke = await import('hpke-js');
      return new hpke.CipherSuite({
        kem: hpke.Kem.DhkemX25519HkdfSha256,
        kdf: hpke.Kdf.HkdfSha256,
        aead: hpke.Aead.Chacha20Poly1305,
      });
    })();
  }
  return cachedSuite;
}

function assertDeliveryPubkey(pub: Uint8Array): void {
  if (pub.length !== KEM_ENC_LEN) {
    throw new Error(`deliveryPubkey must be ${KEM_ENC_LEN} bytes (got ${pub.length})`);
  }
  let any = 0;
  for (let i = 0; i < pub.length; i++) any |= pub[i];
  if (any === 0) throw new Error('deliveryPubkey must not be all-zero');
}

function assertPayload(payload: DeliveryPayload): void {
  if (!Array.isArray(payload.codes) || payload.codes.length === 0) {
    throw new Error('payload.codes must be a non-empty array');
  }
  for (const c of payload.codes) {
    if (typeof c !== 'string' || c.length === 0) {
      throw new Error('payload.codes entries must be non-empty strings');
    }
  }
  if (typeof payload.purchasedAtRound !== 'bigint' || payload.purchasedAtRound < 0n) {
    throw new Error('payload.purchasedAtRound must be a non-negative bigint');
  }
}

function encodePlaintext(payload: DeliveryPayload): Uint8Array {
  return new TextEncoder().encode(
    JSON.stringify({
      codes: payload.codes,
      purchasedAtRound: payload.purchasedAtRound.toString(),
    }),
  );
}

interface ParsedDeliveryJson {
  codes: unknown;
  purchasedAtRound: unknown;
}

function decodePlaintext(bytes: Uint8Array): DeliveryPayload {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  let parsed: ParsedDeliveryJson;
  try {
    parsed = JSON.parse(text) as ParsedDeliveryJson;
  } catch (e) {
    throw new Error(`plaintext is not valid JSON: ${e instanceof Error ? e.message : String(e)}`);
  }
  if (!Array.isArray(parsed.codes) || parsed.codes.length === 0) {
    throw new Error('plaintext missing or empty `codes`');
  }
  for (const c of parsed.codes) {
    if (typeof c !== 'string') throw new Error('plaintext `codes` entries must be strings');
  }
  if (typeof parsed.purchasedAtRound !== 'string') {
    throw new Error('plaintext `purchasedAtRound` must be a string');
  }
  let round: bigint;
  try {
    round = BigInt(parsed.purchasedAtRound);
  } catch {
    throw new Error('plaintext `purchasedAtRound` is not a decimal integer');
  }
  if (round < 0n) throw new Error('plaintext `purchasedAtRound` must be non-negative');
  return { codes: parsed.codes, purchasedAtRound: round };
}

/**
 * Encrypt a delivery payload to the buyer's per-purchase `deliveryPubkey`.
 * Output is the framed wire bytes ready to persist in sqlite and serve
 * verbatim from `GET /delivery/<hex>`.
 */
export async function sealForDelivery(
  payload: DeliveryPayload,
  deliveryPubkey: Uint8Array,
): Promise<Uint8Array> {
  assertDeliveryPubkey(deliveryPubkey);
  assertPayload(payload);

  const suite = await getSuite();
  const recipientPublicKey = await suite.kem.importKey('raw', deliveryPubkey, true);
  const sender = await suite.createSenderContext({
    recipientPublicKey,
    info: WIRE_INFO,
  });

  const plaintext = encodePlaintext(payload);
  const aeadOutput = new Uint8Array(await sender.seal(plaintext));
  const enc = new Uint8Array(sender.enc);
  if (enc.length !== KEM_ENC_LEN) {
    throw new Error(`unexpected enc length: ${enc.length}`);
  }

  const wire = new Uint8Array(1 + KEM_ENC_LEN + aeadOutput.length);
  wire[0] = WIRE_VERSION;
  wire.set(enc, 1);
  wire.set(aeadOutput, 1 + KEM_ENC_LEN);
  return wire;
}

/**
 * Inverse of `sealForDelivery` — used by tests and as a reference
 * implementation for the LP author. The sidecar itself never decrypts
 * its own output; it only sells, never reads.
 */
export async function openForDelivery(
  wire: Uint8Array,
  deliveryPrivkey: Uint8Array,
): Promise<DeliveryPayload> {
  if (deliveryPrivkey.length !== KEM_ENC_LEN) {
    throw new Error(`deliveryPrivkey must be ${KEM_ENC_LEN} bytes (got ${deliveryPrivkey.length})`);
  }
  if (wire.length < 1 + KEM_ENC_LEN + AEAD_TAG_LEN) {
    throw new Error('wire too short');
  }
  const version = wire[0];
  if (version !== WIRE_VERSION) {
    throw new Error(`unsupported wire version: ${version} (expected ${WIRE_VERSION})`);
  }
  const enc = wire.slice(1, 1 + KEM_ENC_LEN);
  const aeadOutput = wire.slice(1 + KEM_ENC_LEN);

  const suite = await getSuite();
  const recipientPrivateKey = await suite.kem.importKey('raw', deliveryPrivkey, false);
  const recipient = await suite.createRecipientContext({
    recipientKey: recipientPrivateKey,
    enc,
    info: WIRE_INFO,
  });
  const plaintext = new Uint8Array(await recipient.open(aeadOutput));
  return decodePlaintext(plaintext);
}

/**
 * Generate a fresh X25519 keypair in the same format the LP would
 * generate in-browser. Exposed for tests and admin smoke tooling, NOT
 * called by the sidecar's runtime path.
 */
export async function generateDeliveryKeypairForTest(): Promise<{
  publicKey: Uint8Array;
  privateKey: Uint8Array;
}> {
  const suite = await getSuite();
  const kp = await suite.kem.generateKeyPair();
  // hpke-js returns CryptoKey objects; serialize to raw bytes for parity
  // with how the LP receives the pubkey on chain.
  const pub = new Uint8Array(await suite.kem.serializePublicKey(kp.publicKey));
  const priv = new Uint8Array(await suite.kem.serializePrivateKey(kp.privateKey));
  return { publicKey: pub, privateKey: priv };
}

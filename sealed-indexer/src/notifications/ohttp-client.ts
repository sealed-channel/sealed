/**
 * OHTTP client for wrapped HTTP requests via relay (RFC 9458).
 *
 * Inner request is encoded as RFC 9292 Binary HTTP, then HPKE-encrypted using
 * the suite advertised by the relay's key config.
 *
 * Encapsulated request layout:
 *   hdr(7) || enc(Npk) || ciphertext || tag(16)
 * where:
 *   hdr      = keyId(1) || kemId(2) || kdfId(2) || aeadId(2)
 *   enc      = ephemeral KEM public key (32 bytes for X25519)
 *   info     = "message/bhttp request" || 0x00 || hdr   (RFC 9458 §4.3)
 *   AAD      = empty
 *
 * Matches the Flutter client at sealed_app/lib/remote/ohttp/ — both sides
 * MUST agree on framing or the relay returns 400.
 */

import { parseOhttpConfig, type OhttpConfig } from './ohttp-config';
import { encodeRequest, decodeResponse, type BinaryHttpResponse } from './binary-http';

export interface OhttpRequest {
  method: 'POST' | 'GET' | 'PUT' | 'DELETE';
  url: string;
  headers: Record<string, string>;
  body: Buffer;
}

export interface OhttpResponse {
  status: number;
  body: Buffer;
}

export interface OhttpClient {
  send(request: OhttpRequest): Promise<OhttpResponse>;
}

export interface OhttpClientOptions {
  relayUrl: string;
  keyConfigFetcher: () => Promise<Buffer>;
  fetchImpl?: typeof fetch;
}

export function createOhttpClient(opts: OhttpClientOptions): OhttpClient {
  const { relayUrl, keyConfigFetcher, fetchImpl = globalThis.fetch } = opts;

  return {
    async send(request: OhttpRequest): Promise<OhttpResponse> {
      try {
        const keyConfigBytes = await keyConfigFetcher();
        const config = parseOhttpConfig(keyConfigBytes);

        // 1. Encode inner HTTP request as RFC 9292 binary HTTP.
        const bhttpRequest = encodeRequest({
          method: request.method,
          url: request.url,
          headers: request.headers,
          body: new Uint8Array(request.body),
        });

        // 2. HPKE-seal it with the relay's public key.
        const { encapsulated, secret, enc } = await encapsulateRequest(
          config,
          bhttpRequest,
        );

        // 3. POST to the relay.
        const response = await fetchImpl(relayUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'message/ohttp-req' },
          body: encapsulated,
        });

        if (!response.ok) {
          throw new Error(`Relay responded with ${response.status}`);
        }

        // 4. Decapsulate the relay's response.
        const encryptedResponse = new Uint8Array(await response.arrayBuffer());
        const inner = await decapsulateResponse(encryptedResponse, enc, secret);

        return {
          status: inner.statusCode,
          body: Buffer.from(inner.body),
        };
      } catch (error) {
        const message = error instanceof Error ? error.message : 'Unknown error';
        throw new Error(`OHTTP client error: ${message}`);
      }
    },
  };
}

// ===========================================================================
// HPKE encapsulation (RFC 9180 + RFC 9458 §4.3)
// ===========================================================================

/**
 * Encapsulate `bhttpRequest` for OHTTP. Returns the on-the-wire bytes
 * (`hdr || enc || ct || tag`) plus the export `secret` + `enc` needed to
 * decapsulate the relay's response.
 *
 * We currently support only the suite Nodely's relay advertises:
 *   DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM
 * If the config advertises a different suite, we throw — the Flutter client
 * has the same constraint.
 */
async function encapsulateRequest(
  config: OhttpConfig,
  bhttpRequest: Uint8Array,
): Promise<{ encapsulated: Uint8Array; secret: Uint8Array; enc: Uint8Array }> {
  if (config.kemId !== 0x0020 || config.kdfId !== 0x0001 || config.aeadId !== 0x0001) {
    throw new Error(
      `Unsupported OHTTP suite kem=0x${config.kemId.toString(16)} ` +
        `kdf=0x${config.kdfId.toString(16)} aead=0x${config.aeadId.toString(16)} ` +
        `(only DHKEM-X25519/HKDF-SHA256/AES-128-GCM is implemented)`,
    );
  }

  const hpke = await import('hpke-js');
  const suite = new hpke.CipherSuite({
    kem: hpke.Kem.DhkemX25519HkdfSha256,
    kdf: hpke.Kdf.HkdfSha256,
    aead: hpke.Aead.Aes128Gcm,
  });

  // hdr = keyId(1) || kemId(2) || kdfId(2) || aeadId(2)
  const hdr = new Uint8Array([
    config.keyId,
    (config.kemId >> 8) & 0xff, config.kemId & 0xff,
    (config.kdfId >> 8) & 0xff, config.kdfId & 0xff,
    (config.aeadId >> 8) & 0xff, config.aeadId & 0xff,
  ]);

  // info = "message/bhttp request" || 0x00 || hdr (RFC 9458 §4.3)
  const infoPrefix = new TextEncoder().encode('message/bhttp request');
  const info = new Uint8Array(infoPrefix.length + 1 + hdr.length);
  info.set(infoPrefix, 0);
  info[infoPrefix.length] = 0x00;
  info.set(hdr, infoPrefix.length + 1);

  // hpke-js 1.x requires importKey for ALL KEMs (including X25519); raw
  // Uint8Array yields "Cannot read properties of undefined (reading 'buffer')".
  const recipientPublicKey = await suite.kem.importKey('raw', config.publicKey, true);

  const sender = await suite.createSenderContext({
    recipientPublicKey,
    info,
  });

  const ct = new Uint8Array(await sender.seal(bhttpRequest));
  const enc = new Uint8Array(sender.enc);

  // Export secret for response decapsulation. RFC 9458 §4.3:
  //   secret = context.Export("message/bhttp response", Nk)
  // where Nk is the AEAD key length — 16 for AES-128-GCM (NOT 32). Using 32
  // here silently produces the wrong response-AEAD key and the gateway's
  // response fails to authenticate ("Unsupported state or unable to authenticate
  // data"). Matches the Flutter client which also exports Nk=16.
  const exportContext = new TextEncoder().encode('message/bhttp response');
  const secret = new Uint8Array(await sender.export(exportContext, 16));

  // Encapsulated = hdr || enc || ct (ct already includes the 16-byte AEAD tag)
  const encapsulated = new Uint8Array(hdr.length + enc.length + ct.length);
  encapsulated.set(hdr, 0);
  encapsulated.set(enc, hdr.length);
  encapsulated.set(ct, hdr.length + enc.length);

  return { encapsulated, secret, enc };
}

/**
 * Decapsulate an OHTTP response (RFC 9458 §4.4).
 *
 *   encryptedResponse = responseNonce(max(Nk,Nn)) || ciphertext || tag
 *   salt   = enc || responseNonce
 *   prk    = HKDF-Extract(salt, secret)
 *   key    = HKDF-Expand(prk, "key",   Nk=16)
 *   nonce  = HKDF-Expand(prk, "nonce", Nn=12)
 */
async function decapsulateResponse(
  encryptedResponse: Uint8Array,
  enc: Uint8Array,
  secret: Uint8Array,
): Promise<BinaryHttpResponse> {
  const Nk = 16; // AES-128-GCM key length
  const Nn = 12; // AES-GCM nonce length
  const responseNonceLen = Math.max(Nk, Nn); // 16

  if (encryptedResponse.length < responseNonceLen + 16) {
    throw new Error('OHTTP response too short');
  }

  const responseNonce = encryptedResponse.subarray(0, responseNonceLen);
  const encResponse = encryptedResponse.subarray(responseNonceLen);

  const salt = new Uint8Array(enc.length + responseNonce.length);
  salt.set(enc, 0);
  salt.set(responseNonce, enc.length);

  const { createHmac } = await import('crypto');
  const prk = hkdfExtract(salt, secret, createHmac);
  const key = hkdfExpand(prk, new TextEncoder().encode('key'), Nk, createHmac);
  const nonce = hkdfExpand(prk, new TextEncoder().encode('nonce'), Nn, createHmac);

  // AES-128-GCM open with empty AAD.
  const { createDecipheriv } = await import('crypto');
  const tagStart = encResponse.length - 16;
  const ct = encResponse.subarray(0, tagStart);
  const tag = encResponse.subarray(tagStart);

  const decipher = createDecipheriv('aes-128-gcm', key, nonce);
  decipher.setAuthTag(tag);
  const part1 = decipher.update(ct);
  const part2 = decipher.final();
  const plaintext = new Uint8Array(part1.length + part2.length);
  plaintext.set(part1, 0);
  plaintext.set(part2, part1.length);

  return decodeResponse(plaintext);
}

// HKDF-Extract (RFC 5869): PRK = HMAC(salt, IKM)
function hkdfExtract(
  salt: Uint8Array,
  ikm: Uint8Array,
  createHmac: typeof import('crypto').createHmac,
): Uint8Array {
  return new Uint8Array(createHmac('sha256', salt).update(ikm).digest());
}

// HKDF-Expand (RFC 5869) with empty info length-prefix (RFC 9180 LabeledExpand
// is NOT used here — RFC 9458 §4.4 uses plain HKDF-Expand for the response key).
function hkdfExpand(
  prk: Uint8Array,
  info: Uint8Array,
  length: number,
  createHmac: typeof import('crypto').createHmac,
): Uint8Array {
  const hashLen = 32;
  const n = Math.ceil(length / hashLen);
  const out = new Uint8Array(n * hashLen);
  let prev = new Uint8Array(0);
  for (let i = 1; i <= n; i++) {
    const h = createHmac('sha256', prk);
    h.update(prev);
    h.update(info);
    h.update(Uint8Array.of(i));
    prev = new Uint8Array(h.digest());
    out.set(prev, (i - 1) * hashLen);
  }
  return out.subarray(0, length);
}

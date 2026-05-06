/**
 * Parsed OHTTP gateway key configuration (RFC 9458 §3).
 *
 * Wire format:
 *   keyId(1) || kemId(2 BE) || publicKey(variable) ||
 *   symmetric_algorithms_length(2 BE) || [kdfId(2 BE) | aeadId(2 BE)]+
 *
 * We pick the FIRST advertised symmetric algorithm pair, matching the Flutter
 * client at sealed_app/lib/remote/ohttp/ohttp_config.dart.
 */
export interface OhttpConfig {
  keyId: number;
  kemId: number;
  kdfId: number;
  aeadId: number;
  publicKey: Uint8Array;
}

export function parseOhttpConfig(bytes: Buffer | Uint8Array): OhttpConfig {
  const buf = bytes instanceof Buffer ? new Uint8Array(bytes) : bytes;
  if (buf.length < 7) throw new Error('OHTTP config too short');

  let off = 0;
  const keyId = buf[off++];
  const kemId = (buf[off] << 8) | buf[off + 1];
  off += 2;

  const pubKeySize = kemPublicKeySize(kemId);
  if (buf.length < off + pubKeySize + 4) {
    throw new Error(
      `OHTTP config too short for KEM ${kemId} ` +
        `(need ${off + pubKeySize + 4}, got ${buf.length})`,
    );
  }
  const publicKey = buf.subarray(off, off + pubKeySize);
  off += pubKeySize;

  const symLen = (buf[off] << 8) | buf[off + 1];
  off += 2;
  if (symLen < 4 || buf.length < off + 4) {
    throw new Error('OHTTP config: no symmetric algorithms present');
  }

  const kdfId = (buf[off] << 8) | buf[off + 1];
  const aeadId = (buf[off + 2] << 8) | buf[off + 3];

  return { keyId, kemId, kdfId, aeadId, publicKey };
}

function kemPublicKeySize(kemId: number): number {
  switch (kemId) {
    case 0x0020: // DHKEM(X25519, HKDF-SHA256)
    case 0x0021: // DHKEM(X25519, HKDF-SHA512)
      return 32;
    case 0x0010: // DHKEM(P-256, HKDF-SHA256)
      return 65;
    case 0x0011: // DHKEM(P-384, HKDF-SHA384)
      return 97;
    case 0x0012: // DHKEM(P-521, HKDF-SHA512)
      return 133;
    default:
      throw new Error(`Unsupported KEM ID: 0x${kemId.toString(16)}`);
  }
}

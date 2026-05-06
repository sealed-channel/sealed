import 'dart:typed_data';

/// Parsed OHTTP gateway key configuration (RFC 9458 §3).
///
/// The binary format is:
///   keyId (1 byte) | kemId (2 bytes BE) | publicKey (variable) |
///   symmetric_algorithms_length (2 bytes BE) |
///   [kdfId (2 bytes BE) | aeadId (2 bytes BE)]*
///
/// We use the first symmetric algorithm pair.
class OhttpConfig {
  /// Key identifier (used by gateway to select the right key)
  final int keyId;

  /// KEM algorithm identifier (e.g. 0x0020 = DHKEM(X25519, HKDF-SHA256))
  final int kemId;

  /// KDF algorithm identifier (e.g. 0x0001 = HKDF-SHA256)
  final int kdfId;

  /// AEAD algorithm identifier (e.g. 0x0001 = AES-128-GCM)
  final int aeadId;

  /// Gateway's KEM public key (32 bytes for X25519)
  final Uint8List publicKey;

  OhttpConfig({
    required this.keyId,
    required this.kemId,
    required this.kdfId,
    required this.aeadId,
    required this.publicKey,
  });

  /// Parse binary key configuration from gateway.
  ///
  /// Throws [FormatException] if the config is malformed.
  factory OhttpConfig.fromBytes(Uint8List bytes) {
    if (bytes.length < 7) {
      throw const FormatException('OHTTP config too short');
    }

    int offset = 0;

    // keyId: 1 byte
    final keyId = bytes[offset];
    offset += 1;

    // kemId: 2 bytes big-endian
    final kemId = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;

    // Determine public key size from KEM ID
    final pubKeySize = _kemPublicKeySize(kemId);
    if (bytes.length < offset + pubKeySize + 4) {
      throw FormatException(
        'OHTTP config too short for KEM $kemId (need ${offset + pubKeySize + 4} bytes, got ${bytes.length})',
      );
    }

    // publicKey: variable length
    final publicKey = Uint8List.fromList(
      bytes.sublist(offset, offset + pubKeySize),
    );
    offset += pubKeySize;

    // symmetric_algorithms_length: 2 bytes big-endian
    final symLen = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;

    if (symLen < 4 || bytes.length < offset + 4) {
      throw const FormatException(
        'OHTTP config: no symmetric algorithms present',
      );
    }

    // First symmetric algorithm pair: kdfId (2) + aeadId (2)
    final kdfId = (bytes[offset] << 8) | bytes[offset + 1];
    final aeadId = (bytes[offset + 2] << 8) | bytes[offset + 3];

    return OhttpConfig(
      keyId: keyId,
      kemId: kemId,
      kdfId: kdfId,
      aeadId: aeadId,
      publicKey: publicKey,
    );
  }

  /// Returns the public key size in bytes for a given KEM ID.
  static int _kemPublicKeySize(int kemId) {
    switch (kemId) {
      case 0x0020: // DHKEM(X25519, HKDF-SHA256)
        return 32;
      case 0x0021: // DHKEM(X25519, HKDF-SHA512)
        return 32;
      case 0x0010: // DHKEM(P-256, HKDF-SHA256)
        return 65;
      case 0x0011: // DHKEM(P-384, HKDF-SHA384)
        return 97;
      case 0x0012: // DHKEM(P-521, HKDF-SHA512)
        return 133;
      default:
        throw FormatException(
          'Unsupported KEM ID: 0x${kemId.toRadixString(16)}',
        );
    }
  }

  @override
  String toString() =>
      'OhttpConfig(keyId: $keyId, kem: 0x${kemId.toRadixString(16)}, '
      'kdf: 0x${kdfId.toRadixString(16)}, aead: 0x${aeadId.toRadixString(16)}, '
      'pubKeyLen: ${publicKey.length})';
}

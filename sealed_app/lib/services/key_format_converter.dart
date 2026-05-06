/// Cryptographic key format conversion utilities.
/// Ed25519 ↔ X25519 conversion for cross-curve compatibility,
/// and legacy Solana → Algorand key migration helpers.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ed25519 ↔ X25519 key conversion utilities.
///
/// Ed25519 (twisted Edwards curve) and X25519 (Montgomery curve) are
/// birationally equivalent over the same finite field GF(2^255-19).
///
/// These conversions allow using a Solana wallet's Ed25519 keypair for
/// X25519 ECDH operations, enabling message encryption to wallets that
/// haven't published separate X25519 keys yet.

final BigInt _p = BigInt.two.pow(255) - BigInt.from(19);

/// Convert an Ed25519 public key (compressed Edwards y-coordinate) to
/// an X25519 public key (Montgomery u-coordinate).
///
/// Formula: u = (1 + y) / (1 - y) mod p
///
/// This is the standard birational map used by libsodium's
/// `crypto_sign_ed25519_pk_to_curve25519`.
Uint8List ed25519PublicKeyToX25519(Uint8List edPubkey) {
  if (edPubkey.length != 32) {
    throw ArgumentError('Ed25519 public key must be 32 bytes');
  }

  // Decode y-coordinate (little-endian, clear sign bit)
  BigInt y = BigInt.zero;
  for (int i = 0; i < 32; i++) {
    int byte = edPubkey[i];
    if (i == 31) byte &= 0x7F; // Clear sign bit (top bit of last byte)
    y += BigInt.from(byte) << (8 * i);
  }

  // u = (1 + y) * modInverse(1 - y, p) mod p
  final numerator = (BigInt.one + y) % _p;
  final denominator = (_p + BigInt.one - y) % _p;

  if (denominator == BigInt.zero) {
    // y == 1 → identity point, not a valid public key for messaging
    throw ArgumentError('Invalid Ed25519 public key: degenerate point');
  }

  final u = (numerator * denominator.modInverse(_p)) % _p;

  // Encode u as 32-byte little-endian
  final result = Uint8List(32);
  BigInt temp = u;
  for (int i = 0; i < 32; i++) {
    result[i] = (temp & BigInt.from(0xFF)).toInt();
    temp >>= 8;
  }

  return result;
}

/// Convert an Ed25519 seed (32-byte private key) to an X25519 private key.
///
/// This mirrors libsodium's `crypto_sign_ed25519_sk_to_curve25519`:
///   1. Hash the Ed25519 seed with SHA-512
///   2. Take the first 32 bytes
///   3. Apply X25519 clamping
///
/// The resulting X25519 private key corresponds to the X25519 public key
/// obtained from [ed25519PublicKeyToX25519] on the matching Ed25519 public key.
Future<Uint8List> ed25519SeedToX25519Seed(Uint8List ed25519Seed) async {
  if (ed25519Seed.length != 32) {
    throw ArgumentError('Ed25519 seed must be 32 bytes');
  }

  final sha512 = Sha512();
  final hash = await sha512.hash(ed25519Seed);
  final x25519Seed = Uint8List.fromList(hash.bytes.sublist(0, 32));

  // Clamp for X25519 (matches RFC 7748)
  x25519Seed[0] &= 248;
  x25519Seed[31] &= 127;
  x25519Seed[31] |= 64;

  return x25519Seed;
}

/// Build an X25519 keypair from an Ed25519 seed.
///
/// This produces the X25519 key pair that corresponds (via the birational map)
/// to the Ed25519 key pair derived from the same seed. The X25519 public key
/// equals `ed25519PublicKeyToX25519(ed25519PublicKey)`.
Future<SimpleKeyPair> ed25519SeedToX25519KeyPair(Uint8List ed25519Seed) async {
  final x25519Seed = await ed25519SeedToX25519Seed(ed25519Seed);
  return X25519().newKeyPairFromSeed(x25519Seed);
}

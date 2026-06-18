import 'dart:typed_data';

/// Holds the subset of cryptographic public keys cached for a contact.
/// Any field may be null if that key has not yet been stored.
class ContactKeys {
  final Uint8List? pqPublicKey;
  final Uint8List? pqSharedSecret;
  final Uint8List? encryptionPubkey;
  final Uint8List? scanPubkey;

  const ContactKeys({
    this.pqPublicKey,
    this.pqSharedSecret,
    this.encryptionPubkey,
    this.scanPubkey,
  });
}

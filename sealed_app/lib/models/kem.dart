import 'dart:typed_data';

class KemResult {
  final Uint8List ciphertext; // 768 bytes (ML-KEM-512)
  final Uint8List sharedSecret; // 32 bytes

  KemResult({required this.ciphertext, required this.sharedSecret});
}

class PqKeyPair {
  final Uint8List publicKey; // 800 bytes (ML-KEM-512)
  final Uint8List privateKey; // 1632 bytes

  PqKeyPair({required this.publicKey, required this.privateKey});
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SealedKeys {
  final SimpleKeyPair encryptionKeyPair;
  final SimpleKeyPair scanKeyPair;
  final String walletAddress;

  Uint8List get scanPubkey => _scanPubkey;
  Uint8List get encryptionPubkey => _encryptionPubkey;
  Uint8List get viewPrivateKey => _viewPrivateKey;
  Uint8List get encryptionPrivateKey => _encryptionPrivateKey;

  String get scanPubkeyBase64 => base64.encode(_scanPubkey);
  String get encryptionPubkeyBase64 => base64.encode(_encryptionPubkey);
  String get viewPrivateKeyBase64 => base64.encode(_viewPrivateKey);
  String get encryptionPrivateKeyBase64 => base64.encode(_encryptionPrivateKey);

  final Uint8List _scanPubkey;
  final Uint8List _encryptionPubkey;
  final Uint8List _encryptionPrivateKey;
  final Uint8List _viewPrivateKey;

  /// ML-KEM-512 public key (800 bytes).
  final Uint8List pqPublicKey;

  /// ML-KEM-512 private key (1632 bytes).
  final Uint8List pqPrivateKey;

  String get pqPublicKeyBase64 => base64.encode(pqPublicKey);
  String get pqPrivateKeyBase64 => base64.encode(pqPrivateKey);

  SealedKeys({
    required this.encryptionKeyPair,
    required this.scanKeyPair,
    required this.walletAddress,
    required Uint8List scanPubkey,
    required Uint8List encryptionPubkey,
    required Uint8List encryptionPrivateKey,
    required Uint8List viewPrivateKey,
    required Uint8List pqPublicKey,
    required Uint8List pqPrivateKey,
  }) : _scanPubkey = Uint8List.fromList(scanPubkey),
       _encryptionPubkey = Uint8List.fromList(encryptionPubkey),
       _encryptionPrivateKey = Uint8List.fromList(encryptionPrivateKey),
       _viewPrivateKey = Uint8List.fromList(viewPrivateKey),
       pqPublicKey = Uint8List.fromList(pqPublicKey),
       pqPrivateKey = Uint8List.fromList(pqPrivateKey);

  factory SealedKeys.fromBase64({
    required SimpleKeyPair encryptionKeyPair,
    required SimpleKeyPair scanKeyPair,
    required String walletAddress,
    required String scanPubkeyBase64,
    required String encryptionPubkeyBase64,
    required String encryptionPrivateKeyBase64,
    required String viewPrivateKeyBase64,
    required String pqPublicKeyBase64,
    required String pqPrivateKeyBase64,
  }) {
    return SealedKeys(
      encryptionKeyPair: encryptionKeyPair,
      scanKeyPair: scanKeyPair,
      walletAddress: walletAddress,
      scanPubkey: base64.decode(scanPubkeyBase64),
      encryptionPubkey: base64.decode(encryptionPubkeyBase64),
      encryptionPrivateKey: base64.decode(encryptionPrivateKeyBase64),
      viewPrivateKey: base64.decode(viewPrivateKeyBase64),
      pqPublicKey: base64.decode(pqPublicKeyBase64),
      pqPrivateKey: base64.decode(pqPrivateKeyBase64),
    );
  }

  Map<String, String> toBase64Map() {
    final map = <String, String>{
      'walletAddress': walletAddress,
      'scanPubkey': scanPubkeyBase64,
      'encryptionPubkey': encryptionPubkeyBase64,
      'encryptionPrivateKey': encryptionPrivateKeyBase64,
      'viewPrivateKey': viewPrivateKeyBase64,
    };
    map['pqPublicKey'] = pqPublicKeyBase64;
    map['pqPrivateKey'] = pqPrivateKeyBase64;
    return map;
  }

  void dispose() {
    // Overwrite sensitive bytes when done
    for (var i = 0; i < _encryptionPrivateKey.length; i++) {
      _encryptionPrivateKey[i] = 0;
    }
    for (var i = 0; i < _viewPrivateKey.length; i++) {
      _viewPrivateKey[i] = 0;
    }
    for (var i = 0; i < pqPrivateKey.length; i++) {
      pqPrivateKey[i] = 0;
    }
  }
}

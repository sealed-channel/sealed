import 'dart:convert';

import 'package:bip39/bip39.dart' as bip39;
import 'package:blockchain_utils/bip/address/algo_addr.dart';
import 'package:blockchain_utils/bip/algorand/algorand.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:sealed_app/chain/wallet_interface.dart';

class AlgorandWallet implements ChainWallet {
  final FlutterSecureStorage _secureStorage;

  SigningKey? _signingKey;
  String? _mnemonic;
  String? _walletAddress;

  AlgorandWallet(this._secureStorage);

  @override
  String get chainId => 'algorand';

  @override
  String? get walletAddress => _walletAddress;

  @override
  bool get hasWallet => _walletAddress != null;

  @override
  Future<void> createWallet() async {
    // New wallets ship in the Algorand-native 25-word format so the recovery
    // phrase is interoperable with Pera, Defly, MyAlgo, etc.
    final mnemonic = AlgorandMnemonicGenerator().fromWordsNumber(
      AlgorandWordsNum.wordsNum25,
    );
    _mnemonic = mnemonic.toStr();
    final seed = _seedFromMnemonic(_mnemonic!);
    _signingKey = SigningKey.fromSeed(seed);
    _walletAddress = _addressFromPublicKey(
      Uint8List.fromList(_signingKey!.verifyKey.asTypedList),
    );
    await _saveToStorage();
  }

  @override
  Future<void> restoreWallet(String mnemonic) async {
    _mnemonic = mnemonic;
    final seed = _seedFromMnemonic(mnemonic);
    _signingKey = SigningKey.fromSeed(seed);
    _walletAddress = _addressFromPublicKey(
      Uint8List.fromList(_signingKey!.verifyKey.asTypedList),
    );
    await _saveToStorage();
  }

  @override
  Future<void> loadExistingWallet() async {
    try {
      _mnemonic = await _secureStorage.read(key: 'algo_mnemonic');
    } on PlatformException catch (e) {
      // Android Keystore corruption (BAD_DECRYPT) – clear unusable data
      // so the user can start fresh instead of being stuck.
      print(
        '⚠️ AlgorandWallet: Secure storage read failed (${e.message}), '
        'clearing corrupted wallet data',
      );
      await _secureStorage.delete(key: 'algo_mnemonic');
      await _secureStorage.delete(key: 'algo_address');
      _mnemonic = null;
      _signingKey = null;
      _walletAddress = null;
      return;
    }
    if (_mnemonic == null) return;
    final seed = _seedFromMnemonic(_mnemonic!);
    _signingKey = SigningKey.fromSeed(seed);
    _walletAddress = _addressFromPublicKey(
      Uint8List.fromList(_signingKey!.verifyKey.asTypedList),
    );
  }

  @override
  Future<Uint8List> getSeedBytes() async {
    if (_mnemonic == null) throw StateError('No wallet loaded');
    return _seedFromMnemonic(_mnemonic!);
  }

  @override
  Future<String?> getMnemonic() async => _mnemonic;

  @override
  Future<Uint8List> signTransactionBytes(Uint8List txBytes) async {
    if (_signingKey == null) throw StateError('No wallet loaded');
    final signedMsg = _signingKey!.sign(txBytes);
    // Return raw 64-byte Ed25519 signature only (not sig+message)
    return Uint8List.fromList(signedMsg.signature.asTypedList);
  }

  @override
  Future<Uint8List> signMessage(String message) async {
    if (_signingKey == null) throw StateError('No wallet loaded');
    final messageBytes = Uint8List.fromList(utf8.encode(message));
    final signedMsg = _signingKey!.sign(messageBytes);
    return Uint8List.fromList(signedMsg.signature.asTypedList);
  }

  @override
  Future<int> getBalance() async {
    // Implemented via AlgorandChainClient's algod connection
    return 0;
  }

  @override
  Future<void> deleteWallet() async {
    await _secureStorage.delete(key: 'algo_mnemonic');
    await _secureStorage.delete(key: 'algo_address');
    _signingKey = null;
    _mnemonic = null;
    _walletAddress = null;
  }

  /// Get raw Ed25519 public key bytes (32 bytes).
  Uint8List? get publicKeyBytes => _signingKey != null
      ? Uint8List.fromList(_signingKey!.verifyKey.asTypedList)
      : null;

  /// Derive the 32-byte Ed25519 seed from a recovery phrase.
  ///
  /// Two formats are accepted:
  ///   • **25 words** — Algorand-native: 24 entropy words + 1 checksum word.
  ///     Decoded with [AlgorandSeedGenerator] and is the standard Pera/Defly
  ///     format. This is what newly-created wallets use.
  ///   • **12 / 24 words** — legacy BIP39 path used by older Sealed installs
  ///     (and the in-app TestNet faucet). We feed the phrase through
  ///     `bip39.mnemonicToSeed` and take the first 32 bytes — the same
  ///     derivation those wallets were created with, so the on-chain address
  ///     stays unchanged.
  ///
  /// The same seed feeds [KeyService] for X25519 derivation, so the contract
  /// (32 bytes) must not change.
  Uint8List _seedFromMnemonic(String mnemonic) {
    final words = mnemonic.trim().split(RegExp(r'\s+'));
    if (words.length == 25) {
      final algoMnemonic = AlgorandMnemonic.fromString(mnemonic);
      final seedBytes = AlgorandSeedGenerator(algoMnemonic).generate();
      return Uint8List.fromList(seedBytes);
    }
    // Legacy BIP39 (12 or 24 words). Preserves existing addresses.
    final fullSeed = bip39.mnemonicToSeed(mnemonic);
    return Uint8List.fromList(fullSeed.sublist(0, 32));
  }

  Future<void> _saveToStorage() async {
    await _secureStorage.write(key: 'algo_mnemonic', value: _mnemonic);
    await _secureStorage.write(key: 'algo_address', value: _walletAddress);
  }

  /// Encode a 32-byte Ed25519 public key to an Algorand address.
  /// Delegates to AlgoAddrEncoder which applies sha512_256 checksum + base32.
  static String _addressFromPublicKey(Uint8List pubkey) {
    return AlgoAddrEncoder().encodeKey(pubkey.toList());
  }
}

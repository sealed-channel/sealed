import 'dart:convert';
import 'dart:isolate';
import 'package:sealed_app/core/log.dart';

import 'package:bip39/bip39.dart' as bip39;
import 'package:blockchain_utils/bip/address/algo_addr.dart';
import 'package:blockchain_utils/bip/algorand/algorand.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart';
import 'package:sealed_app/infra/chain/wallet_interface.dart';

/// Pure-CPU seed derivation, hoisted to top level so it can run inside
/// `Isolate.run` (closures sent to an isolate must not capture instance state).
/// Mirrors the two accepted phrase formats — see [AlgorandWallet._seedFromMnemonic].
Uint8List _computeSeedFromMnemonic(String mnemonic) {
  final words = mnemonic.trim().split(RegExp(r'\s+'));
  if (words.length == 25) {
    final algoMnemonic = AlgorandMnemonic.fromString(mnemonic);
    return Uint8List.fromList(AlgorandSeedGenerator(algoMnemonic).generate());
  }
  // Legacy BIP39 (12 or 24 words). Preserves existing addresses.
  final fullSeed = bip39.mnemonicToSeed(mnemonic);
  return Uint8List.fromList(fullSeed.sublist(0, 32));
}

class AlgorandWallet implements ChainWallet {
  final FlutterSecureStorage _secureStorage;

  SigningKey? _signingKey;
  String? _mnemonic;
  String? _walletAddress;

  // Memoized BIP39 seed. _seedFromMnemonic runs PBKDF2-HMAC-SHA512 (2048
  // iterations) which is called on every key derivation, X25519 fallback and
  // KEM-nonce derivation — cache it per mnemonic so we pay the cost once.
  Uint8List? _cachedSeedBytes;
  String? _cachedSeedMnemonic;

  AlgorandWallet(this._secureStorage);

  @override
  String get chainId => 'algorand';

  @override
  String? get walletAddress => _walletAddress;

  @override
  bool get hasWallet => _walletAddress != null;

  @override
  Future<void> createWallet() async {
    // Refuse to silently overwrite an existing wallet. Without this, a user who
    // backs out of the seed-backup screen and re-taps "Create account" would
    // generate a second wallet on top of the first, orphaning the original seed
    // (and any funds / on-chain identity bound to it). Restore goes through
    // restoreWallet, which is intentionally allowed to replace.
    final existing = await _secureStorage.read(key: 'algo_mnemonic');
    if (existing != null && existing.isNotEmpty) {
      throw StateError('A wallet already exists; refusing to overwrite it');
    }

    // New wallets use a 24-word BIP39 phrase (256 bits of entropy). The
    // 25-word Algorand-native format is preserved on the restore path for
    // legacy users but is no longer generated for new wallets.
    _mnemonic = bip39.generateMnemonic(strength: 256);
    final seed = await _seedFromMnemonic(_mnemonic!);
    _signingKey = SigningKey.fromSeed(seed);
    _walletAddress = _addressFromPublicKey(
      Uint8List.fromList(_signingKey!.verifyKey.asTypedList),
    );
    await _saveToStorage();
  }

  @override
  Future<void> restoreWallet(String mnemonic) async {
    _mnemonic = mnemonic;
    final seed = await _seedFromMnemonic(mnemonic);
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
      Log.d(
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
    final seed = await _seedFromMnemonic(_mnemonic!);
    _signingKey = SigningKey.fromSeed(seed);
    _walletAddress = _addressFromPublicKey(
      Uint8List.fromList(_signingKey!.verifyKey.asTypedList),
    );
  }

  @override
  Future<Uint8List> getSeedBytes() async {
    if (_mnemonic == null) throw StateError('No wallet loaded');
    // _seedFromMnemonic is async (isolate-offloaded); return its Future.
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
    _cachedSeedBytes = null;
    _cachedSeedMnemonic = null;
  }

  /// Get raw Ed25519 public key bytes (32 bytes).
  Uint8List? get publicKeyBytes => _signingKey != null
      ? Uint8List.fromList(_signingKey!.verifyKey.asTypedList)
      : null;

  /// Derive the 32-byte Ed25519 seed from a recovery phrase.
  ///
  /// Two formats are accepted:
  ///   • **25 words** — Algorand-native legacy format (24 entropy words +
  ///     1 checksum word). Decoded with [AlgorandSeedGenerator]. Accepted
  ///     on the restore path for users who created wallets before the
  ///     BIP39 default was introduced.
  ///   • **12 / 24 words** — BIP39 path. 24-word is the format used by
  ///     all wallets created after the BIP39 default change. 12-word is
  ///     the older Sealed legacy format. Both are fed through
  ///     `bip39.mnemonicToSeed` and the first 32 bytes are taken, which
  ///     preserves on-chain addresses for existing wallets.
  ///
  /// The same seed feeds [KeyService] for X25519 derivation, so the contract
  /// (32 bytes) must not change.
  /// The BIP39 branch runs PBKDF2-HMAC-SHA512 (2048 rounds), ~2 s on low-end
  /// devices, so the compute is offloaded to a worker isolate to keep the
  /// create/restore UI thread responsive. Cache-hits return without spawning
  /// an isolate. The 25-word Algorand path is cheap but rides the same isolate
  /// for uniformity.
  Future<Uint8List> _seedFromMnemonic(String mnemonic) async {
    if (mnemonic == _cachedSeedMnemonic && _cachedSeedBytes != null) {
      return _cachedSeedBytes!;
    }
    final seed = await Isolate.run(() => _computeSeedFromMnemonic(mnemonic));
    _cachedSeedMnemonic = mnemonic;
    _cachedSeedBytes = seed;
    return seed;
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

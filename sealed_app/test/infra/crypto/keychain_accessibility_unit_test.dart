import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/chain/wallet_interface.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/infra/local/dek_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Push-prefetch task Tk: the chain-decryption keys the background isolate must
/// read while the screen is locked carry iOS keychain accessibility
/// `first_unlock`; PIN/term/wallet keys and the wrapped DEK keep the
/// `whenUnlocked` default. These tests drive the real production write paths
/// (`KeyService.deriveKeys`, `DekManager.bootstrapIfNeeded`) through a recording
/// storage and assert the accessibility that each key was written with.
///
/// Accessibility is read back via `IOSOptions.toMap()['accessibility']` because
/// the enum field has no public getter. A write made with no `iOptions` records
/// `null` (keeps the `whenUnlocked` default).
void main() {
  group('Tk keychain accessibility', () {
    test('KeyService writes its 5 decryption keys with first_unlock', () async {
      final storage = _RecordingSecureStorage();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final keyService = KeyService(
        // A mnemonic is required so the PQ master-seed derivation completes and
        // pq_master_seed / pq_kem_* keys are actually written.
        chainWallet: _MnemonicWallet(),
        storage: storage,
        x25519: X25519(),
        hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
        prefs: prefs,
      );

      const walletAddress = '7Xf9kL2mN8pQ3rT5vW9x1234567890abcdef';
      final signature = base64.encode(List.generate(64, (i) => i));
      await keyService.deriveKeys(walletAddress, signature);

      for (final key in const [
        'enc_private',
        'view_private',
        'pq_master_seed',
        'pq_kem_pubkey',
        'pq_kem_privkey',
      ]) {
        expect(
          storage.accessibilityOf(key),
          'first_unlock',
          reason:
              '$key must be readable after first unlock for background sync',
        );
      }
    });

    test(
      'DekManager writes device_secret first_unlock, DEK stays default',
      () async {
        final storage = _RecordingSecureStorage();
        final dek = DekManager(storage: storage);

        final created = await dek.bootstrapIfNeeded();
        expect(created, isTrue);

        // The background isolate derives the staging-store KEK from this secret.
        expect(
          storage.accessibilityOf(DekStorageKeys.deviceSecret),
          'first_unlock',
        );

        // The wrapped DEK and its kind tag must NOT be background-readable — the
        // background isolate never opens the DEK DB (single-writer rule).
        expect(storage.accessibilityOf(DekStorageKeys.dekWrapped), isNull);
        expect(storage.accessibilityOf(DekStorageKeys.dekKekKind), isNull);
      },
    );
  });
}

/// Minimal [ChainWallet] returning a fixed mnemonic so PQ key derivation
/// completes. Only [getMnemonic] is exercised by these tests.
class _MnemonicWallet implements ChainWallet {
  @override
  Future<String?> getMnemonic() async =>
      'legal winner thank year wave sausage worth useful legal winner thank yellow';

  @override
  String get chainId => 'mock';
  @override
  String? get walletAddress => 'mock_wallet';
  @override
  bool get hasWallet => true;
  @override
  Future<Uint8List> getSeedBytes() async =>
      Uint8List.fromList(List.generate(32, (i) => i));
  @override
  Future<void> createWallet() async {}
  @override
  Future<void> restoreWallet(String mnemonic) async {}
  @override
  Future<void> loadExistingWallet() async {}
  @override
  Future<Uint8List> signTransactionBytes(Uint8List txBytes) async => txBytes;
  @override
  Future<Uint8List> signMessage(String message) async =>
      Uint8List.fromList(utf8.encode(message));
  @override
  Future<int> getBalance() async => 0;
  @override
  Future<void> deleteWallet() async {}
}

/// In-memory [FlutterSecureStorage] that records the [IOSOptions] each key was
/// last written with, so tests can assert the keychain accessibility.
class _RecordingSecureStorage implements FlutterSecureStorage {
  @override
  Map<String, List<ValueChanged<String?>>> get getListeners => const {};

  final Map<String, String> _values = {};
  final Map<String, AppleOptions?> _iOptionsByKey = {};

  /// The `accessibility` the given key was last written with, or `null` if the
  /// write passed no `iOptions` (i.e. the `whenUnlocked` default).
  String? accessibilityOf(String key) =>
      _iOptionsByKey[key]?.toMap()['accessibility'];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _iOptionsByKey[key] = iOptions;
    if (value != null) {
      _values[key] = value;
    } else {
      _values.remove(key);
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _values.remove(key);
    _iOptionsByKey.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _values.clear();
    _iOptionsByKey.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.from(_values);

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _values.containsKey(key);

  @override
  IOSOptions get iOptions => const IOSOptions();
  @override
  AndroidOptions get aOptions => const AndroidOptions();
  @override
  LinuxOptions get lOptions => const LinuxOptions();
  @override
  WebOptions get webOptions => const WebOptions();
  @override
  MacOsOptions get mOptions => const MacOsOptions();
  @override
  WindowsOptions get wOptions => const WindowsOptions();

  @override
  Future<bool> isCupertinoProtectedDataAvailable() async => true;
  @override
  Stream<bool> get onCupertinoProtectedDataAvailabilityChanged =>
      Stream.value(true);
  @override
  Future<void> registerListener({
    required String key,
    required ValueChanged<String?> listener,
  }) async {}
  @override
  Future<void> unregisterAllListeners() async {}
  @override
  Future<void> unregisterListener({
    required String key,
    required Function listener,
  }) async {}
  @override
  Future<void> unregisterAllListenersForKey({required String key}) async {}
}

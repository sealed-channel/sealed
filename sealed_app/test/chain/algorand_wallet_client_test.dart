// Tests for AlgorandWallet — mnemonic generation and round-trip derivation.
//
// Scope:
//   1. createWallet() produces a 24-word BIP39 phrase.
//   2. Generated phrase passes bip39.validateMnemonic().
//   3. Round-trip: createWallet() → getMnemonic() → restoreWallet() yields
//      the same Algorand address.
//   4. Regression: a 25-word Algorand-native phrase still restores correctly
//      (legacy restore path unbroken).

import 'package:bip39/bip39.dart' as bip39;
import 'package:blockchain_utils/bip/algorand/algorand.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';

// ─── In-memory FlutterSecureStorage stub ────────────────────────────────────

class _InMemorySecureStorage implements FlutterSecureStorage {
  final _store = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

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
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.unmodifiable(_store);

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.clear();

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.containsKey(key);

  // Unimplemented no-ops — not needed for these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ─── Helpers ────────────────────────────────────────────────────────────────

AlgorandWallet _freshWallet() => AlgorandWallet(_InMemorySecureStorage());

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('AlgorandWallet.createWallet()', () {
    test('produces a 24-word phrase', () async {
      final wallet = _freshWallet();
      await wallet.createWallet();

      final phrase = await wallet.getMnemonic();
      expect(phrase, isNotNull);
      final words = phrase!.trim().split(RegExp(r'\s+'));
      expect(words.length, equals(24));
    });

    test('phrase passes BIP39 checksum validation', () async {
      final wallet = _freshWallet();
      await wallet.createWallet();

      final phrase = await wallet.getMnemonic();
      expect(bip39.validateMnemonic(phrase!), isTrue);
    });

    test(
      'round-trip: restore from generated mnemonic yields same address',
      () async {
        final creator = _freshWallet();
        await creator.createWallet();

        final phrase = await creator.getMnemonic();
        final originalAddress = creator.walletAddress;
        expect(originalAddress, isNotNull);

        final restorer = _freshWallet();
        await restorer.restoreWallet(phrase!);

        expect(restorer.walletAddress, equals(originalAddress));
      },
    );
  });

  group('AlgorandWallet.restoreWallet() — legacy 25-word regression', () {
    test('25-word Algorand-native phrase restores without error', () async {
      // Generate a fresh 25-word phrase at test time — no network needed.
      final algoPhrase = AlgorandMnemonicGenerator()
          .fromWordsNumber(AlgorandWordsNum.wordsNum25)
          .toStr();

      final wallet = _freshWallet();
      await wallet.restoreWallet(algoPhrase);

      expect(wallet.walletAddress, isNotNull);
      expect(wallet.walletAddress!.length, greaterThan(0));
    });

    test('25-word round-trip: restore twice yields same address', () async {
      final algoPhrase = AlgorandMnemonicGenerator()
          .fromWordsNumber(AlgorandWordsNum.wordsNum25)
          .toStr();

      final w1 = _freshWallet();
      await w1.restoreWallet(algoPhrase);

      final w2 = _freshWallet();
      await w2.restoreWallet(algoPhrase);

      expect(w1.walletAddress, equals(w2.walletAddress));
    });
  });

  group('AlgorandWallet.createWallet() — overwrite guard (T13)', () {
    test('refuses to overwrite an existing wallet', () async {
      final storage = _InMemorySecureStorage();
      final wallet = AlgorandWallet(storage);
      await wallet.createWallet();

      // A second creator over the SAME storage must not clobber the wallet.
      final second = AlgorandWallet(storage);
      await expectLater(second.createWallet(), throwsA(isA<StateError>()));
    });

    test('restoreWallet is still allowed to replace', () async {
      final storage = _InMemorySecureStorage();
      final wallet = AlgorandWallet(storage);
      await wallet.createWallet();

      final algoPhrase = AlgorandMnemonicGenerator()
          .fromWordsNumber(AlgorandWordsNum.wordsNum25)
          .toStr();
      final restorer = AlgorandWallet(storage);
      await restorer.restoreWallet(algoPhrase); // must not throw
      expect(restorer.walletAddress, isNotNull);
    });
  });

  group('AlgorandWallet seed cache (T18)', () {
    test('getSeedBytes returns identical bytes across calls', () async {
      final wallet = _freshWallet();
      await wallet.createWallet();

      final a = await wallet.getSeedBytes();
      final b = await wallet.getSeedBytes();
      expect(a, equals(b));
      // Cached: same instance returned on the second call.
      expect(identical(a, b), isTrue);
    });

    test('deleteWallet clears the cached seed', () async {
      final storage = _InMemorySecureStorage();
      final wallet = AlgorandWallet(storage);
      await wallet.createWallet();
      await wallet.getSeedBytes();
      await wallet.deleteWallet();

      // After delete there is no wallet, so getSeedBytes must fail rather than
      // return a stale cached seed.
      await expectLater(wallet.getSeedBytes(), throwsA(isA<StateError>()));
    });
  });
}

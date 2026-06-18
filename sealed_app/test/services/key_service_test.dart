import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/chain/wallet_interface.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mock implementation of FlutterSecureStorage for testing
class MockSecureStorage implements FlutterSecureStorage {
  @override
  Map<String, List<ValueChanged<String?>>> get getListeners => const {};

  final Map<String, String> _storage = {};

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
    if (value != null) {
      _storage[key] = value;
    } else {
      _storage.remove(key);
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
  }) async {
    return _storage[key];
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
  }) async {
    _storage.remove(key);
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
    _storage.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage.containsKey(key);
  }

  void clear() => _storage.clear();

  // Required by FlutterSecureStorage interface
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

/// Mock wallet that returns a configurable mnemonic.
class MockChainWallet implements ChainWallet {
  String? _mnemonic;
  int _getMnemonicCallCount = 0;

  MockChainWallet({String? mnemonic}) : _mnemonic = mnemonic;

  void setMnemonic(String? m) => _mnemonic = m;
  int get getMnemonicCallCount => _getMnemonicCallCount;

  @override
  String get chainId => 'mock';
  @override
  String? get walletAddress => 'mock_wallet';
  @override
  bool get hasWallet => _mnemonic != null;

  @override
  Future<String?> getMnemonic() async {
    _getMnemonicCallCount++;
    return _mnemonic;
  }

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

KeyService _makeService({
  MockChainWallet? wallet,
  MockSecureStorage? storage,
  SharedPreferences? prefs,
}) {
  return KeyService(
    chainWallet: wallet,
    storage: storage ?? MockSecureStorage(),
    x25519: X25519(),
    hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
    prefs: prefs!,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KeyService keyService;
  late MockSecureStorage mockStorage;
  late SharedPreferences prefs;

  setUp(() async {
    mockStorage = MockSecureStorage();

    // Initialize SharedPreferences with empty values
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();

    keyService = KeyService(
      chainWallet: null,
      storage: mockStorage,
      x25519: X25519(),
      hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
      prefs: prefs,
    );
  });

  tearDown(() {
    mockStorage.clear();
  });

  group('KeyService', () {
    group('Key derivation determinism', () {
      test('same wallet and signature should produce same keys', () async {
        // Arrange
        const walletAddress = '7Xf9kL2mN8pQ3rT5vW9x1234567890abcdef';
        final signature = base64.encode(List.generate(64, (i) => i));

        // Act
        final keys1 = await keyService.deriveKeys(walletAddress, signature);
        final keys2 = await keyService.deriveKeys(walletAddress, signature);

        // Assert
        expect(keys1.encryptionPubkey, equals(keys2.encryptionPubkey));
        expect(keys1.scanPubkey, equals(keys2.scanPubkey));
        expect(keys1.encryptionPrivateKey, equals(keys2.encryptionPrivateKey));
        expect(keys1.viewPrivateKey, equals(keys2.viewPrivateKey));
      });

      test('different signatures should produce different keys', () async {
        // Arrange
        const walletAddress = '7Xf9kL2mN8pQ3rT5vW9x1234567890abcdef';
        final signature1 = base64.encode(List.generate(64, (i) => i));
        final signature2 = base64.encode(List.generate(64, (i) => i + 1));

        // Act
        final keys1 = await keyService.deriveKeys(walletAddress, signature1);

        // Clear storage to allow fresh derivation
        mockStorage.clear();
        SharedPreferences.setMockInitialValues({});
        prefs = await SharedPreferences.getInstance();
        keyService = KeyService(
          chainWallet: null,
          storage: mockStorage,
          x25519: X25519(),
          hkdf: Hkdf(hmac: Hmac.sha256(), outputLength: 32),
          prefs: prefs,
        );

        final keys2 = await keyService.deriveKeys(walletAddress, signature2);

        // Assert
        expect(keys1.encryptionPubkey, isNot(equals(keys2.encryptionPubkey)));
        expect(keys1.scanPubkey, isNot(equals(keys2.scanPubkey)));
      });

      test('should accept signature as Uint8List', () async {
        // Arrange
        const walletAddress = 'testWallet123';
        final signatureBytes = Uint8List.fromList(List.generate(64, (i) => i));

        // Act
        final keys = await keyService.deriveKeys(walletAddress, signatureBytes);

        // Assert
        expect(keys.encryptionPubkey.length, 32);
        expect(keys.scanPubkey.length, 32);
        expect(keys.walletAddress, walletAddress);
      });

      test(
        'should throw KeyValidationException for empty wallet address',
        () async {
          // Arrange
          const emptyWallet = '';
          final signature = base64.encode(List.generate(64, (i) => i));

          // Act & Assert
          expect(
            () => keyService.deriveKeys(emptyWallet, signature),
            throwsA(isA<KeyValidationException>()),
          );
        },
      );

      test('should throw KeyValidationException for null signature', () async {
        // Arrange
        const walletAddress = 'testWallet123';

        // Act & Assert
        expect(
          () => keyService.deriveKeys(walletAddress, null),
          throwsA(isA<KeyValidationException>()),
        );
      });

      test(
        'should throw KeyValidationException for invalid base64 signature',
        () async {
          // Arrange
          const walletAddress = 'testWallet123';
          const invalidBase64 = 'not-valid-base64!!!';

          // Act & Assert
          expect(
            () => keyService.deriveKeys(walletAddress, invalidBase64),
            throwsA(isA<KeyValidationException>()),
          );
        },
      );
    });

    group('Save/Load roundtrip', () {
      test('should save and load keys correctly', () async {
        // Arrange
        const walletAddress = 'testWalletRoundTrip';
        final signature = base64.encode(List.generate(64, (i) => i * 2));

        // Act: Derive and save keys
        final derivedKeys = await keyService.deriveKeys(
          walletAddress,
          signature,
        );

        // Act: Load keys from storage
        final loadedKeys = await keyService.loadKeys();

        if (loadedKeys == null) {
          fail('Loaded keys should not be null');
        }

        // Assert
        expect(loadedKeys.walletAddress, equals(derivedKeys.walletAddress));
        expect(
          loadedKeys.encryptionPubkey,
          equals(derivedKeys.encryptionPubkey),
        );
        expect(loadedKeys.scanPubkey, equals(derivedKeys.scanPubkey));
        expect(
          loadedKeys.encryptionPrivateKey,
          equals(derivedKeys.encryptionPrivateKey),
        );
        expect(loadedKeys.viewPrivateKey, equals(derivedKeys.viewPrivateKey));
      });

      test('hasKeys should return true after deriving keys', () async {
        // Arrange
        const walletAddress = 'testWalletHasKeys';
        final signature = base64.encode(List.generate(64, (i) => i));

        // Act
        await keyService.deriveKeys(walletAddress, signature);
        final hasKeys = await keyService.hasKeys();

        // Assert
        expect(hasKeys, isTrue);
      });

      test('hasKeys should return false when no keys stored', () async {
        // Act
        final hasKeys = await keyService.hasKeys();

        // Assert
        expect(hasKeys, isFalse);
      });

      test('deleteKeys should remove all stored keys', () async {
        // Arrange
        const walletAddress = 'testWalletDelete';
        final signature = base64.encode(List.generate(64, (i) => i));
        await keyService.deriveKeys(walletAddress, signature);

        // Act
        await keyService.deleteKeys();

        // Assert
        final hasKeys = await keyService.hasKeys();
        expect(hasKeys, isFalse);
      });

      test('loadKeys should throw when keys not found', () async {
        // Act & Assert
        expect(
          () => keyService.loadKeys(),
          throwsA(isA<KeyValidationException>()),
        );
      });
    });

    group('View key extraction', () {
      test('getViewKey should return the view private key', () async {
        // Arrange
        const walletAddress = 'testWalletViewKey';
        final signature = base64.encode(List.generate(64, (i) => i * 3));
        final derivedKeys = await keyService.deriveKeys(
          walletAddress,
          signature,
        );

        // Act
        final viewKey = await keyService.getViewKey();

        // Assert
        expect(viewKey, equals(derivedKeys.viewPrivateKey));
        expect(viewKey.length, 32);
      });

      test('getViewKey should throw when view key not stored', () async {
        // Act & Assert
        expect(
          () => keyService.getViewKey(),
          throwsA(isA<KeyValidationException>()),
        );
      });

      test('getPubKey should return the encryption public key', () async {
        // Arrange
        const walletAddress = 'testWalletPubKey';
        final signature = base64.encode(List.generate(64, (i) => i));
        final derivedKeys = await keyService.deriveKeys(
          walletAddress,
          signature,
        );

        // Act
        final pubKey = await keyService.getPubKey();

        // Assert
        expect(pubKey, equals(derivedKeys.encryptionPubkey));
        expect(pubKey.length, 32);
      });

      test('getWalletAddress should return stored wallet address', () async {
        // Arrange
        const expectedWallet = 'myTestWalletAddress123';
        final signature = base64.encode(List.generate(64, (i) => i));
        await keyService.deriveKeys(expectedWallet, signature);

        // Act
        final walletAddress = await keyService.getWalletAddress();

        // Assert
        expect(walletAddress, equals(expectedWallet));
      });

      test('getWalletAddress should throw when not stored', () async {
        // Act & Assert
        expect(
          () => keyService.getWalletAddress(),
          throwsA(isA<KeyValidationException>()),
        );
      });

      test('view key should be usable for cryptographic operations', () async {
        // Arrange
        const walletAddress = 'testWalletCrypto';
        final signature = base64.encode(List.generate(64, (i) => i));
        await keyService.deriveKeys(walletAddress, signature);

        // Act
        final viewKey = await keyService.getViewKey();
        final x25519 = X25519();
        final keyPair = await x25519.newKeyPairFromSeed(viewKey);
        final publicKey = await keyPair.extractPublicKey();

        // Assert
        expect(publicKey.bytes.length, 32);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // PQ master seed tests (Tasks 1 & 2)
  // ---------------------------------------------------------------------------

  group('PQ master seed (_ensurePqMasterSeed)', () {
    late MockSecureStorage storage;
    late SharedPreferences prefs;

    setUp(() async {
      storage = MockSecureStorage();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test(
      'generateAndSavePqKeyPair returns 800-byte pubkey and 1632-byte privkey',
      () async {
        final wallet = MockChainWallet(
          mnemonic:
              'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        );
        final svc = _makeService(
          wallet: wallet,
          storage: storage,
          prefs: prefs,
        );

        final keys = await svc.generateAndSavePqKeyPair();

        expect(keys.publicKey.length, 800);
        expect(keys.privateKey.length, 1632);
      },
    );

    test(
      'same mnemonic → byte-equal PQ keypair across independent instances',
      () async {
        const mnemonic =
            'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        final storage1 = MockSecureStorage();
        final storage2 = MockSecureStorage();
        SharedPreferences.setMockInitialValues({});
        final p1 = await SharedPreferences.getInstance();
        SharedPreferences.setMockInitialValues({});
        final p2 = await SharedPreferences.getInstance();

        final svc1 = _makeService(
          wallet: MockChainWallet(mnemonic: mnemonic),
          storage: storage1,
          prefs: p1,
        );
        final svc2 = _makeService(
          wallet: MockChainWallet(mnemonic: mnemonic),
          storage: storage2,
          prefs: p2,
        );

        final keys1 = await svc1.generateAndSavePqKeyPair();
        final keys2 = await svc2.generateAndSavePqKeyPair();

        expect(keys1.publicKey, equals(keys2.publicKey));
        expect(keys1.privateKey, equals(keys2.privateKey));
      },
    );

    test('mnemonic whitespace/case variants produce equal PQ keypair', () async {
      const base =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final variants = [
        base,
        '  $base  ', // leading/trailing spaces
        base.toUpperCase(), // uppercase
        base.replaceAll(' ', '  '), // double spaces
        '  ${base.toUpperCase()}  ', // both
      ];

      final results = <Uint8List>[];
      for (final variant in variants) {
        final st = MockSecureStorage();
        SharedPreferences.setMockInitialValues({});
        final p = await SharedPreferences.getInstance();
        final svc = _makeService(
          wallet: MockChainWallet(mnemonic: variant),
          storage: st,
          prefs: p,
        );
        final keys = await svc.generateAndSavePqKeyPair();
        results.add(keys.publicKey);
      }

      for (var i = 1; i < results.length; i++) {
        expect(
          results[i],
          equals(results[0]),
          reason: 'variant $i should produce same pubkey as canonical',
        );
      }
    });

    test(
      'no mnemonic + no cached seed → throws KeyValidationException',
      () async {
        final wallet = MockChainWallet(mnemonic: null);
        final svc = _makeService(
          wallet: wallet,
          storage: storage,
          prefs: prefs,
        );

        expect(
          () => svc.generateAndSavePqKeyPair(),
          throwsA(isA<KeyValidationException>()),
        );
      },
    );

    test(
      'second call uses cached seed without calling getMnemonic again',
      () async {
        const mnemonic =
            'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        final wallet = MockChainWallet(mnemonic: mnemonic);
        final svc = _makeService(
          wallet: wallet,
          storage: storage,
          prefs: prefs,
        );

        // First call — bootstraps from mnemonic
        await svc.generateAndSavePqKeyPair();
        final callsAfterFirst = wallet.getMnemonicCallCount;

        // Second call — should use cached pq_master_seed
        await svc.generateAndSavePqKeyPair();
        final callsAfterSecond = wallet.getMnemonicCallCount;

        expect(
          callsAfterSecond,
          equals(callsAfterFirst),
          reason: 'getMnemonic should not be called again when cache exists',
        );
      },
    );

    test(
      'null chainWallet + cached seed → succeeds (no mnemonic needed)',
      () async {
        // Pre-populate cache manually
        const mnemonic =
            'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        final walletForSetup = MockChainWallet(mnemonic: mnemonic);
        final svcSetup = _makeService(
          wallet: walletForSetup,
          storage: storage,
          prefs: prefs,
        );
        await svcSetup.generateAndSavePqKeyPair(); // seeds the cache

        // Now create service with no wallet
        final svcNoWallet = _makeService(
          wallet: null,
          storage: storage,
          prefs: prefs,
        );
        final keys = await svcNoWallet.generateAndSavePqKeyPair();

        expect(keys.publicKey.length, 800);
      },
    );

    test(
      'regeneratePqKeysFromMasterSeed overwrites stored keys deterministically',
      () async {
        const mnemonic =
            'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
        final wallet = MockChainWallet(mnemonic: mnemonic);
        final svc = _makeService(
          wallet: wallet,
          storage: storage,
          prefs: prefs,
        );

        final original = await svc.generateAndSavePqKeyPair();
        // Corrupt stored keys
        await storage.write(
          key: 'pq_kem_pubkey',
          value: base64.encode(Uint8List(800)),
        );

        final regen = await svc.regeneratePqKeysFromMasterSeed();

        expect(regen.publicKey, equals(original.publicKey));
      },
    );

    // Regression: previously, redeem flow re-derived PQ keys via
    // regeneratePqKeysFromMasterSeed() but then published the pqPub read
    // from a memoized Riverpod keysProvider, which held the pre-regen
    // pqPub. On-chain pqPubkeyHash anchored to the obsolete pubkey while
    // secure storage held the new privkey → every inbound KEM decap on
    // this device returned a garbage shared secret → AEAD MAC failure on
    // hybrid decrypt. Lock the invariant: after regen, loadPqKeys() must
    // return byte-equal material to the regen return value.
    test('regeneratePqKeysFromMasterSeed: loadPqKeys() matches regen result '
        '(prevents stale-keysProvider publish hazard)', () async {
      const mnemonic =
          'abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon about';
      final wallet = MockChainWallet(mnemonic: mnemonic);
      final svc = _makeService(wallet: wallet, storage: storage, prefs: prefs);

      // Simulate an older pqPub being live in storage from a prior
      // derivation path. Overwrite with bytes that differ from the
      // deterministic regen output.
      await svc.generateAndSavePqKeyPair();
      await storage.write(
        key: 'pq_kem_pubkey',
        value: base64.encode(Uint8List(800)),
      );
      await storage.write(
        key: 'pq_kem_privkey',
        value: base64.encode(Uint8List(1632)),
      );

      final regen = await svc.regeneratePqKeysFromMasterSeed();
      final loaded = await svc.loadPqKeys();

      expect(
        loaded,
        isNotNull,
        reason: 'loadPqKeys must return keys after regen',
      );
      expect(
        loaded!.publicKey,
        equals(regen.publicKey),
        reason:
            'pubkey from storage MUST equal regen return value — '
            'otherwise publishKeysIfStale anchors on-chain hash to '
            'a stale pubkey while the privkey in storage diverges',
      );
      expect(
        loaded.privateKey,
        equals(regen.privateKey),
        reason: 'privkey in storage MUST equal regen privkey',
      );
    });

    // Regression: deleteKeys() previously left `pq_master_seed`,
    // `pq_kem_pubkey`, and `pq_kem_privkey` in secure storage. After
    // logout + new-wallet creation, _ensurePqMasterSeed() returned the
    // PRIOR identity's cached master seed → new wallet derived the
    // same pqPub/pqPriv as the old wallet → on-chain pqPubkeyHash
    // anchored to a leaked keypair across identities. Catastrophic for
    // forward secrecy and creates "aligned=true" false-positives in
    // diagnostic logs that mask the bug.
    test('deleteKeys() wipes pq_master_seed + pq_kem keys '
        '(prevents cross-wallet key leakage on logout)', () async {
      const mnemonicA =
          'abandon abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon about';
      const mnemonicB =
          'legal winner thank year wave sausage worth useful legal '
          'winner thank yellow';

      // Wallet A: derive PQ keys, persist master seed.
      final svcA = _makeService(
        wallet: MockChainWallet(mnemonic: mnemonicA),
        storage: storage,
        prefs: prefs,
      );
      final keysA = await svcA.generateAndSavePqKeyPair();

      // Logout — wipe everything.
      await svcA.deleteKeys();

      expect(
        await storage.read(key: 'pq_master_seed'),
        isNull,
        reason: 'pq_master_seed must be wiped on deleteKeys',
      );
      expect(
        await storage.read(key: 'pq_kem_pubkey'),
        isNull,
        reason: 'pq_kem_pubkey must be wiped on deleteKeys',
      );
      expect(
        await storage.read(key: 'pq_kem_privkey'),
        isNull,
        reason: 'pq_kem_privkey must be wiped on deleteKeys',
      );

      // Wallet B: different mnemonic → MUST produce different PQ keypair.
      final svcB = _makeService(
        wallet: MockChainWallet(mnemonic: mnemonicB),
        storage: storage,
        prefs: prefs,
      );
      final keysB = await svcB.generateAndSavePqKeyPair();

      expect(
        keysB.publicKey,
        isNot(equals(keysA.publicKey)),
        reason:
            'fresh wallet with different mnemonic MUST derive a '
            'different pqPub — stale master seed would leak the '
            'prior identity across logout',
      );
      expect(
        keysB.privateKey,
        isNot(equals(keysA.privateKey)),
        reason: 'pqPriv MUST also differ across identities',
      );
    });
  });
}

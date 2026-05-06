import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/services/key_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mock implementation of FlutterSecureStorage for testing
class MockSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _storage = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
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
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return _storage[key];
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.remove(key);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _storage.clear();
  }

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    return Map.from(_storage);
  }

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
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
}

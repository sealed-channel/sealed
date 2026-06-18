// Tests for the PIN lock pipeline: DEK bootstrap → set PIN → verify →
// change → wrong-PIN attempt tracking → termination code.

import 'dart:convert';
import 'dart:typed_data';

import 'package:argon2/argon2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/dek_manager.dart';
import 'package:sealed_app/features/auth/pin_auth.dart';

/// Derive a KEK under the pre-calibration ("legacy") Argon2id params
/// (64 MiB / iter 3 / lane 1) — byte-identical to what older builds used to
/// wrap the DEK. Lets tests forge a legacy-state wrap with no stored params.
Uint8List _legacyKek(String input, Uint8List salt) {
  final params = Argon2Parameters(
    Argon2Parameters.ARGON2_id,
    salt,
    version: Argon2Parameters.ARGON2_VERSION_13,
    iterations: 3,
    memory: 64 * 1024,
    lanes: 1,
  );
  final gen = Argon2BytesGenerator()..init(params);
  final out = Uint8List(32);
  gen.generateBytes(Uint8List.fromList(utf8.encode(input)), out, 0, out.length);
  return out;
}

void main() {
  group('DekManager', () {
    test('bootstrap creates DEK once; subsequent calls are no-ops', () async {
      final storage = _InMemorySecureStorage();
      final mgr = DekManager(storage: storage);
      final first = await mgr.bootstrapIfNeeded();
      final second = await mgr.bootstrapIfNeeded();
      expect(first, isTrue);
      expect(second, isFalse);
      expect(await mgr.currentKekKind(), 'device');
    });

    test('device-secret unwrap round-trip', () async {
      final storage = _InMemorySecureStorage();
      final mgr = DekManager(storage: storage);
      await mgr.bootstrapIfNeeded();
      final dek1 = await mgr.unwrapWithDeviceSecret();
      final dek2 = await mgr.unwrapWithDeviceSecret();
      expect(dek1, dek2);
      expect(dek1.length, 32);
    });
  });

  group('PinService', () {
    late _InMemorySecureStorage storage;
    late DekManager dek;
    late PinService pin;

    setUp(() async {
      storage = _InMemorySecureStorage();
      dek = DekManager(storage: storage);
      pin = PinService(storage: storage, dekManager: dek);
      await dek.bootstrapIfNeeded();
    });

    test('isPinSet false initially', () async {
      expect(await pin.isPinSet(), isFalse);
    });

    test('setPin then verify with correct PIN succeeds', () async {
      // capture device-wrapped DEK before PIN is set
      final deviceDek = await dek.unwrapWithDeviceSecret();

      await pin.setPin('123456');
      expect(await pin.isPinSet(), isTrue);

      final unwrapped = await pin.verifyAndUnwrap('123456');
      expect(unwrapped, deviceDek); // DEK is stable across re-wraps
    });

    test(
      'setPin then verify with wrong PIN throws PinIncorrectException',
      () async {
        await pin.setPin('123456');
        expect(
          () => pin.verifyAndUnwrap('111111'),
          throwsA(isA<PinIncorrectException>()),
        );
      },
    );

    test('changePin re-wraps DEK; old PIN no longer works', () async {
      await pin.setPin('123456');
      final dek1 = await pin.verifyAndUnwrap('123456');
      await pin.changePin('123456', '654321');
      final dek2 = await pin.verifyAndUnwrap('654321');
      expect(dek1, dek2);
      expect(
        () => pin.verifyAndUnwrap('123456'),
        throwsA(isA<PinIncorrectException>()),
      );
    });

    test('PIN must be 6 digits', () async {
      expect(() => pin.setPin('12345'), throwsA(isA<PinException>()));
      expect(() => pin.setPin('abcdef'), throwsA(isA<PinException>()));
    });

    test(
      'legacy wrap (no stored params) verifies, then auto-upgrades',
      () async {
        // Forge the state of a tester who set a PIN before calibration shipped:
        // DEK wrapped under legacy params, no pin_kdf_params key.
        final deviceDek = await dek.unwrapWithDeviceSecret();
        final salt = Uint8List.fromList(List.generate(16, (i) => i + 1));
        await storage.write(
          key: DekStorageKeys.pinSalt,
          value: base64.encode(salt),
        );
        await dek.rewrap(
          deviceDek,
          _legacyKek('123456', salt),
          markKekKind: 'pin',
        );
        expect(await pin.isPinSet(), isTrue);
        expect(await storage.read(key: DekStorageKeys.pinKdfParams), isNull);

        // Unlocks under legacy params — no lockout for existing testers.
        expect(await pin.verifyAndUnwrap('123456'), deviceDek);
        expect(
          () => pin.verifyAndUnwrap('000000'),
          throwsA(isA<PinIncorrectException>()),
        );

        // The fire-and-forget upgrade persists per-device params.
        for (
          var i = 0;
          i < 100 &&
              await storage.read(key: DekStorageKeys.pinKdfParams) == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(await storage.read(key: DekStorageKeys.pinKdfParams), isNotNull);
        // Same DEK still unwraps under the upgraded params.
        expect(await pin.verifyAndUnwrap('123456'), deviceDek);
      },
    );

    test(
      'recovers from a torn upgrade (params persisted ahead of rewrap)',
      () async {
        final deviceDek = await dek.unwrapWithDeviceSecret();
        final salt = Uint8List.fromList(List.generate(16, (i) => 200 - i));
        await storage.write(
          key: DekStorageKeys.pinSalt,
          value: base64.encode(salt),
        );
        await dek.rewrap(
          deviceDek,
          _legacyKek('123456', salt),
          markKekKind: 'pin',
        );
        // Simulate a crash mid-upgrade: new params written, DEK still legacy.
        await storage.write(
          key: DekStorageKeys.pinKdfParams,
          value: '{"v":1,"m":47104,"t":4,"p":1}',
        );

        // Derives the (mismatched) stored params, fails, falls back to legacy on
        // the same salt, unlocks, and finishes the rewrap under the stored params.
        expect(await pin.verifyAndUnwrap('123456'), deviceDek);
        // Now consistent — a direct unwrap under the stored params works.
        expect(await pin.verifyAndUnwrap('123456'), deviceDek);
        expect(
          () => pin.verifyAndUnwrap('999999'),
          throwsA(isA<PinIncorrectException>()),
        );
      },
    );
  });

  group('PinAttemptTracker', () {
    test('counts up to maxAttempts (5)', () async {
      final tracker = PinAttemptTracker(storage: _InMemorySecureStorage());
      for (var i = 1; i <= PinAttemptTracker.maxAttempts; i++) {
        final count = await tracker.recordFailedAttempt();
        expect(count, i);
      }
      expect(await tracker.attemptCount(), PinAttemptTracker.maxAttempts);
    });

    test('reset clears state', () async {
      final tracker = PinAttemptTracker(storage: _InMemorySecureStorage());
      await tracker.recordFailedAttempt();
      await tracker.reset();
      expect(await tracker.attemptCount(), 0);
    });
  });

  group('TerminationService', () {
    test('matches returns true for set code, false otherwise', () async {
      final term = TerminationService(storage: _InMemorySecureStorage());
      expect(await term.isConfigured(), isFalse);
      await term.setCode('999999');
      expect(await term.isConfigured(), isTrue);
      expect(await term.matches('999999'), isTrue);
      expect(await term.matches('888888'), isFalse);
    });

    test('disable removes the code', () async {
      final term = TerminationService(storage: _InMemorySecureStorage());
      await term.setCode('111111');
      await term.disable();
      expect(await term.isConfigured(), isFalse);
      expect(await term.matches('111111'), isFalse);
    });
  });
}

/// In-memory FlutterSecureStorage stub for tests.
class _InMemorySecureStorage implements FlutterSecureStorage {
  final Map<String, String> _mem = {};

  @override
  AndroidOptions get aOptions => const AndroidOptions();
  @override
  IOSOptions get iOptions => const IOSOptions();
  @override
  LinuxOptions get lOptions => const LinuxOptions();
  @override
  MacOsOptions get mOptions => const MacOsOptions();
  @override
  WindowsOptions get wOptions => const WindowsOptions();
  @override
  WebOptions get webOptions => const WebOptions();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _mem[key];

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
      _mem.remove(key);
    } else {
      _mem[key] = value;
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
  }) async {
    _mem.remove(key);
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
    _mem.clear();
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
  }) async => _mem.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_mem);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Avoid analyzer complaint about Uint8List import being unused if tests change.
// ignore: unused_element
void _kUseUint8(Uint8List _) {}

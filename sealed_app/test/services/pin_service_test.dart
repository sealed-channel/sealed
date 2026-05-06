// Tests for the PIN lock pipeline: DEK bootstrap → set PIN → verify →
// change → wrong-PIN attempt tracking → termination code.

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/local/dek_manager.dart';
import 'package:sealed_app/services/pin_attempt_tracker.dart';
import 'package:sealed_app/services/pin_service.dart';
import 'package:sealed_app/services/termination_service.dart';

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
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _mem[key];

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
    if (value == null) {
      _mem.remove(key);
    } else {
      _mem[key] = value;
    }
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
    _mem.remove(key);
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
    _mem.clear();
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
  }) async => _mem.containsKey(key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.of(_mem);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Avoid analyzer complaint about Uint8List import being unused if tests change.
// ignore: unused_element
void _kUseUint8(Uint8List _) {}

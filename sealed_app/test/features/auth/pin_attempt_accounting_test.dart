// Pins the strike-accounting ORDER for the PIN unlock path (security review
// Task 15).
//
// Bug: the wrong-attempt counter used to be persisted only AFTER the ~500ms
// Argon2id derivation + DEK unwrap completed. An attacker could therefore kill
// the app mid-derivation and never consume a strike, making unlimited offline
// guesses against the 5-strike wipe budget.
//
// Fix: `PinSecurityNotifier.confirmAndUnlock` PRE-increments the persisted
// counter BEFORE running verification, and only rolls it back on a confirmed
// correct PIN (or an infrastructure fault that is not a brute-force signal).
//
// Approach: rather than racing a real ~500ms KDF, we inject a spy PinService
// whose `verifyAndUnwrap` reads the *persisted* attempt counter at the exact
// moment it is invoked — i.e. the seam where the KDF result would be consumed.
// Asserting the counter is already incremented at that point proves the
// increment lands before verification, which is the property a mid-verify kill
// relies on.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/auth/pin_auth.dart';
import 'package:sealed_app/infra/local/dek_manager.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';

void main() {
  group('PIN strike accounting ordering (Task 15)', () {
    late _InMemorySecureStorage storage;
    late _FakeWipeRunner wipe;
    late _FakeSession session;

    setUp(() {
      storage = _InMemorySecureStorage();
      wipe = _FakeWipeRunner();
      session = _FakeSession();
    });

    ProviderContainer makeContainer(PinService pin) {
      return ProviderContainer(
        overrides: [
          flutterSecureStorageProvider.overrideWithValue(storage),
          pinServiceProvider.overrideWithValue(pin),
          wipeRunnerProvider.overrideWithValue(wipe.call),
          pinSessionControllerProvider.overrideWithValue(session),
        ],
      );
    }

    Future<int> persistedCount() async {
      final s = await storage.read(key: DekStorageKeys.pinAttempts);
      return int.tryParse(s ?? '0') ?? 0;
    }

    test(
      'strike is persisted BEFORE verification consumes the KDF result',
      () async {
        // Spy: on verifyAndUnwrap, capture what the persisted counter looks
        // like right now (the moment the KDF result would be consumed).
        int? countSeenDuringVerify;
        final pin = _SpyPinService(
          onVerify: () async {
            countSeenDuringVerify = await persistedCount();
            throw PinIncorrectException();
          },
        );
        final container = makeContainer(pin);
        addTearDown(container.dispose);
        await container.read(pinSecurityProvider.future);

        final ok = await container
            .read(pinSecurityProvider.notifier)
            .confirmAndUnlock('999999');

        expect(ok, isFalse);
        // The increment must already be visible to the verification step.
        expect(
          countSeenDuringVerify,
          1,
          reason: 'counter must be incremented before verifyAndUnwrap runs',
        );
        // And it must still be on disk after a wrong PIN (mid-verify kill
        // would leave exactly this state).
        expect(await persistedCount(), 1);
      },
    );

    test('correct PIN clears the speculative strike', () async {
      final pin = _SpyPinService(
        onVerify: () async => Uint8List(32), // success
      );
      final container = makeContainer(pin);
      addTearDown(container.dispose);
      await container.read(pinSecurityProvider.future);

      final ok = await container
          .read(pinSecurityProvider.notifier)
          .confirmAndUnlock('123456');

      expect(ok, isTrue);
      expect(
        await persistedCount(),
        0,
        reason: 'correct PIN rolls back the pre-incremented strike',
      );
      expect(session.lastUnlockedDek, isNotNull);
    });

    test('each wrong PIN counts exactly one strike', () async {
      final pin = _SpyPinService(
        onVerify: () async {
          throw PinIncorrectException();
        },
      );
      final container = makeContainer(pin);
      addTearDown(container.dispose);
      await container.read(pinSecurityProvider.future);
      final notifier = container.read(pinSecurityProvider.notifier);

      await notifier.confirmAndUnlock('999999');
      await notifier.confirmAndUnlock('999999');
      expect(await persistedCount(), 2);
    });

    test(
      'infrastructure fault rolls back to prior count (does not drain budget)',
      () async {
        // Pre-seed one genuine prior strike.
        await PinAttemptTracker(storage: storage).recordFailedAttempt();

        final pin = _SpyPinService(
          onVerify: () async {
            throw PinKdfException('Argon2id failed');
          },
        );
        final container = makeContainer(pin);
        addTearDown(container.dispose);
        await container.read(pinSecurityProvider.future);

        final ok = await container
            .read(pinSecurityProvider.notifier)
            .confirmAndUnlock('123456');

        expect(ok, isFalse);
        // The speculative strike for THIS attempt is rolled back, but the
        // genuine earlier strike survives — a KDF fault must not clear the
        // budget, nor add to it.
        expect(await persistedCount(), 1);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// Spy over PinService that lets the test drive the verifyAndUnwrap outcome
/// (and observe state at that instant) without running a real Argon2id KDF.
class _SpyPinService implements PinService {
  final Future<Uint8List> Function() onVerify;
  _SpyPinService({required this.onVerify});

  @override
  Future<Uint8List> verifyAndUnwrap(String pin) => onVerify();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWipeRunner {
  int calls = 0;
  Future<void> call() async {
    calls++;
  }
}

class _FakeSession implements PinSessionController {
  Uint8List? lastUnlockedDek;
  Uint8List? lastSetupDek;
  int resetCount = 0;

  @override
  void unlock(Uint8List dek) => lastUnlockedDek = dek;
  @override
  void onPinSetCompleted(Uint8List dek) => lastSetupDek = dek;
  @override
  void reset() => resetCount++;
}

// ---------------------------------------------------------------------------
// In-memory FlutterSecureStorage stub (same shape as the one in
// test/providers/pin_security_provider_test.dart).
// ---------------------------------------------------------------------------

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

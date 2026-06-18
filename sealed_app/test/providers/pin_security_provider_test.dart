// Tests for `pinSecurityProvider` — the unified PIN security surface.
//
// We exercise the notifier with real PinService / TerminationService /
// PinAttemptTracker over an in-memory FlutterSecureStorage, and inject
// recording fakes for the two production-side seams:
//
//   - wipeRunnerProvider           — so we don't tear down secure
//                                    storage / SQLCipher / SharedPreferences
//                                    inside a unit test.
//   - pinSessionControllerProvider — so we don't trigger
//                                    PinSessionNotifier._initialize(),
//                                    which calls LocalDatabase.fileExists()
//                                    (native plugin, not available in
//                                    `flutter test`).
//
// Both indirections still preserve the privacy invariant: the DEK is
// passed INTO the (fake) session controller, never read OUT of it
// through the notifier's surface.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/auth/pin_auth.dart';
import 'package:sealed_app/infra/local/dek_manager.dart';
import 'package:sealed_app/providers/pin_security_provider.dart';

void main() {
  group('PinSecurityNotifier', () {
    late _InMemorySecureStorage storage;
    late _FakeWipeRunner wipe;
    late _FakeSession session;
    late ProviderContainer container;

    setUp(() async {
      storage = _InMemorySecureStorage();
      // Bootstrap a DEK into the in-memory storage so PinService.setPin can
      // find a device-wrapped DEK to migrate to a PIN wrap. Mirrors what
      // PinSessionNotifier._initialize would do on real startup.
      await DekManager(storage: storage).bootstrapIfNeeded();

      wipe = _FakeWipeRunner();
      session = _FakeSession();

      container = ProviderContainer(
        overrides: [
          flutterSecureStorageProvider.overrideWithValue(storage),
          wipeRunnerProvider.overrideWithValue(wipe.call),
          pinSessionControllerProvider.overrideWithValue(session),
        ],
      );
    });

    tearDown(() => container.dispose());

    // Read state, forcing the initial async build to complete.
    Future<PinSecurityState> readState() {
      return container.read(pinSecurityProvider.future);
    }

    // ── Initial state ────────────────────────────────────────────────────

    test('initial state: no attempts, no termination configured', () async {
      final s = await readState();
      expect(s.attemptCount, 0);
      expect(s.isTerminationConfigured, isFalse);
      expect(s.isLockedOut, isFalse);
      expect(s.lastError, isNull);
    });

    // ── setPin + unlock happy path ───────────────────────────────────────

    test(
      'setPin then confirmAndUnlock(correct) returns true and DEK is handed to session',
      () async {
        await readState();
        final notifier = container.read(pinSecurityProvider.notifier);

        await notifier.setPin('123456');
        // setPin commits the freshly-wrapped DEK to the session via
        // onPinSetCompleted. The session fake records that.
        expect(session.lastSetupDek, isNotNull);
        expect(session.lastSetupDek!.length, 32);

        final ok = await notifier.confirmAndUnlock('123456');
        expect(ok, isTrue);

        // confirmAndUnlock hands the DEK to the session via unlock().
        expect(session.lastUnlockedDek, isNotNull);
        expect(session.lastUnlockedDek!.length, 32);
        // DEKs from both paths must be the same key — DEK is stable across
        // wrap migrations.
        expect(session.lastUnlockedDek, session.lastSetupDek);

        final s = container.read(pinSecurityProvider).value!;
        expect(s.attemptCount, 0);
        // No wipe triggered on the happy path.
        expect(wipe.calls, 0);
      },
    );

    // ── Wrong PIN bumps tracker, leaves DEK alone ────────────────────────

    test(
      'confirmAndUnlock with wrong PIN returns false, bumps attempt count, no DEK passed',
      () async {
        await readState();
        final notifier = container.read(pinSecurityProvider.notifier);
        await notifier.setPin('123456');

        // Clear the session-fake's record of the setPin-path DEK so we can
        // prove the wrong-pin branch did NOT touch the session.
        session.clear();

        final ok = await notifier.confirmAndUnlock('999999');
        expect(ok, isFalse);

        final s = container.read(pinSecurityProvider).value!;
        expect(s.attemptCount, 1);

        // No DEK crossed the session boundary on this path.
        expect(session.lastUnlockedDek, isNull);
        expect(session.lastSetupDek, isNull);
        // Single failure must not yet trigger the wipe.
        expect(wipe.calls, 0);
      },
    );

    // ── Max attempts triggers wipe ───────────────────────────────────────

    test('reaching maxAttempts triggers wipeNow exactly once', () async {
      await readState();
      final notifier = container.read(pinSecurityProvider.notifier);
      await notifier.setPin('123456');
      session.clear();

      // Hammer wrong PIN up to (but not at) the cap — wipe must not yet fire.
      for (var i = 1; i < PinAttemptTracker.maxAttempts; i++) {
        final ok = await notifier.confirmAndUnlock('999999');
        expect(ok, isFalse);
        expect(
          wipe.calls,
          0,
          reason: 'wipe must not fire before attempt $i crosses the cap',
        );
      }

      // Final attempt — must push past the threshold and trigger the wipe.
      final ok = await notifier.confirmAndUnlock('999999');
      expect(ok, isFalse);
      expect(wipe.calls, 1, reason: 'wipe fires exactly once at threshold');
      // Wipe must also reset the session (session-reset post-wipe contract).
      expect(session.resetCount, 1);

      final s = container.read(pinSecurityProvider).value!;
      expect(s.attemptCount, PinAttemptTracker.maxAttempts);
      expect(s.isLockedOut, isTrue);
    });

    // ── changePin: rejection + acceptance ────────────────────────────────

    test(
      'changePin rejects wrong oldPin without bumping wipe budget',
      () async {
        await readState();
        final notifier = container.read(pinSecurityProvider.notifier);
        await notifier.setPin('123456');

        await expectLater(
          notifier.changePin('999999', '654321'),
          throwsA(isA<PinIncorrectException>()),
        );

        // Settings-flow wrong PIN must NOT count against the lock-screen
        // wipe budget — settings wrong-PIN attempts have always been free.
        final s = container.read(pinSecurityProvider).value!;
        expect(s.attemptCount, 0);
        expect(wipe.calls, 0);
      },
    );

    test(
      'changePin accepts correct oldPin; new PIN unlocks, old does not',
      () async {
        await readState();
        final notifier = container.read(pinSecurityProvider.notifier);
        await notifier.setPin('123456');
        session.clear();

        await notifier.changePin('123456', '654321');

        // Old PIN no longer works.
        expect(await notifier.confirmAndUnlock('123456'), isFalse);
        // New PIN unlocks — resets the bad-attempt counter.
        expect(await notifier.confirmAndUnlock('654321'), isTrue);

        final s = container.read(pinSecurityProvider).value!;
        expect(
          s.attemptCount,
          0,
          reason: 'successful unlock with new PIN resets the tracker',
        );
        expect(wipe.calls, 0);
      },
    );

    // ── Termination code ─────────────────────────────────────────────────

    test(
      'setTerminationCode then verifyTermination(correct) returns true',
      () async {
        await readState();
        final notifier = container.read(pinSecurityProvider.notifier);

        await notifier.setTerminationCode('999999');
        expect(await notifier.verifyTermination('999999'), isTrue);

        final s = container.read(pinSecurityProvider).value!;
        expect(s.isTerminationConfigured, isTrue);
      },
    );

    test('verifyTermination with wrong code returns false', () async {
      await readState();
      final notifier = container.read(pinSecurityProvider.notifier);

      await notifier.setTerminationCode('999999');
      expect(await notifier.verifyTermination('888888'), isFalse);
      // Pure gate — no wipe side-effect.
      expect(wipe.calls, 0);
    });

    test(
      'verifyTermination(correct) does not by itself trigger wipe',
      () async {
        // Contract used by change_termination_flow: gate is non-destructive.
        // Wipe-on-termination only fires from the lock screen, which
        // composes verifyTermination + wipeNow.
        await readState();
        final notifier = container.read(pinSecurityProvider.notifier);

        await notifier.setTerminationCode('999999');
        final ok = await notifier.verifyTermination('999999');

        expect(ok, isTrue);
        expect(wipe.calls, 0);
      },
    );

    test('state reflects isTerminationConfigured through set/clear', () async {
      await readState();
      final notifier = container.read(pinSecurityProvider.notifier);

      expect(
        container.read(pinSecurityProvider).value!.isTerminationConfigured,
        isFalse,
      );

      await notifier.setTerminationCode('999999');
      expect(
        container.read(pinSecurityProvider).value!.isTerminationConfigured,
        isTrue,
      );

      await notifier.clearTermination();
      expect(
        container.read(pinSecurityProvider).value!.isTerminationConfigured,
        isFalse,
      );
    });

    // ── Public recordFailedAttempt mirrors the internal path ─────────────

    test(
      'public recordFailedAttempt triggers wipe at maxAttempts (same as confirmAndUnlock)',
      () async {
        await readState();
        final notifier = container.read(pinSecurityProvider.notifier);

        for (var i = 1; i < PinAttemptTracker.maxAttempts; i++) {
          await notifier.recordFailedAttempt();
          expect(wipe.calls, 0);
        }
        await notifier.recordFailedAttempt();
        expect(wipe.calls, 1);
        expect(session.resetCount, 1);
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

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

  void clear() {
    lastUnlockedDek = null;
    lastSetupDek = null;
    // Deliberately do NOT zero resetCount here — tests that need it reset
    // create a fresh container.
  }

  @override
  void unlock(Uint8List dek) {
    lastUnlockedDek = dek;
  }

  @override
  void onPinSetCompleted(Uint8List dek) {
    lastSetupDek = dek;
  }

  @override
  void reset() {
    resetCount++;
  }
}

// ---------------------------------------------------------------------------
// In-memory FlutterSecureStorage stub — same shape as the one in
// test/services/pin_service_test.dart.
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

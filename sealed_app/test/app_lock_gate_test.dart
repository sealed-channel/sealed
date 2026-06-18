import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/ui/navigation/screens/app_shell.dart'
    show shouldGateBehindLock;
import 'package:sealed_app/providers/pin_provider.dart' show PinPhase;

/// Regression guard for the "LocalDatabase accessed while PIN session is not
/// unlocked" crash.
///
/// Root cause: AppShell.build watched the DB-touching wallet/keys/user
/// providers (userProvider.build → restoreSession/syncMessages → LocalDatabase)
/// on the FIRST locked state of a launch, before any unlock had supplied the
/// DEK. The deterministic StateError tripped ErrorScreen ("Something went
/// wrong"). Reproduced on hot restart and on a genuine cold launch with a PIN
/// set.
///
/// Fix: gate that subtree behind the first unlock via [shouldGateBehindLock].
/// These tests pin the decision and the latch behaviour that preserves the
/// no-flicker overlay design on re-lock.
void main() {
  group('shouldGateBehindLock', () {
    test('GATEs when locked and never unlocked this launch', () {
      // First locked state of a launch: providers have no cached data, so we
      // must show the lock screen alone, NOT mount the DB subtree under it.
      expect(shouldGateBehindLock(PinPhase.locked, false), isTrue);
    });

    test('does NOT gate while unlocked (DEK present)', () {
      expect(shouldGateBehindLock(PinPhase.unlocked, true), isFalse);
    });

    test('does NOT gate during bootstrapping (handled earlier)', () {
      expect(shouldGateBehindLock(PinPhase.bootstrapping, false), isFalse);
    });

    test('does NOT gate in PIN-less (noPin) state', () {
      // noPin resolves to an unlocked phase with the device-secret DEK; the
      // phase is never `locked`, so the subtree is free to mount.
      expect(shouldGateBehindLock(PinPhase.noPin, false), isFalse);
    });

    test('OVERLAYs (does not re-gate) on re-lock after a prior unlock', () {
      // After the first unlock the providers hold cached AsyncData; a later
      // re-lock must overlay the lock screen and keep them mounted (no
      // re-resolve, no SplashScreen flicker). The latch makes that so.
      expect(shouldGateBehindLock(PinPhase.locked, true), isFalse);
    });
  });

  test('launch latch sequence: gate first lock, overlay every lock after', () {
    // Mirrors AppShell.build: the latch flips true on the first unlocked
    // frame and never flips back for the rest of the launch.
    var hasUnlockedThisLaunch = false;

    void observe(PinPhase phase) {
      if (phase == PinPhase.unlocked) hasUnlockedThisLaunch = true;
    }

    // 1. Cold launch with a PIN set → bootstrapping → locked (first time).
    observe(PinPhase.bootstrapping);
    expect(
      shouldGateBehindLock(PinPhase.locked, hasUnlockedThisLaunch),
      isTrue,
      reason: 'first locked state must gate the DB subtree',
    );

    // 2. User enters PIN → unlocked. Latch flips.
    observe(PinPhase.unlocked);
    expect(
      shouldGateBehindLock(PinPhase.unlocked, hasUnlockedThisLaunch),
      isFalse,
    );

    // 3. App backgrounded past the grace timer → re-lock.
    observe(PinPhase.locked);
    expect(
      shouldGateBehindLock(PinPhase.locked, hasUnlockedThisLaunch),
      isFalse,
      reason: 're-lock must overlay, not re-gate (no flicker / no re-resolve)',
    );
  });
}

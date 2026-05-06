/// Riverpod providers for PIN lock, termination code, and the
/// in-memory DEK session.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'
    show StateNotifier, StateNotifierProvider;
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/local/dek_manager.dart';
import 'package:sealed_app/services/pin_attempt_tracker.dart';
import 'package:sealed_app/services/pin_service.dart';
import 'package:sealed_app/services/termination_service.dart';
import 'package:sealed_app/services/wipe_service.dart';

// ─── Service providers ──────────────────────────────────────────────────────

final dekManagerProvider = Provider<DekManager>((ref) {
  return DekManager(storage: ref.watch(flutterSecureStorageProvider));
});

final pinServiceProvider = Provider<PinService>((ref) {
  return PinService(
    storage: ref.watch(flutterSecureStorageProvider),
    dekManager: ref.watch(dekManagerProvider),
  );
});

final pinAttemptTrackerProvider = Provider<PinAttemptTracker>((ref) {
  return PinAttemptTracker(storage: ref.watch(flutterSecureStorageProvider));
});

final terminationServiceProvider = Provider<TerminationService>((ref) {
  return TerminationService(storage: ref.watch(flutterSecureStorageProvider));
});

final wipeServiceProvider = Provider<WipeService>((ref) {
  // WipeService needs a ProviderContainer to drive performLogout. We expect
  // callers to construct it via [wipeServiceFromContainer]; this provider
  // exists for parity but throws if accessed without a container.
  throw UnimplementedError(
    'Use wipeServiceFromContainer(container) — WipeService needs a ProviderContainer.',
  );
});

WipeService wipeServiceFromContainer(ProviderContainer container) {
  return WipeService(
    container,
    storage: container.read(flutterSecureStorageProvider),
  );
}

// ─── PIN session state ─────────────────────────────────────────────────────
//
// `pinSessionProvider` exposes the in-memory unlocked state. The DEK is held
// here (and only here) while the app is unlocked; clearing the state wipes
// it from RAM.

enum PinPhase { bootstrapping, noPin, locked, unlocked }

class PinSessionState {
  final PinPhase phase;
  final Uint8List? dek; // present iff phase == unlocked
  final bool
  needsPinSetup; // true when DEK is unlocked under device-secret only

  const PinSessionState(this.phase, {this.dek, this.needsPinSetup = false});

  const PinSessionState.bootstrapping() : this(PinPhase.bootstrapping);
  const PinSessionState.noPin() : this(PinPhase.noPin);
  const PinSessionState.locked() : this(PinPhase.locked);
  PinSessionState.unlocked(Uint8List dek, {bool needsPinSetup = false})
    : this(PinPhase.unlocked, dek: dek, needsPinSetup: needsPinSetup);

  bool get isUnlocked => phase == PinPhase.unlocked;
}

class PinSessionNotifier extends StateNotifier<PinSessionState> {
  final Ref _ref;

  PinSessionNotifier(this._ref) : super(const PinSessionState.bootstrapping()) {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final dek = _ref.read(dekManagerProvider);

      // Self-heal: iOS Simulator (and some real-device flows) preserve
      // `flutter_secure_storage` entries across app uninstalls. Either
      // direction of mismatch leaves SQLCipher unable to write (it
      // silently mounts the file with the wrong key as read-only,
      // producing "attempt to write a readonly database" on the first
      // INSERT). We detect both directions and reset to a clean slate:
      //
      //   (a) wrapped DEK exists but DB file is gone → wipe wrap so
      //       bootstrap creates a fresh DEK matched to the new DB.
      //   (b) DB file exists but wrapped DEK is gone → delete the DB
      //       so a fresh one is created under the new wrap.
      final hasWrap = (await dek.currentKekKind()) != null;
      final hasFile = await LocalDatabase.fileExists();
      if (hasWrap && !hasFile) {
        await dek.clearPinAndDekState();
      } else if (!hasWrap && hasFile) {
        await LocalDatabase.closeAndDelete();
      }

      // Bootstrap the DEK if this is a fresh install / first run with the
      // feature enabled. Returns true if a fresh DEK was just created.
      await dek.bootstrapIfNeeded();

      final pin = _ref.read(pinServiceProvider);
      if (await pin.isPinSet()) {
        state = const PinSessionState.locked();
      } else {
        // No PIN — DEK is wrapped under device secret; unwrap immediately so
        // the rest of the app can open the DB without user interaction. We
        // flag `needsPinSetup` so AppShell knows to prompt the user once the
        // wallet is ready.
        final unwrapped = await dek.unwrapWithDeviceSecret();
        state = PinSessionState.unlocked(unwrapped, needsPinSetup: true);
      }
    } catch (e) {
      // Leave bootstrapping state on hard failure; AppShell shows an error.
      // Surface via state if you want a dedicated error phase later.
      rethrow;
    }
  }

  /// Called by LockScreen when the user successfully verifies their PIN.
  void unlock(Uint8List dek) {
    state = PinSessionState.unlocked(dek);
  }

  /// Called by AppShell when the app is backgrounded.
  void lock() {
    if (state.phase == PinPhase.unlocked) {
      // Best-effort RAM wipe (Dart cannot guarantee this; for sensitive
      // material we'd use a native buffer, but this is at least a hint).
      final dek = state.dek;
      if (dek != null) {
        for (var i = 0; i < dek.length; i++) {
          dek[i] = 0;
        }
      }
      state = const PinSessionState.locked();
    }
  }

  /// Called after PIN setup completes during onboarding.
  void onPinSetCompleted(Uint8List dek) {
    state = PinSessionState.unlocked(dek);
  }

  /// Called by AppShell when the user dismisses or completes the mandatory
  /// PIN setup screen — clears the prompt flag so we don't re-show the screen.
  void clearPinSetupPrompt() {
    if (state.phase == PinPhase.unlocked && state.needsPinSetup) {
      final dek = state.dek;
      if (dek != null) {
        state = PinSessionState.unlocked(dek);
      }
    }
  }

  /// Called after termination wipe — return to bootstrapping so AppShell
  /// re-runs setup. Re-invokes [_initialize] so the session walks through
  /// the same path a fresh app launch would (bootstrap DEK → noPin/locked
  /// → unlocked-with-needsPinSetup), instead of being stuck in
  /// `bootstrapping` forever.
  void reset() {
    state = const PinSessionState.bootstrapping();
    _initialize();
  }
}

final pinSessionProvider =
    StateNotifierProvider<PinSessionNotifier, PinSessionState>((ref) {
      return PinSessionNotifier(ref);
    });

// ─── DEK resolver injection ─────────────────────────────────────────────────
//
// LocalDatabase needs a way to fetch the DEK; we wire pinSessionProvider as
// the source. The first call from databaseProvider will await unlock.

/// Convenience: returns the current unlocked DEK or throws if locked.
Uint8List requireDek(Ref ref) {
  final s = ref.read(pinSessionProvider);
  final dek = s.dek;
  if (s.phase != PinPhase.unlocked || dek == null) {
    throw StateError('Database accessed while locked');
  }
  return dek;
}

// ─── Internal helper ────────────────────────────────────────────────────────

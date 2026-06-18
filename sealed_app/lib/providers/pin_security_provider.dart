/// Unified PIN security surface.
///
/// Collapses four raw providers into one [PinSecurityNotifier]:
///   - [pinServiceProvider]       — KDF + DEK wrap/unwrap
///   - [terminationServiceProvider] — duress code marker
///   - [pinAttemptTrackerProvider]  — wrong-PIN strike counter
///   - [wipeServiceFromContainer]   — the panic wipe path
///
/// UI screens (lock, pin setup, pin confirm, change-pin, change-termination)
/// should depend on this notifier only — never reach for the raw services
/// directly. The DEK lifecycle stays on [pinSessionProvider]; this notifier
/// commits the unlocked DEK to that session on success and never exposes it
/// through its own state. This preserves the invariant that the DEK lives
/// in exactly one place in RAM (privacy-critical).
///
/// Wipe is injected via [wipeRunnerProvider] so tests can assert the
/// trigger without exercising the real destructive code path. Production
/// builds wire it to `wipeServiceFromContainer(...).silentWipe()`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/log.dart';
import 'package:sealed_app/features/auth/pin_auth.dart';
import 'package:sealed_app/providers/pin_provider.dart';

// ─── Wipe runner ────────────────────────────────────────────────────────────
//
// Indirection: lets tests substitute a recording fake without touching the
// real [WipeService] (which would tear down secure storage, the SQLCipher
// file, and SharedPreferences inside a unit test).

typedef WipeRunner = Future<void> Function();

final wipeRunnerProvider = Provider<WipeRunner>((ref) {
  return () async {
    final container = ref.container;
    await wipeServiceFromContainer(container).silentWipe();
  };
});

// ─── Session controller indirection ─────────────────────────────────────────
//
// The new notifier forwards exactly three session mutations into the
// existing [PinSessionNotifier]: unlock, onPinSetCompleted, reset. We wrap
// those behind an interface so unit tests can inject a recording fake —
// the real [PinSessionNotifier] is constructed eagerly and runs
// `_initialize()` synchronously, which hits `LocalDatabase.fileExists()`
// (a native plugin) and is not viable in test land.
//
// Privacy invariant preserved: the controller does NOT expose the DEK
// for reading; it only forwards it INTO `pinSessionProvider` where the
// DEK has always lived. Same single-RAM-location property as before.

abstract class PinSessionController {
  void unlock(Uint8List dek);
  void onPinSetCompleted(Uint8List dek);
  void reset();
}

class _DefaultPinSessionController implements PinSessionController {
  final Ref _ref;
  _DefaultPinSessionController(this._ref);

  @override
  void unlock(Uint8List dek) =>
      _ref.read(pinSessionProvider.notifier).unlock(dek);

  @override
  void onPinSetCompleted(Uint8List dek) =>
      _ref.read(pinSessionProvider.notifier).onPinSetCompleted(dek);

  @override
  void reset() => _ref.read(pinSessionProvider.notifier).reset();
}

final pinSessionControllerProvider = Provider<PinSessionController>(
  (ref) => _DefaultPinSessionController(ref),
);

// ─── State ──────────────────────────────────────────────────────────────────

/// Immutable snapshot of the user-facing PIN security surface.
///
/// Does NOT expose the DEK — that stays on [pinSessionProvider].
class PinSecurityState {
  /// Consecutive wrong-PIN strikes since the last successful unlock.
  /// Capped at [PinAttemptTracker.maxAttempts]; beyond that the lock
  /// screen wipes the device.
  final int attemptCount;

  /// True iff the user has configured a termination (duress) code.
  final bool isTerminationConfigured;

  /// Last error message surfaced from a failed operation (e.g. KDF blew up).
  /// Cleared on every successful op. Wrong-PIN / wrong-termination are
  /// returned as bool results, not propagated through this field — the UI
  /// layer renders them inline.
  final String? lastError;

  const PinSecurityState({
    this.attemptCount = 0,
    this.isTerminationConfigured = false,
    this.lastError,
  });

  /// True once the attempt budget is exhausted. UI flows that drive
  /// `confirmAndUnlock` use this to decide whether to short-circuit to the
  /// wipe branch instead of asking the KDF.
  bool get isLockedOut => attemptCount >= PinAttemptTracker.maxAttempts;

  PinSecurityState copyWith({
    int? attemptCount,
    bool? isTerminationConfigured,
    String? lastError,
    bool clearError = false,
  }) {
    return PinSecurityState(
      attemptCount: attemptCount ?? this.attemptCount,
      isTerminationConfigured:
          isTerminationConfigured ?? this.isTerminationConfigured,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

// ─── Notifier ───────────────────────────────────────────────────────────────

class PinSecurityNotifier extends AsyncNotifier<PinSecurityState> {
  PinService get _pin => ref.read(pinServiceProvider);
  TerminationService get _term => ref.read(terminationServiceProvider);
  PinAttemptTracker get _tracker => ref.read(pinAttemptTrackerProvider);
  WipeRunner get _wipeRunner => ref.read(wipeRunnerProvider);
  PinSessionController get _session => ref.read(pinSessionControllerProvider);

  @override
  Future<PinSecurityState> build() async {
    final count = await _tracker.attemptCount();
    final termConfigured = await _term.isConfigured();
    return PinSecurityState(
      attemptCount: count,
      isTerminationConfigured: termConfigured,
    );
  }

  // ── PIN setup / change ────────────────────────────────────────────────────

  /// Wraps [PinService.setPin]. Onboarding path: there is no existing PIN.
  /// On success the freshly-wrapped DEK is committed to [pinSessionProvider]
  /// so the rest of the app can keep reading the database without another
  /// unlock prompt.
  Future<void> setPin(String pin) async {
    try {
      // PinService.setPin moves the DEK from device-wrap to PIN-wrap and
      // hands back the freshly-wrapped DEK. Commit it straight into the
      // session — no second verifyAndUnwrap, which would re-run Argon2id
      // (~500ms) on the onboarding path just to recover what we already have.
      final dek = await _pin.setPin(pin);
      _session.onPinSetCompleted(dek);
      state = AsyncData(_current.copyWith(clearError: true));
    } catch (e) {
      state = AsyncData(_current.copyWith(lastError: e.toString()));
      rethrow;
    }
  }

  /// Verify + unwrap + commit to session. Returns true on success.
  ///
  /// Strike accounting is PRE-incremented: the wrong-attempt counter is
  /// persisted BEFORE the ~500ms Argon2id derivation runs, then cleared
  /// only on a confirmed-correct PIN. This closes a brute-force bypass —
  /// previously the strike was recorded only AFTER the KDF completed, so an
  /// attacker could kill the app mid-derivation and never consume a strike,
  /// making unlimited guesses against the 5-strike wipe budget. With the
  /// pre-increment, a kill mid-verify leaves the strike already on disk.
  ///
  /// Net effect is unchanged for honest flows: one wrong PIN = exactly one
  /// strike (incremented up-front, never reset because verification fails);
  /// a correct PIN = counter cleared. When the pre-incremented count crosses
  /// [PinAttemptTracker.maxAttempts] we trigger [wipeNow] — same policy as
  /// the lock screen's 5th-strike branch. Returns false on any failure so
  /// the UI can render its disguise message uniformly.
  ///
  /// Termination interaction: the lock screen checks [verifyTermination]
  /// BEFORE calling this method and returns early on a match, so a duress
  /// code never reaches here and never burns a strike.
  Future<bool> confirmAndUnlock(String pin) async {
    // Pre-increment: persist the strike before the KDF so a mid-verify kill
    // cannot dodge the budget. Reset() below undoes it on a correct PIN.
    final prior = await _tracker.attemptCount();
    final pending = await _tracker.recordFailedAttempt();
    state = AsyncData(_current.copyWith(attemptCount: pending));
    try {
      // [unlock-timing] One-off diagnostic for the low-end-Android slow-unlock
      // report. Splits verify(KDF+unwrap) vs the post-unlock session commit so
      // logcat shows whether the ~15s is the KDF or downstream warmup. Remove
      // once the regression is pinned + fixed.
      final swVerify = Stopwatch()..start();
      final dek = await _pin.verifyAndUnwrap(pin);
      swVerify.stop();
      // Correct PIN — roll back the speculative strike.
      await _tracker.reset();
      final swCommit = Stopwatch()..start();
      _session.unlock(dek);
      state = AsyncData(_current.copyWith(attemptCount: 0, clearError: true));
      swCommit.stop();
      debugPrint(
        '[unlock-timing] verifyAndUnwrap=${swVerify.elapsedMilliseconds}ms '
        'sessionCommit=${swCommit.elapsedMilliseconds}ms',
      );
      return true;
    } on PinIncorrectException {
      // Wrong PIN — the strike already landed up-front; just enforce the cap.
      Log.d('confirmAndUnlock: wrong PIN, strike $pending recorded pre-KDF');
      if (pending >= PinAttemptTracker.maxAttempts) {
        await wipeNow();
      }
      return false;
    } catch (e) {
      // Non-incorrect-PIN failures (KDF blowup, missing salt) — NOT a
      // brute-force signal, so roll back the speculative strike to the prior
      // count (preserving any genuine earlier strikes) and surface the error
      // instead of letting infrastructure faults drain the budget.
      await _tracker.setCount(prior);
      state = AsyncData(
        _current.copyWith(attemptCount: prior, lastError: e.toString()),
      );
      return false;
    }
  }

  /// Change PIN, gated by [oldPin]. Wrong-old-PIN throws
  /// [PinIncorrectException] (same as direct service); does NOT bump the
  /// attempt tracker (settings-flow attempts have always been free —
  /// only lock-screen attempts count toward the wipe budget).
  Future<void> changePin(String oldPin, String newPin) async {
    try {
      await _pin.changePin(oldPin, newPin);
      state = AsyncData(_current.copyWith(clearError: true));
    } catch (e) {
      state = AsyncData(_current.copyWith(lastError: e.toString()));
      rethrow;
    }
  }

  // ── Termination code ──────────────────────────────────────────────────────

  /// Sets or replaces the termination (duress) code.
  Future<void> setTerminationCode(String code) async {
    try {
      await _term.setCode(code);
      state = AsyncData(
        _current.copyWith(isTerminationConfigured: true, clearError: true),
      );
    } catch (e) {
      state = AsyncData(_current.copyWith(lastError: e.toString()));
      rethrow;
    }
  }

  /// Verifies a candidate termination code. Returns true on match.
  /// Does NOT trigger a wipe — the caller decides what to do (the lock
  /// screen's duress branch wipes; the change-termination flow uses this
  /// as a non-destructive gate).
  Future<bool> verifyTermination(String code) async {
    return _term.matches(code);
  }

  /// Removes the configured termination code, if any. Wraps
  /// [TerminationService.disable].
  Future<void> clearTermination() async {
    try {
      await _term.disable();
      state = AsyncData(
        _current.copyWith(isTerminationConfigured: false, clearError: true),
      );
    } catch (e) {
      state = AsyncData(_current.copyWith(lastError: e.toString()));
      rethrow;
    }
  }

  // ── Attempt tracker ───────────────────────────────────────────────────────

  /// Bumps the wrong-PIN counter. Exposed so UI flows that drive their own
  /// verification path (e.g. a custom gate) can mirror the lock-screen
  /// policy. [confirmAndUnlock] calls this internally for its own
  /// failures — callers should not double-bump.
  Future<void> recordFailedAttempt() => _recordFailedAttempt();

  Future<void> _recordFailedAttempt() async {
    final next = await _tracker.recordFailedAttempt();
    state = AsyncData(_current.copyWith(attemptCount: next));
    if (next >= PinAttemptTracker.maxAttempts) {
      await wipeNow();
    }
  }

  // ── Wipe ──────────────────────────────────────────────────────────────────

  /// Panic wipe + session reset. Used by the lock screen's 5th-strike and
  /// duress branches, and by Settings → "Erase this device". Never throws
  /// (underlying [WipeService.silentWipe] swallows errors so duress flows
  /// don't leak success/failure to an observer).
  ///
  /// After wipe we also reset [pinSessionProvider] so the UI can pop to
  /// the root and the AppShell rebuilds onto onboarding — same shape both
  /// existing call sites do today, kept here so B1b screens don't need to
  /// know about [pinSessionProvider].
  Future<void> wipeNow() async {
    await _wipeRunner();
    // pinSessionProvider.reset() is the existing post-wipe contract — see
    // wipe.dart performLogout step (called from silentWipe), but the
    // top-level session-reset still belongs at the call site.
    _session.reset();
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  PinSecurityState get _current => state.value ?? const PinSecurityState();
}

// ─── Provider ───────────────────────────────────────────────────────────────

final pinSecurityProvider =
    AsyncNotifierProvider<PinSecurityNotifier, PinSecurityState>(
      PinSecurityNotifier.new,
    );

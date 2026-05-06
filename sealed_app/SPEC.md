# Spec: UX Polish — Lock, Termination, Logout, Performance

## Objective

Five small UX fixes across auth/lock/logout flows. Reduce friction without weakening crypto invariants.

**Target user:** existing Sealed user with PIN configured.

**Why now:** current behaviors annoy users (immediate lock on every notification-bar pull, jarring "Incorrect PIN" on duress wipe, ~500ms unlock hang, mnemonic exposed on every logout intent).

---

## In-Scope Changes

### 1. Inactivity-based lock (replaces immediate-on-background)

**Current:** `_AppShellState.didChangeAppLifecycleState` locks on `paused | inactive | hidden` immediately.

**New:** start a grace timer on backgrounding; lock only after **25 seconds** of continuous background. Cancel timer on resume. Pulling notification bar / Control Centre triggers `inactive` then `resumed` quickly → no lock.

**Acceptance:**
- Pull notification shade for <25s, return → still unlocked, no PIN prompt.
- Background app (home/lock device) for >25s, foreground → LockScreen shown.
- Foreground transition between 0-25s cancels timer cleanly (no lock fires after resume).
- Force-kill / cold start → still locked (existing behavior, untouched).

**Files:** `lib/app.dart` (timer in `_AppShellState`), maybe new constant in `core/constants.dart`.

**Open questions:**
- Q1: Exact duration — 20s, 25s, or 30s? Proposing **25s**.
- Q2: Should `inactive` (transient state, e.g. incoming call) reset the timer or keep it running? Proposing: only `paused | hidden` arms timer; `inactive` ignored.

### 2. Termination Code row when already set

**Current:** row subtitle shows "Set" / "Not set". Action label uniform.

**New:** when `_termSet == true`, row trailing label = **"Change"**. When not set, label = **"Set"**. Tap behavior unchanged (already routes to change/remove dialog when set, setup flow when not).

**Acceptance:**
- Fresh install / no termination → row shows "Set".
- After configuring termination → row shows "Change".
- Tap on "Change" → existing Change/Remove dialog.
- Tap on "Set" → existing setup flow.

**Files:** `lib/features/settings/screens/settings_screen.dart`.

### 3. Termination code shows "Terminating data..." instead of "Incorrect PIN"

**Current** (`lock_screen.dart` `_wipeAndExit`): hard-coded "Incorrect PIN" disguise on termination match — intentional duress-disguise so attacker can't tell which code triggered wipe.

**New:** show "Terminating data…" while wipe runs.

**⚠️ SECURITY TRADE-OFF — needs explicit sign-off:**
- This **removes** the duress-disguise property. Attacker watching screen can now distinguish duress wipe from wrong-PIN wipe.
- Threat model `SECURITY.md` lists duress-disguise as a property. Touching it without review violates `CONTRIBUTING.md` crypto-core policy.
- 5th-strike wipe (wrong-PIN brute-force) currently uses same path. Should it also show "Terminating data…", or stay "Incorrect PIN"?

**Proposal:** only termination-match path shows "Terminating data…"; 5th-strike stays disguised. Or: keep disguise, just remove the 0.5s delay.

**Acceptance:** TBD pending decision above.

**Files:** `lib/features/auth/screens/lock_screen.dart`.

### 4. Logout: gate mnemonic behind PIN re-entry

**Current** (`settings_screen.dart` `_logout`): tapping Log Out immediately shows recovery phrase in a dialog (selectable text), then "I've saved it" → wipes.

**New flow:**
1. Tap "Log Out" → confirmation dialog: *"Logging out will wipe local data. Back up your recovery phrase first."* with `[Show Recovery Phrase]` button + `[Cancel]`.
2. Tap `[Show Recovery Phrase]` → PIN entry screen (reuse `PinEntryView`).
3. PIN verified → mnemonic dialog (existing UI) with `[I've saved it]` → wipe.
4. Wrong PIN → re-prompt; max-attempt path same as `LockScreen` (5-strike wipe).

**Acceptance:**
- Mnemonic never visible without PIN entry within logout flow.
- Cancel at any step aborts logout; no wipe, no state mutation.
- PIN attempt counter shared with LockScreen tracker (don't open second budget).

**Files:** `lib/features/settings/screens/settings_screen.dart`, possibly new `lib/features/auth/screens/pin_confirm_screen.dart` (modal route).

### 5. Smooth unlock — kill the 500ms hang

**Current:** after 6th digit entered, `_submit` runs sequentially:
- `term.matches(code)` (Argon2id verify)
- `pin.verifyAndUnwrap(code)` (Argon2id verify + AES-GCM unwrap)
- Setting `pinSession` → AppShell rebuild → DB providers initialize

User perceives ~500ms freeze with filled dots before transition.

**Proposal:**
- Profile first (`flutter run --profile`, time each step). Don't optimize blind.
- Likely culprits: synchronous Argon2id on UI isolate, DB open on resume, provider rebuild cascade.
- Fixes (in order of impact):
  1. Run Argon2id verification in `compute()` isolate.
  2. Defer non-critical provider warm-up post-unlock (lazy load).
- **Fallback (if hang remains):** disable any blocking overlay during loading phase — keep existing `quantum-animation.gif` (`assets/quantum-animation.gif`, used in `pin_entry_view.dart` `showQuantumBackdrop`) running uninterrupted so user sees continuous motion instead of frozen frame. No new spinner; reuse already-precached gif.

**Acceptance:**
- From 6th digit → MainShell visible: <150ms perceived latency, OR a continuous animation covering any latency >100ms (no frozen-dots state).
- No regression in unlock correctness or attempt-counter semantics.

**Files:** `lib/features/auth/screens/lock_screen.dart`, `lib/services/pin_service.dart`, possibly `lib/providers/pin_provider.dart`.

---

## Tech Stack

- Flutter (Dart), Riverpod, sqflite (SQLCipher).
- Existing: `pin_service.dart` (Argon2id KDF), `termination_service.dart`, `wipe_service.dart`, `pin_attempt_tracker.dart`.

## Commands

```
Build       : flutter build ios --debug   (or android/macos)
Test        : flutter test
Single test : flutter test test/features/auth/lock_screen_test.dart
Lint        : flutter analyze
Format      : dart format --set-exit-if-changed .
Dev         : flutter run -d ios | -d macos
```

## Project Structure

```
lib/app.dart                               → AppShell + lifecycle observer (item 1)
lib/features/auth/screens/lock_screen.dart → LockScreen (items 3, 5)
lib/features/auth/widgets/pin_entry_view.dart → shared PIN UI
lib/features/settings/screens/settings_screen.dart → logout flow (items 2, 4)
lib/services/pin_service.dart              → KDF + unwrap (item 5 isolate move)
lib/providers/pin_provider.dart            → PinSessionState
test/features/auth/                        → new tests for lock timer, logout gate
```

## Code Style

Match existing. Riverpod `ConsumerStatefulWidget` pattern. Doc comments above classes.

```dart
/// Inactivity lock timer — fires LockSession after [_lockGraceDuration] of
/// continuous background. Cancelled on resume. See SPEC.md §1.
Timer? _lockTimer;
static const Duration _lockGraceDuration = Duration(seconds: 25);

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
    _lockTimer ??= Timer(_lockGraceDuration, _lockNow);
  } else if (state == AppLifecycleState.resumed) {
    _lockTimer?.cancel();
    _lockTimer = null;
  }
}
```

## Testing Strategy

- **Unit:** PIN attempt tracker shared across logout-gate + lock screen.
- **Widget:** LockScreen renders "Terminating data…" on termination match; logout flow requires PIN before mnemonic.
- **Integration:** lifecycle timer — mock `WidgetsBindingObserver`, fire `paused → resumed` <25s and >25s, assert lock state.
- **Manual:** Notification-bar pull on real iOS/Android device; measure unlock latency on mid-tier device.

## Boundaries

**Always do:**
- Run `flutter analyze` + `flutter test` before commit.
- Preserve PinAttemptTracker semantics (5-strike wipe budget shared).
- Keep DEK never-on-disk invariant.
- Use existing `wipeServiceFromContainer` for any wipe path.

**Ask first:**
- §3 duress-disguise removal — touches threat-model property. Need explicit user OK.
- Adding new dependencies (none expected).
- Changing `pin_service.dart` Argon2id parameters (only moving execution to isolate is OK).

**Never do:**
- Weaken Argon2id work factor for "performance".
- Cache PIN, PIN-derived key, or DEK on disk.
- Skip PIN check in logout flow under "convenience" reasoning.
- Show mnemonic without PIN re-entry (item 4 entire purpose).

## Success Criteria

- [ ] Notification-shade pull <25s does not lock app.
- [ ] Background >25s locks app on next foreground.
- [ ] Lock screen shows "Terminating data…" on termination match (pending §3 sign-off).
- [ ] Logout requires PIN re-entry before mnemonic visible.
- [ ] Unlock transition has no frozen ≥150ms gap — quantum-animation.gif keeps moving through unlock latency.
- [ ] `flutter analyze` clean.
- [ ] All new + existing tests pass.

## Open Questions

All resolved. Moving to Plan phase.

**Decisions locked:**
- §1: 25s timeout. Only `paused | hidden` arm timer (`inactive` ignored).
- §2: row label = "Change" if termination set, "Set" otherwise.
- §3: termination match → "Terminating data…". 5th-strike wrong-PIN wipe → keep "Incorrect PIN" disguise.
- §4: full-screen PIN re-entry route (reuse `PinEntryView`) before mnemonic.
- §5: profile first → isolate Argon2id → fallback keep `quantum-animation.gif` running.

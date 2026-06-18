// Push pre-sync background pipeline (internal/docs/plan-push-prefetch-sync.md, T3).
//
// Fetch → match → stage. Runs in the FCM background isolate (and, on the iOS
// locked branch, the main isolate). Reads the on-chain cursor but NEVER advances
// it, and NEVER opens the PIN-gated DEK DB — matched envelopes go to the
// device-secret-encrypted [WakeStageStore], which the main isolate drains and
// decrypts into the real DB on unlock.
//
// The crypto match (X25519 tag-check + ML-KEM first-contact trial-decap, ~3ms
// each per the T0 spike → KEM-in-window is fine) is injected via [WakeMatcher]
// so this orchestration unit-tests with fakes and the real key-coupled matcher
// is wired separately (no Riverpod here — constructible in a cold isolate).
library;

import 'package:sealed_app/infra/local/wake_stage_store.dart';

/// Read-only source of on-chain envelopes from the current cursor. MUST NOT
/// advance the cursor — the main isolate's [MessageSync] is the sole cursor
/// writer.
abstract class WakeEnvelopeSource {
  Future<List<StagedEnvelope>> fetchSinceCursor();
}

/// Decides whether an envelope is addressed to this device. Uses the PIN-free
/// keys (tag-check / KEM trial-decap); never opens the DEK DB.
abstract class WakeMatcher {
  Future<bool> matches(StagedEnvelope candidate);
}

/// Orchestrates the background pre-sync: fetch candidates, match each, stage the
/// matches, all under a hard wall-clock cap (partial staging on timeout is fine;
/// the on-open sync reconciles the rest).
class BackgroundWakeSync {
  BackgroundWakeSync({
    required WakeEnvelopeSource source,
    required WakeMatcher matcher,
    required WakeStageStore store,
    this.cap = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _source = source,
       _matcher = matcher,
       _store = store,
       _now = clock ?? DateTime.now;

  final WakeEnvelopeSource _source;
  final WakeMatcher _matcher;
  final WakeStageStore _store;
  final Duration cap;
  final DateTime Function() _now;

  /// Returns the number of envelopes staged. Stops early (partial) once the cap
  /// is reached. Fetch failure ⇒ 0 staged (loss-tolerant; on-open sync recovers).
  Future<int> run() async {
    final deadline = _now().add(cap);
    final List<StagedEnvelope> candidates;
    try {
      candidates = await _source.fetchSinceCursor();
    } catch (_) {
      return 0;
    }

    var staged = 0;
    for (final c in candidates) {
      if (!_now().isBefore(deadline)) break; // cap reached → partial result
      bool matched;
      try {
        matched = await _matcher.matches(c);
      } catch (_) {
        continue; // one bad envelope can't stall the pass
      }
      if (matched) {
        await _store.append(c);
        staged++;
      }
    }
    return staged;
  }
}

/// Notifier surface for the credit-code redeem flow (PLAN-snark-redeem-B4).
///
/// Wraps [CreditsService.redeem] plus the post-redeem PQ-key republish into a
/// single typed-phase notifier. UI callers no longer await
/// `credits.redeem(... onPhase: ...)` and then chase a manual
/// `keyManagementProvider.notifier.regenerateAndPublish()` — they call
/// [RedeemNotifier.redeem] and watch [RedeemState.phase] for progress.
///
/// Privacy invariant: the SNARK prover stays inside [CreditsService]. This
/// notifier orchestrates only — no crypto, no key bytes, no preimage on its
/// public surface. [RedeemState] exposes only a [RedeemPhase], an optional
/// error string, an optional [lastException] for typed-error UX, and the
/// last successful txid.
///
/// On a successful redeem we always run [KeyManagementNotifier.regenerateAndPublish].
/// The credits have already landed on-chain at that point — a failure inside
/// key regen/publish is surfaced via the key-management notifier's own state
/// (we do NOT roll the redeem back), so we still transition this notifier to
/// [RedeemPhase.done]. Matches pre-B4 widget behavior, where the publish call
/// already happened post-redeem in an awaited-but-non-blocking fashion.
library;

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sealed_app/core/service_locator.dart' show keyServiceProvider;
import 'package:sealed_app/features/wallet/credits_service.dart'
    as cs
    show CreditsService;
import 'package:sealed_app/infra/crypto/key_service.dart' show KeyService;
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';

// ============================================================================
// PHASE / STATE
// ============================================================================

/// Lifecycle phase for the redeem flow.
///
/// Happy paths:
///   idle → proving → submitting → publishing → done   (SNARK path)
///   idle → submitting → publishing → done             (legacy path — no proving)
///
/// `error` is any failure inside the redeem call itself (bad code, network,
/// prover failure, contract assert). Post-redeem key republish failures do
/// NOT flip us back to `error` — credits are already claimed on chain at that
/// point; the key-management notifier owns its own error reporting.
enum RedeemPhase { idle, proving, submitting, publishing, done, error }

@immutable
class RedeemState {
  final RedeemPhase phase;

  /// Stringified error message, populated when [phase] == [RedeemPhase.error].
  final String? lastError;

  /// The original thrown object, so widgets can switch on typed errors
  /// ([BadRedeemCodeError], [RedeemContractError], [SnarkProverException], …)
  /// and resolve their own user-visible strings. Never includes redeem-code
  /// material — only what the underlying call threw.
  final Object? lastException;

  /// App-call txid of the last successful redeem. Set on `done`.
  final String? lastTxId;

  const RedeemState({
    this.phase = RedeemPhase.idle,
    this.lastError,
    this.lastException,
    this.lastTxId,
  });

  RedeemState copyWith({
    RedeemPhase? phase,
    String? lastError,
    Object? lastException,
    String? lastTxId,
  }) {
    return RedeemState(
      phase: phase ?? this.phase,
      lastError: lastError ?? this.lastError,
      lastException: lastException ?? this.lastException,
      lastTxId: lastTxId ?? this.lastTxId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RedeemState &&
          other.phase == phase &&
          other.lastError == lastError &&
          other.lastException == lastException &&
          other.lastTxId == lastTxId;

  @override
  int get hashCode => Object.hash(phase, lastError, lastException, lastTxId);

  @override
  String toString() =>
      'RedeemState(phase: $phase, lastError: $lastError, lastTxId: $lastTxId)';
}

// ============================================================================
// NOTIFIER
// ============================================================================

class RedeemNotifier extends Notifier<RedeemState> {
  @override
  RedeemState build() => const RedeemState();

  /// Active cancel token for an in-flight redeem (SNARK prove phase). Used
  /// by [cancel] so the widget's lifecycle hook can cancel without holding a
  /// direct reference to the token.
  CancelToken? _activeCancel;

  /// Cancel an in-flight redeem. No-op when nothing is in flight or when the
  /// token has already been cancelled. The credits service surfaces a
  /// [SnarkProverException] with kind `cancelled`, which the redeem call's
  /// catch arm turns into an `error` state.
  void cancel() {
    final c = _activeCancel;
    if (c != null && !c.isCancelled) {
      c.cancel();
    }
  }

  /// Redeem a credit code and, on success, regenerate + republish the PQ key
  /// bundle.
  ///
  /// Pre-conditions: a wallet must be ready via [walletProvider]. If
  /// the wallet isn't ready we set [RedeemPhase.error] with a stable message
  /// and return — the UI surfaces it through [RedeemState.lastError].
  ///
  /// On bad code / chain error / prover failure: phase = error, [lastError]
  /// populated, [lastException] set so the UI can map typed errors to
  /// localized strings. The key republish is NOT attempted in this case.
  ///
  /// On success: phase walks proving (if SNARK) → submitting → publishing →
  /// done. [lastTxId] is set to the redeem app-call txid.
  Future<void> redeem(String code) async {
    // Reset to a clean in-flight state — clear any prior error so consumers
    // re-render the spinner instead of the old inline message.
    state = const RedeemState(phase: RedeemPhase.idle);

    // Resolve the wallet via `.future` so we tolerate the async wallet build
    // still being in flight on first redeem. Falling back to `.value` here
    // would race the wallet bootstrap and yield a spurious "Wallet not ready"
    // on cold-start redeem.
    final String? wallet;
    try {
      final ws = await ref.read(walletProvider.future);
      wallet = ws.walletAddress;
    } catch (e) {
      state = RedeemState(
        phase: RedeemPhase.error,
        lastError: 'Wallet not ready. Try again.',
        lastException: e,
      );
      return;
    }
    if (wallet == null || wallet.isEmpty) {
      state = const RedeemState(
        phase: RedeemPhase.error,
        lastError: 'Wallet not ready. Try again.',
      );
      return;
    }

    final cancel = CancelToken();
    _activeCancel = cancel;

    try {
      // Regenerate the PQ keypair locally (rolls keys each redeem — parity with
      // the legacy `regenerateAndPublish` behavior) and load the enc + scan
      // pubkeys from the freshly written bundle. Shared by BOTH redeem paths so
      // each one mints the full denomination AND publishes keys atomically (no
      // separate publishKeys credit spend → user ends with exactly the
      // denomination, e.g. 500, not 499).
      state = const RedeemState(phase: RedeemPhase.submitting);
      final preimage = cs.CreditsService.preimageFromCode(code);
      final KeyService keyService = await ref.read(keyServiceProvider.future);
      final regenerated = await keyService.regeneratePqKeysFromMasterSeed();
      ref.invalidate(keysProvider);
      final keys = await keyService.loadKeys();
      if (keys == null) {
        throw StateError('keys missing after regeneration');
      }
      final encPub = Uint8List.fromList(
        (await keys.encryptionKeyPair.extractPublicKey()).bytes,
      );
      final scanPub = Uint8List.fromList(
        (await keys.scanKeyPair.extractPublicKey()).bytes,
      );

      // SNARK-sold codes (leaf committed in an on-chain Merkle root) have NO
      // `c:` commitment box, so the legacy atomic `redeemAndPublish` below would
      // assert BAD_CODE. Route them through the proof path — `redeem` uses the
      // `redeemWithProofAndPublishKeys` contract method, which folds the key
      // publish into the SNARK redeem so the buyer keeps the FULL denomination,
      // exactly like the legacy path.
      final credits = await ref.read(creditsServiceProvider.future);
      if (await credits.isSnarkRedeemable(code)) {
        state = const RedeemState(phase: RedeemPhase.proving);
        final txid = await credits.redeem(
          code: code,
          fromAddress: wallet,
          encryptionPubkey: encPub,
          scanPubkey: scanPub,
          pqPubkey: regenerated.publicKey,
        );
        ref.invalidate(creditsBalanceProvider);
        final ops = await ref.read(sealedCreditOpsProvider.future);
        ops.invalidate(wallet);
        state = RedeemState(phase: RedeemPhase.done, lastTxId: txid);
        return;
      }

      // Legacy free-code onboarding: atomic redeem + key publish.
      state = const RedeemState(phase: RedeemPhase.publishing);
      final chain = await ref.read(sealedChainClientProvider.future);
      final txid = await chain.redeemAndPublish(
        preimage: preimage,
        encryptionPubkey: encPub,
        scanPubkey: scanPub,
        pqPubkey: regenerated.publicKey,
      );

      // Refresh credit balance so settings + top-up screens reflect the new
      // total (full denomination, no publishKeys spend).
      ref.invalidate(creditsBalanceProvider);

      // The send-path credit pre-flight reads a SEPARATE in-process cache
      // (SealedCreditChainOps) that `redeemAndPublish` bypasses — invalidating
      // the UI provider above does not touch it. Without this, the first send
      // right after a 0→N redeem reads the stale 0 and throws NoCreditsError
      // ("Credits Required"). Drop the redeemer's cache entry so the next
      // getCredits refetches from chain.
      final ops = await ref.read(sealedCreditOpsProvider.future);
      ops.invalidate(wallet);

      state = RedeemState(phase: RedeemPhase.done, lastTxId: txid);
    } catch (e, st) {
      debugPrint('[RedeemNotifier] redeem failed: $e\n$st');
      state = RedeemState(
        phase: RedeemPhase.error,
        lastError: e.toString(),
        lastException: e,
      );
    } finally {
      _activeCancel = null;
    }
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final redeemProvider = NotifierProvider<RedeemNotifier, RedeemState>(
  RedeemNotifier.new,
);

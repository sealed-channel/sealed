import 'dart:typed_data';
import 'package:sealed_app/core/log.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';

// ============================================================================
// KEYS STATE
// ============================================================================

/// Manages cryptographic keys state using modern AsyncNotifier pattern.
/// Keys are derived from the local wallet seed (no external wallet needed).
class KeysNotifier extends AsyncNotifier<SealedKeys?> {
  late KeyService _keyService;

  /// Single-flight guard for [deriveKeysFromLocalWallet]. Two callers can race
  /// the derivation during restore: the wallet-restore flow
  /// (`restoreFromMnemonic`) and AppShell's keys==null self-heal both fire it.
  /// Run concurrently, each independently trips the keystore-corruption
  /// recovery (storage.deleteAll + retry) in KeyService, and the two wipes/
  /// writes race — one derive throws transiently, flipping this provider to
  /// AsyncError and flashing ErrorScreen for a few frames before the other
  /// completes. Sharing one in-flight future makes duplicate callers await the
  /// same result instead of launching a second derive.
  Future<void>? _deriveInFlight;

  @override
  Future<SealedKeys?> build() async {
    // Wait for dependencies
    _keyService = await ref.watch(keyServiceProvider.future);

    // Try to load existing keys
    return _keyService.loadKeys();
  }

  /// Derive new keys from local wallet seed.
  Future<void> deriveKeysFromLocalWallet() {
    // Coalesce concurrent callers onto one derivation (see [_deriveInFlight]).
    final existing = _deriveInFlight;
    if (existing != null) return existing;

    final future = _deriveKeysFromLocalWallet();
    _deriveInFlight = future;
    return future.whenComplete(() {
      if (identical(_deriveInFlight, future)) _deriveInFlight = null;
    });
  }

  Future<void> _deriveKeysFromLocalWallet() async {
    state = const AsyncLoading();

    state = await AsyncValue.guard(() async {
      // read, not watch: this is a method (not build); watching here registers
      // a phantom dependency.
      final wallet = await ref.read(algorandWalletProvider.future);
      Log.d(
        '🔑 KeysNotifier.deriveKeysFromLocalWallet: '
        'wallet#${identityHashCode(wallet)} '
        'hasWallet=${wallet.hasWallet} '
        'address=${wallet.walletAddress}',
      );
      final hasActiveWallet = wallet.hasWallet;

      if (!hasActiveWallet) {
        throw Exception('Local wallet not created');
      }

      Log.d('🔑 KeysNotifier: Deriving keys from local wallet seed...');

      final keys = await _keyService.deriveKeysFromLocalWallet();
      Log.d('🔑 KeysNotifier: ✅ Keys derived successfully');

      // Keys are deterministically derived from the wallet seed via HKDF.
      // With memo-based accounts, there is no on-chain PDA profile to verify
      // against — the keys will be published when the user sets their username.
      // AsyncValue.guard assigns `state` from this return value — no need to
      // set it again here.
      return keys;
    });
  }

  /// Load existing keys from secure storage
  Future<void> loadKeys() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _keyService.loadKeys());
  }

  /// Clear all keys
  Future<void> clearKeys() async {
    await _keyService.deleteKeys();
    state = const AsyncData(null);
  }
}

// ============================================================================
// PROVIDER
// ============================================================================

final keysProvider = AsyncNotifierProvider<KeysNotifier, SealedKeys?>(
  KeysNotifier.new,
);

// Convenience provider for sync access (when you know keys are loaded)
final currentKeysProvider = Provider<SealedKeys?>((ref) {
  return ref.watch(keysProvider).valueOrNull;
});

extension on AsyncValue<SealedKeys?> {
  SealedKeys? get valueOrNull =>
      when(data: (keys) => keys, loading: () => null, error: (_, _) => null);
}

// ============================================================================
// KEY MANAGEMENT (PQ regen + on-chain publish orchestration)
// ============================================================================
//
// Wraps the two flows that previously lived inline in `redeem_code_sheet.dart`
// and `main_shell.dart`:
//
//   - regenerateAndPublish: re-derive PQ keys from master seed then publish
//     the full key bundle on chain. Used after a credit redeem so the
//     on-chain `pqPubkeyHash` stays aligned with the locally regenerated
//     keypair.
//
//   - ensurePublished: idempotent boot-time publish — only republishes if
//     the on-chain bundle diverges from local material, and only when the
//     wallet has credits to pay the publish fee.
//
// Privacy invariant: key material never crosses keyManagementProvider's
// public surface. [KeyManagementState] exposes only a [KeyPhase] and an
// optional error string. Callers cannot read key bytes through this notifier.
//
// The [pqPublishBlockedFlagKey] flag from `local_wallet_provider.dart` is
// honored — when set, the notifier transitions to KeyPhase.blockedByMismatch
// and refuses to regenerate or publish. Bypassing that flag would silently
// rotate the on-chain key and destroy decryptability of any in-flight
// messages encrypted against the prior key.

/// Lifecycle phase for the key-management flow.
enum KeyPhase { idle, regenerating, publishing, blockedByMismatch, done, error }

@immutable
class KeyManagementState {
  final KeyPhase phase;
  final String? lastError;

  const KeyManagementState({this.phase = KeyPhase.idle, this.lastError});

  KeyManagementState copyWith({KeyPhase? phase, String? lastError}) {
    return KeyManagementState(phase: phase ?? this.phase, lastError: lastError);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyManagementState &&
          other.phase == phase &&
          other.lastError == lastError;

  @override
  int get hashCode => Object.hash(phase, lastError);

  @override
  String toString() =>
      'KeyManagementState(phase: $phase, lastError: $lastError)';
}

class KeyManagementNotifier extends Notifier<KeyManagementState> {
  @override
  KeyManagementState build() => const KeyManagementState();

  /// Test seam — overridden in unit tests to inject a fake SharedPreferences.
  /// Default: real shared_preferences instance.
  @visibleForTesting
  Future<SharedPreferences> getPrefs() => SharedPreferences.getInstance();

  /// Regenerate PQ keys from master seed, then publish the on-chain bundle.
  ///
  /// Phase transitions on the happy path:
  ///   idle → regenerating → publishing → done
  ///
  /// If [pqPublishBlockedFlagKey] is set (wallet-restore detected a hash
  /// mismatch), transitions to KeyPhase.blockedByMismatch WITHOUT calling
  /// the chain client or KeyService.
  ///
  /// Publishes via SealedChainClient.publishKeysIfStale — idempotent when
  /// the on-chain bundle already matches local material.
  Future<void> regenerateAndPublish() async {
    final prefs = await getPrefs();
    if (prefs.getBool(pqPublishBlockedFlagKey) == true) {
      debugPrint(
        '[KeyManagement] regenerateAndPublish BLOCKED — pq mismatch flag set. '
        'See restore logs.',
      );
      state = const KeyManagementState(phase: KeyPhase.blockedByMismatch);
      return;
    }

    state = const KeyManagementState(phase: KeyPhase.regenerating);

    try {
      final keyService = await ref.read(keyServiceProvider.future);
      final regenerated = await keyService.regeneratePqKeysFromMasterSeed();
      // Invalidate so downstream consumers (main_shell publish-on-boot, sender
      // path) see the new pqPub from secure storage. This is the legitimate
      // home for that invalidation — it stays inside the notifier where it
      // belongs, not at the UI layer.
      ref.invalidate(keysProvider);

      // Load the fresh bundle to obtain the X25519 public keys. Using the
      // just-regenerated pqPub directly avoids the stale-keysProvider race
      // documented in the original redeem code.
      final keys = await keyService.loadKeys();
      if (keys == null) {
        throw StateError('keys missing after regeneration');
      }

      state = const KeyManagementState(phase: KeyPhase.publishing);

      final encPub = await keys.encryptionKeyPair.extractPublicKey();
      final scanPub = await keys.scanKeyPair.extractPublicKey();
      final chain = await ref.read(sealedChainClientProvider.future);
      await chain.publishKeysIfStale(
        encryptionPubkey: Uint8List.fromList(encPub.bytes),
        scanPubkey: Uint8List.fromList(scanPub.bytes),
        pqPubkey: regenerated.publicKey,
      );

      state = const KeyManagementState(phase: KeyPhase.done);
    } catch (e, st) {
      debugPrint('[KeyManagement] regenerateAndPublish failed: $e\n$st');
      state = KeyManagementState(
        phase: KeyPhase.error,
        lastError: e.toString(),
      );
    }
  }

  /// Boot-time idempotent publish.
  ///
  /// Does NOT regenerate PQ keys — only publishes the existing local bundle
  /// when the on-chain copy is stale or missing. No-op (transitions to done)
  /// when:
  ///   - the blocked flag is set,
  ///   - keys haven't been derived yet,
  ///   - the wallet has no credits (publishKeys costs 1 credit),
  ///   - publishKeysIfStale is already idempotent.
  Future<void> ensurePublished() async {
    final prefs = await getPrefs();
    if (prefs.getBool(pqPublishBlockedFlagKey) == true) {
      debugPrint(
        '[KeyManagement] ensurePublished BLOCKED — pq mismatch flag set. '
        'See restore logs.',
      );
      state = const KeyManagementState(phase: KeyPhase.blockedByMismatch);
      return;
    }

    state = const KeyManagementState(phase: KeyPhase.publishing);

    try {
      final keys = await ref.read(keysProvider.future);
      if (keys == null) {
        state = const KeyManagementState(phase: KeyPhase.done);
        return;
      }
      final pqPub = keys.pqPublicKey;
      final chain = await ref.read(sealedChainClientProvider.future);
      final walletAddress = chain.wallet.walletAddress;
      if (walletAddress == null) {
        state = const KeyManagementState(phase: KeyPhase.done);
        return;
      }
      // publishKeys costs 1 credit — skip when the user has none.
      final credits = await chain.getCredits(walletAddress);
      if (credits < 1) {
        state = const KeyManagementState(phase: KeyPhase.done);
        return;
      }

      final encPub = await keys.encryptionKeyPair.extractPublicKey();
      final scanPub = await keys.scanKeyPair.extractPublicKey();
      await chain.publishKeysIfStale(
        encryptionPubkey: Uint8List.fromList(encPub.bytes),
        scanPubkey: Uint8List.fromList(scanPub.bytes),
        pqPubkey: pqPub,
      );

      state = const KeyManagementState(phase: KeyPhase.done);
    } catch (e, st) {
      debugPrint('[KeyManagement] ensurePublished failed: $e\n$st');
      state = KeyManagementState(
        phase: KeyPhase.error,
        lastError: e.toString(),
      );
    }
  }
}

final keyManagementProvider =
    NotifierProvider<KeyManagementNotifier, KeyManagementState>(
      KeyManagementNotifier.new,
    );

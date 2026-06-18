import 'dart:async';

import 'package:crypto/crypto.dart' as pkg_crypto;
import 'package:sealed_app/core/log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key set when restore detects an on-chain PQ pubkey hash
/// that does NOT match the locally re-derived PQ pubkey hash. When set, all
/// publish paths (boot, redeem) MUST refuse to call publishKeys until the
/// flag is cleared (manual debug action) — otherwise we would silently
/// rotate the on-chain key and permanently break decryption of any messages
/// still in flight that were encrypted to the previous key.
const String pqPublishBlockedFlagKey = 'pq_publish_blocked_mismatch';

// ============================================================================
// WALLET STATE
// ============================================================================

enum OnboardingPhase {
  /// No wallet exists, need to create or restore
  noWallet,

  /// Wallet exists but needs funding
  needsFunding,

  /// Wallet is ready to use
  ready,

  /// Currently creating a new wallet
  creating,

  /// Currently restoring from seed
  restoring,

  /// Error occurred
  error,
}

class WalletState {
  final OnboardingPhase phase;
  final String? walletAddress;
  final double? balanceSol;
  final String? seedPhrase; // Only set during creation, user must back up
  final String? error;

  const WalletState({
    this.phase = OnboardingPhase.noWallet,
    this.walletAddress,
    this.balanceSol,
    this.seedPhrase,
    this.error,
  });

  bool get hasWallet =>
      phase == OnboardingPhase.ready || phase == OnboardingPhase.needsFunding;
  bool get isReady => phase == OnboardingPhase.ready;

  WalletState copyWith({
    OnboardingPhase? phase,
    String? walletAddress,
    double? balanceSol,
    String? seedPhrase,
    String? error,
  }) {
    return WalletState(
      phase: phase ?? this.phase,
      walletAddress: walletAddress ?? this.walletAddress,
      balanceSol: balanceSol ?? this.balanceSol,
      seedPhrase: seedPhrase,
      error: error,
    );
  }

  @override
  String toString() =>
      'WalletState(phase: $phase, address: $walletAddress, balance: $balanceSol ALGO)';
}

// ============================================================================
// WALLET NOTIFIER
// ============================================================================

class WalletNotifier extends AsyncNotifier<WalletState> {
  AlgorandWallet? _algoWallet;
  // Minimum ALGO balance: 0.1 ALGO covers the Algorand account minimum reserve.
  static const double _minBalanceSol = 0.1;

  // ── helpers ────────────────────────────────────────────────────────────────

  bool get _hasWallet => _algoWallet?.hasWallet ?? false;

  String? get _walletAddress => _algoWallet?.walletAddress;

  @override
  Future<WalletState> build() async {
    _algoWallet = await ref.watch(algorandWalletProvider.future);

    if (!_hasWallet) {
      return const WalletState(phase: OnboardingPhase.noWallet);
    }
    return _checkWalletStatus();
  }

  /// Fetch wallet balance in ALGO (microALGO ÷ 1,000,000).
  ///
  /// Returns null when the balance could NOT be fetched (offline / chain
  /// unreachable) — distinct from a genuine zero balance. Callers must not
  /// treat null as "unfunded": doing so misclassified funded wallets as
  /// needsFunding on an offline launch.
  Future<double?> _getAlgoBalance() async {
    final addr = _walletAddress;
    if (addr == null) {
      Log.d('🔑 _getAlgoBalance: no wallet address set');
      return 0.0;
    }
    try {
      final chainClient = await ref.read(sealedChainClientProvider.future);
      final microAlgos = await chainClient.getWalletBalance(addr);
      Log.d('🔑 _getAlgoBalance: addr=$addr microAlgos=$microAlgos');
      return microAlgos / 1_000_000.0;
    } catch (e, st) {
      Log.d('⚠️ _getAlgoBalance failed (treating as unknown): $e');
      Log.d(st);
      return null;
    }
  }

  /// Check wallet balance and determine status
  Future<WalletState> _checkWalletStatus() async {
    try {
      final balance = await _getAlgoBalance();
      final address = _walletAddress;

      // Could not reach the chain (offline). Do NOT downgrade a possibly-funded
      // wallet to the funding screen — assume ready; an actual send will
      // surface a real shortfall, and the balance refreshes on the next
      // successful fetch.
      if (balance == null) {
        return WalletState(
          phase: OnboardingPhase.ready,
          walletAddress: address,
        );
      }

      // Minimum balance needed for sending transactions
      const minBalance = _minBalanceSol;

      if (balance < minBalance) {
        // Mainnet - show funding required screen
        return WalletState(
          phase: OnboardingPhase.needsFunding,
          walletAddress: address,
          balanceSol: balance,
        );
      }

      return WalletState(
        phase: OnboardingPhase.ready,
        walletAddress: address,
        balanceSol: balance,
      );
    } catch (e) {
      return WalletState(
        phase: OnboardingPhase.error,
        walletAddress: _walletAddress,
        error: e.toString(),
      );
    }
  }

  /// Create a new wallet
  /// Returns the seed phrase that user MUST back up
  Future<String> createWallet() async {
    state = const AsyncData(WalletState(phase: OnboardingPhase.creating));

    try {
      final algo = await ref.read(algorandWalletProvider.future);
      _algoWallet = algo;
      Log.d(
        '🔑 WalletNotifier.createWallet: '
        'pre-create wallet#${identityHashCode(algo)} '
        'hasWallet=${algo.hasWallet} '
        'address=${algo.walletAddress}',
      );
      // [create-timing] One-off diagnostic for the account-creation jank
      // (~179 dropped frames). Times the awaited wallet keypair/mnemonic gen
      // that blocks the create→backup transition. debugPrint → visible in
      // profile builds. Remove once the jank is pinned + fixed.
      final swAlgo = Stopwatch()..start();
      await algo.createWallet();
      swAlgo.stop();
      Log.d(
        '🔑 WalletNotifier.createWallet: '
        'post-create wallet#${identityHashCode(algo)} '
        'hasWallet=${algo.hasWallet} '
        'address=${algo.walletAddress}',
      );
      final seedPhrase = (await algo.getMnemonic())!;
      debugPrint(
        '[create-timing] algo.createWallet+mnemonic='
        '${swAlgo.elapsedMilliseconds}ms (awaited, blocks backup screen)',
      );

      // Derive keys in the BACKGROUND. The seed-backup screen the caller is
      // about to show does not need keys, so we return the phrase immediately
      // (instant "Create", no spinner) and let the ML-KEM keygen — which now
      // runs in an isolate (see KeyService) — finish while the user reads and
      // writes down their phrase. The onboarding "Continue" step awaits
      // [ensureKeysReady] before leaving the backup screen, by which point this
      // is virtually always already done.
      _keysReady = _finalizeNewWalletKeys();

      // A freshly created wallet's balance is zero by definition, so we skip
      // the chain balance RPC (a network round trip) that previously blocked
      // the backup screen from appearing.
      state = AsyncData(
        WalletState(
          phase: OnboardingPhase.needsFunding,
          walletAddress: _walletAddress,
          balanceSol: 0,
          seedPhrase: seedPhrase, // User must back this up!
        ),
      );
      return seedPhrase;
    } catch (e) {
      state = AsyncData(
        WalletState(phase: OnboardingPhase.error, error: e.toString()),
      );
      rethrow;
    }
  }

  /// Completes when the freshly created wallet's keys have been derived and the
  /// dependent providers refreshed. Awaited by the onboarding Continue step via
  /// [ensureKeysReady].
  Future<void>? _keysReady;

  /// Upper bound for local key derivation + secure-storage writes. These are
  /// CPU + Keystore operations with no network, so anything past this is a
  /// wedged native call (e.g. a locked/corrupt Android Keystore) rather than
  /// slowness. Turning the wedge into a [TimeoutException] keeps the onboarding
  /// spinner from spinning forever and lets the user retry.
  static const _keyDerivationTimeout = Duration(seconds: 30);

  Future<void> _finalizeNewWalletKeys() async {
    await ref
        .read(keysProvider.notifier)
        .deriveKeysFromLocalWallet()
        .timeout(_keyDerivationTimeout);
    // userProvider may have built before keys existed; refresh it plus the
    // wallet-snapshotting chain client and the chat-list providers so no stale
    // AsyncData from a prior session bleeds into the new account.
    ref.invalidate(userProvider);
    ref.invalidate(sealedChainClientProvider);
    ref.invalidate(conversationsProvider);
    ref.invalidate(conversationMessagesProvider);
    ref.invalidate(aliasPreviewsProvider);
    ref.invalidate(aliasContactMessagesProvider);
  }

  /// Ensure the background key derivation started by [createWallet] has
  /// finished. Returns immediately if no creation is in flight. Rethrows if the
  /// derivation failed so the caller can surface it instead of proceeding with
  /// a half-initialised account.
  ///
  /// On failure the cached [_keysReady] future is re-armed with a fresh
  /// derivation attempt before rethrowing. Without this, a single transient
  /// failure (secure-storage hiccup, Android Keystore wedge) would poison the
  /// cached future forever: every subsequent "Continue" tap on the seed-backup
  /// screen would re-await the same already-failed future and rethrow the same
  /// error, leaving the user permanently stuck — unable to go forward and
  /// unable to go back without discarding the freshly created wallet.
  Future<void> ensureKeysReady() async {
    try {
      await _keysReady;
    } catch (_) {
      // Re-arm so the next call retries instead of replaying the cached error.
      _keysReady = _finalizeNewWalletKeys();
      rethrow;
    }
  }

  /// Restore wallet from a recovery phrase. Accepts either a 25-word
  /// Algorand-native mnemonic (Pera/Defly) or a legacy 12/24-word BIP39
  /// phrase from older Sealed installs — `AlgorandWallet.restoreWallet`
  /// dispatches based on word count.
  ///
  /// When [wordCount] is 12 (legacy BIP39), arms the post-migration
  /// informational dialog via [MigrationNoticeService.markPending]: those
  /// users predate the new on-chain `app id` deploy and need to be told
  /// their previously-registered username is gone. The flag is consumed
  /// at next post-login frame in `main_shell.dart`.
  Future<void> restoreFromMnemonic(String mnemonic, {int? wordCount}) async {
    state = const AsyncData(WalletState(phase: OnboardingPhase.restoring));

    try {
      final algo = await ref.read(algorandWalletProvider.future);
      _algoWallet = algo;
      await algo.restoreWallet(mnemonic).timeout(_keyDerivationTimeout);

      // Derive encryption keys
      await ref
          .read(keysProvider.notifier)
          .deriveKeysFromLocalWallet()
          .timeout(_keyDerivationTimeout);

      // ── PQ KEY MISMATCH GUARD ─────────────────────────────────────────────
      // Restore should produce the SAME PQ pubkey that was previously
      // published on-chain (derivation is deterministic from mnemonic).
      // If the on-chain hash diverges from the freshly-derived hash, something
      // is wrong with key gen (or this wallet was onboarded under legacy,
      // non-deterministic key derivation). DO NOT republish — that would
      // silently rotate the key and destroy old messages. Set a publish-block
      // flag and log loudly so we can debug.
      await _verifyPqKeyMatchesOnChain();
      // ──────────────────────────────────────────────────────────────────────

      // Arm the one-shot post-migration notice for legacy 12-word users.
      // Other word counts represent post-app-id users and do not need it.
      if (wordCount == 12) {
        await ref.read(migrationNoticeServiceProvider).markPending();
      }

      // Invalidate userProvider to trigger auto-login with the restored wallet
      ref.invalidate(userProvider);
      // Same reason as createWallet: rebuild SealedChainClient with real addr.
      ref.invalidate(sealedChainClientProvider);
      // Safety net for stale chat-list cache (see createWallet).
      ref.invalidate(conversationsProvider);
      ref.invalidate(conversationMessagesProvider);
      ref.invalidate(aliasPreviewsProvider);
      ref.invalidate(aliasContactMessagesProvider);

      state = AsyncData(await _checkWalletStatus());
    } catch (e) {
      state = AsyncData(
        WalletState(
          phase: OnboardingPhase.error,
          error: 'Failed to restore wallet: $e',
        ),
      );
      rethrow;
    }
  }

  /// Compare locally-derived PQ pubkey hash against the on-chain pubkey hash
  /// for the restored wallet. On mismatch, set [pqPublishBlockedFlagKey] in
  /// shared prefs and log loudly. The publish paths (`main_shell` boot and
  /// redeem flow) MUST consult this flag and refuse to call publishKeys.
  ///
  /// No-op (and clears the flag) when:
  ///   - on-chain box does not exist (fresh wallet, nothing to compare against)
  ///   - on-chain pqPubkeyHash is null/zero (legacy state)
  ///   - hashes match (happy path)
  Future<void> _verifyPqKeyMatchesOnChain() async {
    try {
      final keys = await ref.read(keysProvider.future);
      final localPqPub = keys?.pqPublicKey;
      if (localPqPub == null) {
        debugPrint(
          '🚨 [PQ-VERIFY] No local PQ pubkey after derive — skip check',
        );
        return;
      }
      final chain = await ref.read(sealedChainClientProvider.future);
      final walletAddress = chain.wallet.walletAddress;
      if (walletAddress == null) {
        debugPrint('🚨 [PQ-VERIFY] No wallet address — skip check');
        return;
      }

      final profile = await chain.getUserByWallet(walletAddress);
      final onChainHash = profile?.pqPubkeyHash;

      final prefs = await SharedPreferences.getInstance();

      if (onChainHash == null) {
        // Fresh wallet or pre-publish — nothing to compare. Ensure flag clear.
        await prefs.remove(pqPublishBlockedFlagKey);
        debugPrint(
          '🟢 [PQ-VERIFY] No on-chain pqPubkeyHash for $walletAddress — '
          'fresh wallet, publish allowed.',
        );
        return;
      }

      final localHash = Uint8List.fromList(
        pkg_crypto.sha256.convert(localPqPub).bytes,
      );

      final match = _constantTimeEquals(localHash, onChainHash);
      if (match) {
        await prefs.remove(pqPublishBlockedFlagKey);
        debugPrint(
          '🟢 [PQ-VERIFY] Local PQ pubkey matches on-chain hash '
          'fp=${_fp(onChainHash)} — restore OK.',
        );
        return;
      }

      // MISMATCH — block publish and shout.
      await prefs.setBool(pqPublishBlockedFlagKey, true);
      debugPrint('');
      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      debugPrint('🚨🚨🚨 [PQ-VERIFY] PQ PUBKEY MISMATCH ON RESTORE 🚨🚨🚨');
      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      debugPrint('  wallet:        $walletAddress');
      debugPrint('  onChainFp:     ${_fp(onChainHash)}');
      debugPrint('  localFp:       ${_fp(localHash)}');
      debugPrint('  localPubFp:    ${_fp(localPqPub)}');
      debugPrint('  pubKeyLen:     ${localPqPub.length}');
      debugPrint('');
      debugPrint('  The locally-derived PQ pubkey does NOT match the key');
      debugPrint('  published on-chain for this wallet. This means either:');
      debugPrint('   (a) PQ derivation is not deterministic — INVESTIGATE');
      debugPrint('   (b) Wallet was onboarded with legacy non-deterministic');
      debugPrint('       key gen and old key is unrecoverable.');
      debugPrint('');
      debugPrint('  publishKeys is now BLOCKED for this session via');
      debugPrint('  SharedPreferences flag "$pqPublishBlockedFlagKey".');
      debugPrint('  Clear flag manually after investigation to resume.');
      debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      debugPrint('');
    } catch (e, st) {
      // Don't block restore on a verification failure (e.g. chain RPC down).
      // Just log — publish gating will simply be unarmed for this session.
      debugPrint('🚨 [PQ-VERIFY] verification threw, skipping: $e\n$st');
    }
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  String _fp(List<int> bytes) {
    final n = bytes.length < 8 ? bytes.length : 8;
    final slice = bytes.sublist(0, n);
    // base64-style short fingerprint (matches existing log style).
    return slice.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Refresh balance
  Future<void> refreshBalance() async {
    if (!_hasWallet) return;

    try {
      final balance = await _getAlgoBalance();
      // Transient fetch failure — keep the last-known balance/phase rather than
      // flipping a funded wallet to needsFunding.
      if (balance == null) return;
      final current = state.value ?? const WalletState();

      state = AsyncData(
        current.copyWith(
          balanceSol: balance,
          phase: balance >= _minBalanceSol
              ? OnboardingPhase.ready
              : OnboardingPhase.needsFunding,
        ),
      );
    } catch (e) {
      // Ignore balance fetch errors
      Log.d('🔑 WalletNotifier: Failed to refresh balance: $e');
    }
  }

  /// Request airdrop (devnet only) - Not implemented for Algorand
  Future<void> requestAirdrop() async {
    throw UnsupportedError('Airdrop not available for Algorand TestNet');
  }

  /// Delete wallet and all data
  Future<void> deleteWallet() async {
    await _algoWallet?.deleteWallet();
    state = const AsyncData(WalletState(phase: OnboardingPhase.noWallet));
  }

  /// Set state to noWallet (used by logout service after all data is cleared)
  void setNoWalletState() {
    state = const AsyncData(WalletState(phase: OnboardingPhase.noWallet));
  }

  /// Get seed phrase for backup before logout
  Future<String?> getSeedPhraseForBackup() async {
    return _algoWallet?.getMnemonic();
  }

  /// Get wallet type (always 'mnemonic' for Algorand)
  String getWalletType() => 'mnemonic';

  /// Clear the stored seed phrase from state (after user confirms backup)
  void clearSeedPhraseFromState() {
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(seedPhrase: null));
    }
  }
}

// ============================================================================
// PROVIDERS
// ============================================================================

/// Main wallet provider
final walletProvider = AsyncNotifierProvider<WalletNotifier, WalletState>(
  WalletNotifier.new,
);

/// Convenience: check if wallet is ready
final isWalletReadyProvider = Provider<bool>((ref) {
  final walletState = ref.watch(walletProvider);
  return walletState.value?.isReady ?? false;
});

/// Convenience: get wallet address
final walletAddressProvider = Provider<String?>((ref) {
  final walletState = ref.watch(walletProvider);
  return walletState.value?.walletAddress;
});

/// Convenience: get wallet balance
final walletBalanceProvider = Provider<double?>((ref) {
  final walletState = ref.watch(walletProvider);
  return walletState.value?.balanceSol;
});

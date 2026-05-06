import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/chain/algorand_wallet_client.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';

// ============================================================================
// LOCAL WALLET STATE
// ============================================================================

enum WalletSetupPhase {
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

class LocalWalletState {
  final WalletSetupPhase phase;
  final String? walletAddress;
  final double? balanceSol;
  final String? seedPhrase; // Only set during creation, user must back up
  final String? error;

  const LocalWalletState({
    this.phase = WalletSetupPhase.noWallet,
    this.walletAddress,
    this.balanceSol,
    this.seedPhrase,
    this.error,
  });

  bool get hasWallet =>
      phase == WalletSetupPhase.ready || phase == WalletSetupPhase.needsFunding;
  bool get isReady => phase == WalletSetupPhase.ready;

  LocalWalletState copyWith({
    WalletSetupPhase? phase,
    String? walletAddress,
    double? balanceSol,
    String? seedPhrase,
    String? error,
  }) {
    return LocalWalletState(
      phase: phase ?? this.phase,
      walletAddress: walletAddress ?? this.walletAddress,
      balanceSol: balanceSol ?? this.balanceSol,
      seedPhrase: seedPhrase,
      error: error,
    );
  }

  @override
  String toString() =>
      'LocalWalletState(phase: $phase, address: $walletAddress, balance: $balanceSol ALGO)';
}

// ============================================================================
// LOCAL WALLET NOTIFIER
// ============================================================================

class LocalWalletNotifier extends AsyncNotifier<LocalWalletState> {
  AlgorandWallet? _algoWallet;
  // Minimum ALGO balance: 0.1 ALGO covers the Algorand account minimum reserve.
  static const double _minBalanceSol = 0.1;

  // ── helpers ────────────────────────────────────────────────────────────────

  bool get _hasWallet => _algoWallet?.hasWallet ?? false;

  String? get _walletAddress => _algoWallet?.walletAddress;

  @override
  Future<LocalWalletState> build() async {
    _algoWallet = await ref.watch(algorandWalletProvider.future);

    if (!_hasWallet) {
      return const LocalWalletState(phase: WalletSetupPhase.noWallet);
    }
    return _checkWalletStatus();
  }

  /// Fetch wallet balance in ALGO (microALGO ÷ 1,000,000).
  Future<double> _getAlgoBalance() async {
    try {
      final addr = _walletAddress;
      if (addr == null) {
        print('🔑 _getAlgoBalance: no wallet address set');
        return 0.0;
      }
      final chainClient = await ref.read(chainClientProvider.future);
      final microAlgos = await chainClient.getWalletBalance(addr);
      print('🔑 _getAlgoBalance: addr=$addr microAlgos=$microAlgos');
      return microAlgos / 1_000_000.0;
    } catch (e, st) {
      print('⚠️ _getAlgoBalance failed: $e');
      print(st);
      return 0.0;
    }
  }

  /// Check wallet balance and determine status
  Future<LocalWalletState> _checkWalletStatus() async {
    try {
      final balance = await _getAlgoBalance();
      final address = _walletAddress;

      // Minimum balance needed for sending transactions
      const minBalance = _minBalanceSol;

      if (balance < minBalance) {
        // Mainnet - show funding required screen
        return LocalWalletState(
          phase: WalletSetupPhase.needsFunding,
          walletAddress: address,
          balanceSol: balance,
        );
      }

      return LocalWalletState(
        phase: WalletSetupPhase.ready,
        walletAddress: address,
        balanceSol: balance,
      );
    } catch (e) {
      return LocalWalletState(
        phase: WalletSetupPhase.error,
        walletAddress: _walletAddress,
        error: e.toString(),
      );
    }
  }

  /// Create a new wallet
  /// Returns the seed phrase that user MUST back up
  Future<String> createWallet() async {
    state = const AsyncData(LocalWalletState(phase: WalletSetupPhase.creating));

    try {
      final algo = await ref.read(algorandWalletProvider.future);
      _algoWallet = algo;
      print(
        '🔑 LocalWalletNotifier.createWallet: '
        'pre-create wallet#${identityHashCode(algo)} '
        'hasWallet=${algo.hasWallet} '
        'address=${algo.walletAddress}',
      );
      await algo.createWallet();
      print(
        '🔑 LocalWalletNotifier.createWallet: '
        'post-create wallet#${identityHashCode(algo)} '
        'hasWallet=${algo.hasWallet} '
        'address=${algo.walletAddress}',
      );
      final seedPhrase = (await algo.getMnemonic())!;

      // Derive encryption keys from the new wallet
      await ref.read(keysProvider.notifier).deriveKeysFromLocalWallet();

      // Invalidate userProvider in case user is re-creating with same seed
      ref.invalidate(userProvider);

      final balance = await _getAlgoBalance();
      if (balance < _minBalanceSol) {
        state = AsyncData(
          LocalWalletState(
            phase: WalletSetupPhase.needsFunding,
            walletAddress: _walletAddress,
            balanceSol: balance,
            seedPhrase: seedPhrase, // User must back this up!
          ),
        );
        return seedPhrase;
      }

      state = AsyncData(
        LocalWalletState(
          phase: WalletSetupPhase.ready,
          walletAddress: _walletAddress,
          balanceSol: balance,
          seedPhrase: seedPhrase, // User must back this up!
        ),
      );

      return seedPhrase;
    } catch (e) {
      state = AsyncData(
        LocalWalletState(phase: WalletSetupPhase.error, error: e.toString()),
      );
      rethrow;
    }
  }

  /// Restore wallet from a recovery phrase. Accepts either a 25-word
  /// Algorand-native mnemonic (Pera/Defly) or a legacy 12/24-word BIP39
  /// phrase from older Sealed installs — `AlgorandWallet.restoreWallet`
  /// dispatches based on word count.
  Future<void> restoreFromMnemonic(String mnemonic) async {
    state = const AsyncData(
      LocalWalletState(phase: WalletSetupPhase.restoring),
    );

    try {
      final algo = await ref.read(algorandWalletProvider.future);
      _algoWallet = algo;
      await algo.restoreWallet(mnemonic);

      // Derive encryption keys
      await ref.read(keysProvider.notifier).deriveKeysFromLocalWallet();

      // Invalidate userProvider to trigger auto-login with the restored wallet
      ref.invalidate(userProvider);

      state = AsyncData(await _checkWalletStatus());
    } catch (e) {
      state = AsyncData(
        LocalWalletState(
          phase: WalletSetupPhase.error,
          error: 'Failed to restore wallet: $e',
        ),
      );
      rethrow;
    }
  }

  /// Refresh balance
  Future<void> refreshBalance() async {
    if (!_hasWallet) return;

    try {
      final balance = await _getAlgoBalance();
      final current = state.value ?? const LocalWalletState();

      state = AsyncData(
        current.copyWith(
          balanceSol: balance,
          phase: balance >= _minBalanceSol
              ? WalletSetupPhase.ready
              : WalletSetupPhase.needsFunding,
        ),
      );
    } catch (e) {
      // Ignore balance fetch errors
      print('🔑 LocalWalletNotifier: Failed to refresh balance: $e');
    }
  }

  /// Request airdrop (devnet only) - Not implemented for Algorand
  Future<void> requestAirdrop() async {
    throw UnsupportedError('Airdrop not available for Algorand TestNet');
  }

  /// Delete wallet and all data
  Future<void> deleteWallet() async {
    await _algoWallet?.deleteWallet();
    state = const AsyncData(LocalWalletState(phase: WalletSetupPhase.noWallet));
  }

  /// Set state to noWallet (used by logout service after all data is cleared)
  void setNoWalletState() {
    state = const AsyncData(LocalWalletState(phase: WalletSetupPhase.noWallet));
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

/// Main local wallet provider
final localWalletProvider =
    AsyncNotifierProvider<LocalWalletNotifier, LocalWalletState>(
      LocalWalletNotifier.new,
    );

/// Convenience: check if wallet is ready
final isWalletReadyProvider = Provider<bool>((ref) {
  final walletState = ref.watch(localWalletProvider);
  return walletState.value?.isReady ?? false;
});

/// Convenience: get wallet address
final walletAddressProvider = Provider<String?>((ref) {
  final walletState = ref.watch(localWalletProvider);
  return walletState.value?.walletAddress;
});

/// Convenience: get wallet balance
final walletBalanceProvider = Provider<double?>((ref) {
  final walletState = ref.watch(localWalletProvider);
  return walletState.value?.balanceSol;
});

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/models/sealed_keys.dart';
import 'package:sealed_app/services/key_service.dart';

// ============================================================================
// KEYS STATE
// ============================================================================

/// Manages cryptographic keys state using modern AsyncNotifier pattern.
/// Keys are now derived from the local wallet seed (no external wallet needed).
class KeysNotifier extends AsyncNotifier<SealedKeys?> {
  late KeyService _keyService;

  @override
  Future<SealedKeys?> build() async {
    // Wait for dependencies
    _keyService = await ref.watch(keyServiceProvider.future);

    // Try to load existing keys
    return _keyService.loadKeys();
  }

  /// Derive new keys from local wallet seed (NEW - no external wallet!)
  Future<void> deriveKeysFromLocalWallet() async {
    state = const AsyncLoading();

    state = await AsyncValue.guard(() async {
      // Check if the Algorand wallet is active and ready
      final wallet = await ref.watch(algorandWalletProvider.future);
      print(
        '🔑 KeysNotifier.deriveKeysFromLocalWallet: '
        'wallet#${identityHashCode(wallet)} '
        'hasWallet=${wallet.hasWallet} '
        'address=${wallet.walletAddress}',
      );
      final hasActiveWallet = wallet.hasWallet;

      if (!hasActiveWallet) {
        throw Exception('Local wallet not created');
      }

      print('🔑 KeysNotifier: Deriving keys from local wallet seed...');

      final keys = await _keyService.deriveKeysFromLocalWallet();
      print('🔑 KeysNotifier: ✅ Keys derived successfully');

      // Keys are deterministically derived from the wallet seed via HKDF.
      // With memo-based accounts, there is no on-chain PDA profile to verify
      // against — the keys will be published when the user sets their username.

      state = AsyncValue.data(keys);
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

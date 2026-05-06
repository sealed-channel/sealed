import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sealed_app/chain/algorand_wallet_client.dart';
import 'package:sealed_app/local/alias_chat_cache.dart';
import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/local/message_cache.dart';
import 'package:sealed_app/local/sync_state.dart';
import 'package:sealed_app/local/user_cache.dart';

import 'package:sealed_app/services/alias_key_service.dart';
import 'package:sealed_app/services/app_settings_service.dart';
import 'package:sealed_app/services/crypto_service.dart';
import 'package:sealed_app/services/key_service.dart';

import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// SERVICE LOCATOR - Synchronous, Singleton Services
// ============================================================================
// These are simple providers for services that don't have async initialization
// or complex dependencies. They can be accessed synchronously anywhere.

// ----------------------------------------------------------------------------
// Storage
// ----------------------------------------------------------------------------

final flutterSecureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage();
});

// ----------------------------------------------------------------------------
// Database
// ----------------------------------------------------------------------------

final localDatabaseProvider = Provider<LocalDatabase>((ref) {
  return LocalDatabase();
});

final messageCacheProvider = Provider<MessageCache>((ref) {
  return MessageCache(localDatabase: ref.watch(localDatabaseProvider));
});

final userCacheProvider = Provider<UserCache>((ref) {
  return UserCache(ref.watch(localDatabaseProvider));
});

final syncStateProvider = Provider<SyncState>((ref) {
  return SyncState(ref.watch(localDatabaseProvider));
});

// ----------------------------------------------------------------------------
// Alias Chat
// ----------------------------------------------------------------------------

final aliasChatCacheProvider = Provider<AliasChatCache>((ref) {
  return AliasChatCache(localDatabase: ref.watch(localDatabaseProvider));
});

final aliasKeyServiceProvider = Provider<AliasKeyService>((ref) {
  return AliasKeyService(
    storage: ref.watch(flutterSecureStorageProvider),
    x25519: ref.watch(x25519Provider),
  );
});

// ----------------------------------------------------------------------------
// Cryptography Primitives
// ----------------------------------------------------------------------------

final x25519Provider = Provider<X25519>((ref) => X25519());

final hkdfProvider = Provider<Hkdf>((ref) {
  return Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
});

final hmacProvider = Provider<Hmac>((ref) => Hmac(Sha256()));

final aesGcmProvider = Provider<AesGcm>((ref) => AesGcm.with256bits());

// ----------------------------------------------------------------------------
// Crypto Service (sync - all deps are sync)
// ----------------------------------------------------------------------------

final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService(
    x25519: ref.watch(x25519Provider),
    hkdf: ref.watch(hkdfProvider),
    aesGcm: ref.watch(aesGcmProvider),
    hmac: ref.watch(hmacProvider),
  );
});

// ----------------------------------------------------------------------------
// ============================================================================
// ASYNC SERVICES - Require async initialization
// ============================================================================

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

// ----------------------------------------------------------------------------
// App Settings Service
// ----------------------------------------------------------------------------

final appSettingsServiceProvider = FutureProvider<AppSettingsService>((
  ref,
) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  return AppSettingsService(prefs: prefs);
});

// ----------------------------------------------------------------------------
// Algorand Wallet (loads existing wallet from secure storage on init)
// ----------------------------------------------------------------------------

final algorandWalletProvider = FutureProvider<AlgorandWallet>((ref) async {
  final storage = ref.watch(flutterSecureStorageProvider);
  final wallet = AlgorandWallet(storage);
  await wallet.loadExistingWallet();
  return wallet;
});

// ----------------------------------------------------------------------------
// Key Service (Algorand-only after Solana deprecation)
// ----------------------------------------------------------------------------

final keyServiceProvider = FutureProvider<KeyService>((ref) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  final chainWallet = await ref.watch(algorandWalletProvider.future);

  return KeyService(
    storage: ref.watch(flutterSecureStorageProvider),
    prefs: prefs,
    x25519: ref.watch(x25519Provider),
    hkdf: ref.watch(hkdfProvider),
    chainWallet: chainWallet,
  );
});

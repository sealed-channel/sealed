import 'package:cryptography/cryptography.dart';
// Pure-Dart HKDF/HMAC. The native cryptography_flutter delegate rejects an
// empty HMAC key (SecretKeySpec "Empty key"), and our salt-less HKDF extract
// step passes exactly that. Pure-Dart follows RFC 5869 (empty salt → zeros),
// producing identical output without crashing. Keyless hashing stays native.
import 'package:cryptography/dart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sealed_app/features/wallet/algorand_wallet_client.dart';
import 'package:sealed_app/infra/local/database.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart';
import 'package:sealed_app/infra/local/repositories/local_user_repository.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/infra/local/repositories/sync_repository.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/indexer_provider.dart';

import 'package:sealed_app/features/messaging/alias/alias_key_service.dart';
import 'package:sealed_app/features/settings/app_settings_service.dart';
import 'package:sealed_app/infra/crypto/crypto_service.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/identity/migration_notice_service.dart';

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

/// One-shot post-migration informational notice (legacy 12-word restore).
/// See [MigrationNoticeService] for storage-key contract.
final migrationNoticeServiceProvider = Provider<MigrationNoticeService>((ref) {
  return MigrationNoticeService(
    storage: ref.watch(flutterSecureStorageProvider),
  );
});

// ----------------------------------------------------------------------------
// Database
// ----------------------------------------------------------------------------

final localDatabaseProvider = Provider<LocalDatabase>((ref) {
  return LocalDatabase();
});

final syncStateProvider = Provider<SyncRepository>((ref) {
  return SyncRepository(ref.watch(localDatabaseProvider));
});

final localUserRepositoryProvider = Provider<LocalUserRepository>((ref) {
  return LocalUserRepositoryImpl(ref.watch(localDatabaseProvider));
});

final contactRepositoryProvider = Provider<ContactRepository>((ref) {
  return ContactRepositoryImpl(
    ref.watch(localDatabaseProvider),
    indexer: ref.watch(indexerClientProvider),
    chainResolver: () => ref.read(sealedChainClientProvider.future),
  );
});

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepositoryImpl(localDatabase: ref.watch(localDatabaseProvider));
});

// ----------------------------------------------------------------------------
// Alias Chat
// ----------------------------------------------------------------------------

final aliasKeyServiceProvider = Provider<AliasKeyService>((ref) {
  return AliasKeyService(
    storage: ref.watch(flutterSecureStorageProvider),
    x25519: ref.watch(x25519Provider),
    contactRepository: ref.watch(contactRepositoryProvider),
  );
});

// ----------------------------------------------------------------------------
// Cryptography Primitives
// ----------------------------------------------------------------------------

final x25519Provider = Provider<X25519>((ref) => X25519());

final hkdfProvider = Provider<Hkdf>((ref) {
  return DartHkdf(hmac: DartHmac.sha256(), outputLength: 32);
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

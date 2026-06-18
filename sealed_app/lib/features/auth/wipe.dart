/// Logout + device wipe.
///
/// Consolidates two previously-separate files:
///
///   - [performLogout] — global logout function that clears all user data
///     and state. Takes a [ProviderContainer] instead of [WidgetRef] so it
///     survives widget disposal (e.g. dialog dismiss / navigation pop).
///
///   - [WipeService] — the panic switch. Reuses the destructive ordering
///     from [performLogout] and additionally wipes
///     flutter_secure_storage, deletes the encrypted DB file from disk,
///     and clears SharedPreferences.
library;

import 'dart:io';
import 'package:sealed_app/core/log.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/infra/local/database.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/indexer_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/search_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/features/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Global logout function that clears all user data and state.
///
/// Takes a [ProviderContainer] instead of [WidgetRef] so it survives
/// widget disposal (e.g. dialog dismiss / navigation pop).
///
/// Order (destructive-first to prevent races with concurrent wallet creation):
/// 1. Do all destructive work — clear caches, keys, user, delete wallet.
/// 2. Flip wallet state to noWallet.
/// 3. Invalidate providers so they rebuild clean on next access.
///
/// Previously step 1 was "set noWallet first", which let the UI navigate
/// to the wallet-setup screen while async destructive work (push unregister
/// over Tor, secure-storage deletes) was still running. A user tapping
/// "Create wallet" during that window would have their freshly-created
/// wallet wiped by the in-flight `deleteWallet()` and the subsequent
/// provider invalidation, causing "Local wallet not created" on the
/// auto-login that follows.
Future<void> performLogout(ProviderContainer container) async {
  Log.d('🚪 performLogout: Starting logout...');

  // ── Step 1: Unregister push tokens (non-critical) ────────────────────────
  try {
    // Unregister Push Notifications token from indexer (Phase B: only push path).
    final indexerService = await container.read(indexerServiceProvider.future);
    await indexerService.unregisterTargetedPush();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to unregister push token from indexer: $e');
  }

  // ── Step 1b: Unregister every per-alias push row + clear per-alias flags.
  //
  // CRITICAL ordering: this MUST run BEFORE
  // `aliasKeyService.deleteAllChannels()` below — the scan_priv bytes needed
  // to derive each alias row's blinded_id live in the same flutter_secure_storage
  // keys (`alias_*_tmp_scan_priv` / contact rows) that `deleteAllChannels` and
  // the SQLCipher DB delete are about to wipe. Once wiped we cannot
  // re-derive the blinded_id and the alias rows leak on the indexer until
  // the next install of this device.
  //
  // Best-effort: never throw out of performLogout because the indexer is
  // unreachable.
  try {
    final indexerService = await container.read(indexerServiceProvider.future);
    await indexerService.unregisterAllAliasViewKeys();
  } catch (e) {
    Log.d('⚠️ performLogout: unregisterAllAliasViewKeys failed: $e');
  }

  try {
    final settings = await container.read(appSettingsServiceProvider.future);
    await settings.clearAllAliasPushFlags();
  } catch (e) {
    Log.d('⚠️ performLogout: clearAllAliasPushFlags failed: $e');
  }

  try {
    // Delete local FCM token (legacy - no-op post Task 2.5)
    await NotificationService().deleteToken();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to delete FCM token: $e');
  }

  // ── Step 2: Clear all persisted data ──────────────────────────────
  // Each step is wrapped so one failure doesn't block the rest.

  try {
    Log.d('🚪 performLogout: Clearing root cache...');
    await container.read(indexerClientProvider).clearRootCache();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to clear root cache: $e');
  }

  try {
    Log.d('🚪 performLogout: Clearing message cache...');
    await container.read(messageRepositoryProvider).clear();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to clear message cache: $e');
  }

  try {
    Log.d('🚪 performLogout: Clearing contact cache...');
    await container.read(contactRepositoryProvider).clear();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to clear contact cache: $e');
  }

  try {
    Log.d('🚪 performLogout: Clearing alias keys...');
    await container.read(aliasKeyServiceProvider).deleteAllChannels();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to clear alias keys: $e');
  }

  try {
    Log.d('🚪 performLogout: Resetting sync state...');
    await container.read(syncStateProvider).reset();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to reset sync state: $e');
  }

  try {
    Log.d('🚪 performLogout: Clearing keys...');
    await container.read(keysProvider.notifier).clearKeys();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to clear keys: $e');
  }

  try {
    Log.d('🚪 performLogout: Logging out user...');
    await container.read(userProvider.notifier).logout();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to logout user: $e');
  }

  try {
    Log.d('🚪 performLogout: Deleting wallet...');
    final algoWallet = await container.read(algorandWalletProvider.future);
    await algoWallet.deleteWallet();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to delete wallet: $e');
  }

  // Close & delete the SQLCipher DB file BEFORE we wipe the DEK that
  // encrypts it. After clearPinAndDekState() the next session bootstraps a
  // fresh DEK, and a leftover DB file encrypted with the old key would
  // mount but reject writes ("attempt to write a readonly database").
  try {
    Log.d('🚪 performLogout: Closing & deleting encrypted DB file...');
    await LocalDatabase.closeAndDelete();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to delete DB file: $e');
  }

  // Clear PIN/DEK/termination secure-storage so a follow-up account
  // creation gets a fresh PIN setup prompt. Without this, the previous
  // user's PIN salt + DEK wraps survive logout, PinService.isPinSet()
  // keeps returning true, and PinSetupScreen never fires for the new
  // account.
  try {
    Log.d('🚪 performLogout: Clearing PIN / DEK secure-storage...');
    await container.read(dekManagerProvider).clearPinAndDekState();
    container.read(pinSessionProvider.notifier).reset();
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to clear PIN/DEK state: $e');
  }

  // ── Step 3: Now that everything is gone, flip wallet state ───────
  // Doing this AFTER the destructive work prevents the UI from
  // navigating to the wallet-setup screen and letting the user
  // create a new wallet while the destructive work is still running.
  try {
    container.read(walletProvider.notifier).setNoWalletState();
    Log.d('🚪 performLogout: Set wallet state to noWallet');
  } catch (e) {
    Log.d('⚠️ performLogout: Failed to set noWallet state: $e');
  }

  // ── Step 4: Invalidate providers for clean rebuilds ───────────────
  // Data is already gone, so rebuilds will see empty state.
  Log.d('🚪 performLogout: Invalidating providers...');
  container.invalidate(algorandWalletProvider);
  container.invalidate(sealedChainClientProvider);
  container.invalidate(messagesNotifierProvider);
  container.invalidate(messageServiceProvider);
  container.invalidate(keysProvider);
  container.invalidate(userProvider);
  container.invalidate(walletProvider);
  container.invalidate(searchServiceProvider);
  // Chat-list / message preview providers cache AsyncData independently of
  // the DB file. Without these invalidations the prior account's
  // ChatPreview rows survive logout and render ghost chats on the new
  // account until the providers happen to rebuild. Opening a ghost shows
  // zero messages because the underlying DB is gone.
  container.invalidate(conversationsProvider);
  container.invalidate(conversationMessagesProvider);
  container.invalidate(aliasPreviewsProvider);
  container.invalidate(aliasContactMessagesProvider);
  // The chat list actually watches the MERGED surface (chatPreviewsProvider)
  // and the invitations banner watches pendingInvitesProvider. Both cache
  // ChatPreview/invite rows from the prior account; without invalidating them
  // the old account's previews render as ghost chats on the new account and
  // open blank because the underlying DB was deleted above.
  container.invalidate(chatPreviewsProvider);
  container.invalidate(pendingInvitesProvider);
  container.invalidate(contactRepositoryProvider);
  container.read(messageRefreshCounterProvider.notifier).state = 0;

  Log.d('🚪 performLogout: Logout complete!');
}

/// WipeService — the panic switch.
///
/// Reuses the existing destructive ordering from [performLogout] (caches →
/// alias keys → user → wallet) and additionally:
///   - flutterSecureStorage.deleteAll() — wipes wallet seed, all DEK wraps,
///     PIN salts, biometric KEK, termination marker.
///   - Deletes the encrypted DB file from disk.
///   - Clears SharedPreferences.
///
/// Two entry points:
///   - [WipeService.wipeAll] — for the Settings "Erase this device" button.
///   - [WipeService.silentWipe] — for the duress branch in LockScreen, which
///     must never throw and must complete even if intermediate steps fail.
class WipeService {
  final ProviderContainer _container;
  final FlutterSecureStorage _storage;

  WipeService(this._container, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Full wipe — for "Erase this device" or termination code.
  /// Best-effort: each step is wrapped so one failure does not block the rest.
  ///
  /// DURESS ORDERING: local secret material is destroyed FIRST, before any
  /// network I/O. Under coercion the network may be slow or blackholed; if we
  /// ran the push/alias unregister first (as a plain logout does) the seed,
  /// DEK and decryption keys would survive in secure storage for the entire
  /// network-timeout window while the screen claims to be wiping.
  Future<void> wipeAll() async {
    Log.d('💣 WipeService: starting full wipe...');

    // Step 1 (DURESS-CRITICAL): irreversibly destroy local secrets up front.
    await _destroyLocalSecrets();

    // Step 2: best-effort logout cleanup — push/alias unregister over OHTTP
    // plus cache + provider reset. Runs AFTER secrets are gone and is
    // time-bounded so a hung network cannot stall the duress flow. The alias
    // unregister may now fail because its scan keys were just wiped; leaking
    // blinded indexer push rows is the accepted trade-off for destroying the
    // local secrets first.
    try {
      await performLogout(_container).timeout(const Duration(seconds: 3));
    } catch (e) {
      Log.d('⚠️ WipeService: post-wipe cleanup failed/timed out: $e');
    }

    // Step 3: clear SharedPreferences (sync-layer pref, push opt-in, etc.).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (e) {
      Log.d('⚠️ WipeService: prefs.clear failed: $e');
    }

    Log.d('💣 WipeService: wipe complete.');
  }

  /// Destroy all local secret material: secure storage, derived DEK/PIN state,
  /// and the encrypted database file. Never throws (each step is wrapped) so
  /// the duress path always completes.
  Future<void> _destroyLocalSecrets() async {
    // flutter_secure_storage v10 puts kSecAttrAccessible into the DELETE query,
    // so a default deleteAll() can silently miss items written with
    // `first_unlock` accessibility (the chain-decryption keys read by the
    // push-prefetch background isolate). Passing `accessibility: null` omits
    // the attribute and matches items under ANY accessibility. We then run a
    // plain deleteAll() as a catch-all for anything the first pass missed.
    try {
      await _storage.deleteAll(iOptions: const IOSOptions(accessibility: null));
    } catch (e) {
      Log.d('⚠️ WipeService: accessibility-agnostic deleteAll failed: $e');
    }
    try {
      await _storage.deleteAll();
    } catch (e) {
      Log.d('⚠️ WipeService: deleteAll failed: $e');
    }

    // Clear derived DEK + PIN state so nothing can re-wrap or re-derive.
    try {
      await _container.read(dekManagerProvider).clearPinAndDekState();
    } catch (e) {
      Log.d('⚠️ WipeService: clearPinAndDekState failed: $e');
    }

    // Delete the encrypted SQLite database file (the message plaintext store).
    try {
      await _deleteDatabaseFile();
    } catch (e) {
      Log.d('⚠️ WipeService: DB file delete failed: $e');
    }
  }

  /// Same as [wipeAll], but never throws — duress safety. Used from the
  /// LockScreen so the user sees only "Incorrect PIN" regardless of state.
  Future<void> silentWipe() async {
    try {
      await wipeAll();
    } catch (_) {
      // Swallow — caller must not signal success/failure to attacker.
    }
  }

  Future<void> _deleteDatabaseFile() async {
    // sealed_messages.db lives in the sqflite default databases dir.
    final dbDir = await getDatabasesPath();
    final file = File(p.join(dbDir, 'sealed_messages.db'));
    if (await file.exists()) {
      await file.delete();
    }
    // Also clean up any stale migration scratch file.
    final scratch = File(p.join(dbDir, 'sealed_messages.enc.db'));
    if (await scratch.exists()) {
      await scratch.delete();
    }
    // And any documents-dir copy if path_provider was used.
    try {
      final docs = await getApplicationDocumentsDirectory();
      final altFile = File(p.join(docs.path, 'sealed_messages.db'));
      if (await altFile.exists()) {
        await altFile.delete();
      }
    } catch (_) {
      /* not all platforms expose docs dir */
    }
  }
}

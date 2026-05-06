import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/local_wallet_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/user_provider.dart';
import 'package:sealed_app/services/notification_service.dart';

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
  print('🚪 performLogout: Starting logout...');

  // ── Step 1: Unregister push tokens (non-critical) ────────────────────────
  try {
    // Unregister Push Notifications token from indexer (Phase B: only push path).
    final indexerService = await container.read(indexerServiceProvider.future);
    await indexerService.unregisterTargetedPush();
  } catch (e) {
    print('⚠️ performLogout: Failed to unregister push token from indexer: $e');
  }

  try {
    // Delete local FCM token (legacy - no-op post Task 2.5)
    await NotificationService().deleteToken();
  } catch (e) {
    print('⚠️ performLogout: Failed to delete FCM token: $e');
  }

  // ── Step 2: Clear all persisted data ──────────────────────────────
  // Each step is wrapped so one failure doesn't block the rest.

  try {
    print('🚪 performLogout: Clearing message cache...');
    await container.read(messageCacheProvider).clearMessages();
  } catch (e) {
    print('⚠️ performLogout: Failed to clear message cache: $e');
  }

  try {
    print('🚪 performLogout: Clearing alias chat cache...');
    await container.read(aliasChatCacheProvider).clearAll();
  } catch (e) {
    print('⚠️ performLogout: Failed to clear alias chat cache: $e');
  }

  try {
    print('🚪 performLogout: Clearing alias keys...');
    await container.read(aliasKeyServiceProvider).deleteAllChannels();
  } catch (e) {
    print('⚠️ performLogout: Failed to clear alias keys: $e');
  }

  try {
    print('🚪 performLogout: Resetting sync state...');
    await container.read(syncStateProvider).reset();
  } catch (e) {
    print('⚠️ performLogout: Failed to reset sync state: $e');
  }

  try {
    print('🚪 performLogout: Clearing keys...');
    await container.read(keysProvider.notifier).clearKeys();
  } catch (e) {
    print('⚠️ performLogout: Failed to clear keys: $e');
  }

  try {
    print('🚪 performLogout: Logging out user...');
    await container.read(userProvider.notifier).logout();
  } catch (e) {
    print('⚠️ performLogout: Failed to logout user: $e');
  }

  try {
    print('🚪 performLogout: Deleting wallet...');
    final algoWallet = await container.read(algorandWalletProvider.future);
    await algoWallet.deleteWallet();
  } catch (e) {
    print('⚠️ performLogout: Failed to delete wallet: $e');
  }

  // Close & delete the SQLCipher DB file BEFORE we wipe the DEK that
  // encrypts it. After clearPinAndDekState() the next session bootstraps a
  // fresh DEK, and a leftover DB file encrypted with the old key would
  // mount but reject writes ("attempt to write a readonly database").
  try {
    print('🚪 performLogout: Closing & deleting encrypted DB file...');
    await LocalDatabase.closeAndDelete();
  } catch (e) {
    print('⚠️ performLogout: Failed to delete DB file: $e');
  }

  // Clear PIN/DEK/termination secure-storage so a follow-up account
  // creation gets a fresh PIN setup prompt. Without this, the previous
  // user's PIN salt + DEK wraps survive logout, PinService.isPinSet()
  // keeps returning true, and PinSetupScreen never fires for the new
  // account.
  try {
    print('🚪 performLogout: Clearing PIN / DEK secure-storage...');
    await container.read(dekManagerProvider).clearPinAndDekState();
    container.read(pinSessionProvider.notifier).reset();
  } catch (e) {
    print('⚠️ performLogout: Failed to clear PIN/DEK state: $e');
  }

  // ── Step 3: Now that everything is gone, flip wallet state ───────
  // Doing this AFTER the destructive work prevents the UI from
  // navigating to the wallet-setup screen and letting the user
  // create a new wallet while the destructive work is still running.
  try {
    container.read(localWalletProvider.notifier).setNoWalletState();
    print('🚪 performLogout: Set wallet state to noWallet');
  } catch (e) {
    print('⚠️ performLogout: Failed to set noWallet state: $e');
  }

  // ── Step 4: Invalidate providers for clean rebuilds ───────────────
  // Data is already gone, so rebuilds will see empty state.
  print('🚪 performLogout: Invalidating providers...');
  container.invalidate(algorandWalletProvider);
  container.invalidate(chainClientProvider);
  container.invalidate(messagesNotifierProvider);
  container.invalidate(messageServiceProvider);
  container.invalidate(keysProvider);
  container.invalidate(userProvider);
  container.invalidate(localWalletProvider);

  print('🚪 performLogout: Logout complete!');
}

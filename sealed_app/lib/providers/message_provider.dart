// lib/providers/messages_provider.dart

import 'dart:async';
import 'package:sealed_app/core/log.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/messaging/alias/alias_onboarding_service.dart';
import 'package:sealed_app/features/messaging/background_wake_runner.dart';
import 'package:sealed_app/features/messaging/message_service.dart';
import 'package:sealed_app/features/notifications/notification_service.dart';
import 'package:sealed_app/features/wallet/credits_service.dart';
import 'package:sealed_app/infra/local/repositories/contact_repository.dart'
    show PendingInvite;
import 'package:sealed_app/infra/local/block_mirror.dart';
import 'package:sealed_app/infra/local/repositories/message_repository.dart';
import 'package:sealed_app/infra/local/wake_stage_store.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/providers/chain_provider.dart';
import 'package:sealed_app/providers/pin_provider.dart';
import 'package:sealed_app/providers/indexer_provider.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/user_provider.dart'
    show userServiceProvider;

/// Bridges Flutter app-lifecycle callbacks into [MessagesNotifier] so polling
/// can pause in the background. (A Riverpod notifier can't be a
/// WidgetsBindingObserver directly.)
class _LifecycleWatcher extends WidgetsBindingObserver {
  _LifecycleWatcher(this._onChange);
  final void Function(AppLifecycleState) _onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onChange(state);
}

class MessagesNotifier extends AsyncNotifier<List<ChatPreview>> {
  late MessageService _messageService;
  late MessageRepository _messageCache;
  bool _isSyncing = false;
  Timer? _pollingTimer;
  Timer? _usernameRefreshTimer;
  _LifecycleWatcher? _lifecycleWatcher;

  /// Polling is suspended while the app is backgrounded — push wake handles
  /// background delivery, and a foreground-only poll cuts relay traffic and
  /// battery drain dramatically.
  bool _pollingPaused = false;

  /// Consecutive sync failures, for exponential backoff of the poll interval.
  int _consecutiveSyncFailures = 0;

  /// How often we check if contacts updated their usernames (120s)
  static const _usernameRefreshInterval = Duration(seconds: 15);

  /// Foreground app-wide polling interval (chat list / not focused on a thread).
  /// Push wake is the primary delivery path; an open chat polls faster via the
  /// chat screen's focused sync. (Was 5s — ~17k relay round trips/device/day.)
  static const _blockchainPollInterval = Duration(seconds: 6);

  /// Upper bound for the backed-off poll interval after repeated failures.
  static const _maxBackoffInterval = Duration(minutes: 5);

  @override
  Future<List<ChatPreview>> build() async {
    if (kDebugMode)
      Log.d('[DEBUG-sync1] 🔨 build() running at ${DateTime.now()}');
    if (kDebugMode)
      Log.d('[MessagesNotifier] 🔨 build() - initializing messages provider');
    _messageService = await ref.watch(messageServiceProvider.future);
    final chainClient = await ref.watch(sealedChainClientProvider.future);
    // Use read instead of watch to avoid circular dependency:
    // indexerInitializerProvider's callback invalidates messagesNotifierProvider
    ref.read(indexerInitializerProvider);
    if (kDebugMode) Log.d('[MessagesNotifier] ✅ MessageService initialized');
    _messageCache = ref.watch(messageRepositoryProvider);
    if (kDebugMode) Log.d('[MessagesNotifier] ✅ MessageCache initialized');

    final userWallet = chainClient.wallet.walletAddress;
    if (userWallet == null) {
      if (kDebugMode)
        Log.d('[MessagesNotifier] ⚠️ No wallet address available');
      return [];
    }

    // Set up blockchain auto-refresh polling (only sync path supported).
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _pollingPaused = false;
    _consecutiveSyncFailures = 0;
    _startBlockchainPolling();

    // Pause polling while backgrounded; resume (and immediately catch up) on
    // foreground. Push wake covers the background window.
    final watcher = _LifecycleWatcher(_onLifecycleChange);
    _lifecycleWatcher = watcher;
    WidgetsBinding.instance.addObserver(watcher);

    // Clean up timers + observer when provider is disposed/rebuilt
    ref.onDispose(() {
      if (kDebugMode)
        Log.d(
          '[DEBUG-sync1] 💀 provider disposed, timer cancelled at ${DateTime.now()}',
        );
      _pollingTimer?.cancel();
      _pollingTimer = null;
      _usernameRefreshTimer?.cancel();
      _usernameRefreshTimer = null;
      if (_lifecycleWatcher != null) {
        WidgetsBinding.instance.removeObserver(_lifecycleWatcher!);
        _lifecycleWatcher = null;
      }
    });

    // Remove any leftover Solana-chain conversations before displaying the list.
    await _messageCache.purgeSolanaConversations();

    final conversations = await _messageCache.getConversations(
      currentUserWallet: userWallet,
    );
    if (kDebugMode)
      Log.d(
        '[MessagesNotifier] ✅ Loaded ${conversations.length} conversations',
      );

    // 🔥 Auto-sync on fresh login (when cache is empty)
    if (conversations.isEmpty && !_isSyncing) {
      if (kDebugMode)
        Log.d(
          '[MessagesNotifier] 📥 Empty cache detected - triggering initial sync',
        );

      // Don't await to avoid blocking UI. This is the fresh-login / mnemonic
      // restore path: the cache is empty so the full sync pulls the account's
      // history. Those messages are historical and the chain carries no read
      // state, so once the restore sync lands, mark everything read — mirroring
      // forceResync(). Without this every restored incoming message (wallet AND
      // alias) lands is_read=0 and shows a spurious unread badge after login.
      syncMessages(fullSync: true).then((_) async {
        await _messageCache.markAllAsRead();
        await ref.read(contactRepositoryProvider).markAllContactMessagesRead();
        bumpRefresh();
      });
    }

    // Start periodic username refresh unconditionally. Gating this on
    // conversations.isNotEmpty left the timer permanently off when build()
    // ran against an empty cache (fresh login / restore): the fire-and-forget
    // sync filled the DB later but never re-ran build(), so usernames were
    // never refreshed. The loop early-returns when there are no contacts,
    // so an empty start is free.
    _startUsernameRefresh();

    return conversations;
  }

  /// Start (or restart) the self-rescheduling blockchain poll. Uses a one-shot
  /// Timer that reschedules itself after each tick so the delay can grow with
  /// [_consecutiveSyncFailures] (exponential backoff) and so polling can be
  /// suspended while backgrounded.
  void _startBlockchainPolling() {
    if (kDebugMode)
      Log.d(
        '[MessagesNotifier] ⛓️ Starting blockchain polling (every ${_blockchainPollInterval.inSeconds}s, paused while backgrounded)',
      );
    _scheduleNextPoll();
  }

  Duration _nextPollDelay() {
    if (_consecutiveSyncFailures == 0) return _blockchainPollInterval;
    // Exponential backoff: base * 2^failures, capped.
    final factor = 1 << _consecutiveSyncFailures.clamp(0, 10);
    final ms = _blockchainPollInterval.inMilliseconds * factor;
    final capped = ms.clamp(0, _maxBackoffInterval.inMilliseconds);
    return Duration(milliseconds: capped);
  }

  void _scheduleNextPoll() {
    _pollingTimer?.cancel();
    if (_pollingPaused) return;
    _pollingTimer = Timer(_nextPollDelay(), () async {
      if (!_isSyncing) {
        await syncMessages();
      }
      _scheduleNextPoll();
    });
  }

  /// App lifecycle hook: suspend polling in the background (push wake covers
  /// delivery), resume + immediately catch up on foreground.
  void _onLifecycleChange(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      if (!_pollingPaused) return;
      _pollingPaused = false;
      if (kDebugMode)
        Log.d('[MessagesNotifier] ▶️ foreground — resume polling');
      if (!_isSyncing) unawaited(syncMessages());
      _scheduleNextPoll();
    } else {
      if (_pollingPaused) return;
      _pollingPaused = true;
      _pollingTimer?.cancel();
      _pollingTimer = null;
      if (kDebugMode) Log.d('[MessagesNotifier] ⏸️ background — pause polling');
    }
  }

  // void _startIndexerPolling() {
  //   _pollingTimer?.cancel();
  //   Log.d(
  //     '[MessagesNotifier] 📡 Starting indexer fallback polling (every ${_indexerPollInterval.inSeconds}s)',
  //   );
  //   _pollingTimer = Timer.periodic(_indexerPollInterval, (_) async {
  //     if (!_isSyncing) {
  //       final newMessageCount = await syncMessages();
  //       if (newMessageCount > 0) {
  //         Log.d(
  //           '[MessagesNotifier] ✅ Found $newMessageCount new messages via indexer',
  //         );
  //       }
  //       // Remove no-op logging to reduce I/O overhead
  //     }
  //   });
  // }

  Future<int> syncMessages({bool fullSync = false}) async {
    // Guard against concurrent syncs and syncs during logout
    if (_isSyncing) {
      if (kDebugMode)
        Log.d('[MessagesNotifier] ⚠️ Sync already in progress, skipping');
      return 0;
    }

    _isSyncing = true;
    try {
      const preferredLayer = SyncLayer.blockchain;

      if (kDebugMode)
        Log.d(
          '[MessagesNotifier] 🔄 syncMessages() - triggering sync, fullSync: $fullSync, preferredLayer: $preferredLayer',
        );
      final count = await _messageService.syncMessages(
        fullSync: fullSync,
        preferredLayer: preferredLayer,
      );
      _consecutiveSyncFailures = 0; // success resets the backoff

      // Only refresh UI if we actually found new messages
      if (count > 0 || fullSync) {
        if (kDebugMode)
          Log.d(
            '[MessagesNotifier] ✅ Sync completed with $count new messages, refreshing UI',
          );
        await refresh();
        // refresh() reloads the wallet chat list but does NOT signal the
        // counter-driven providers (alias previews, pending invites). A synced
        // invite envelope writes a pending row that those providers must re-read
        // — bump so the AliasInvitations banner + invitation rows appear.
        bumpRefresh();
      }
      // A full sync may have pulled block changes from another device — converge
      // the PIN-free block mirror (#17). Off the hot path; fire-and-forget.
      if (fullSync) unawaited(reconcileBlockMirror());
      // Remove no-op logging for better performance

      return count;
    } catch (e) {
      if (kDebugMode) Log.d('[MessagesNotifier] ❌ Sync error: $e');
      _consecutiveSyncFailures++; // grows the next poll delay (backoff)
      // Don't rethrow - just log and return 0
      return 0;
    } finally {
      _isSyncing = false;
    }
  }

  /// Drain push pre-staged envelopes ([WakeStageStore]) into the DB on the main
  /// isolate: unwrap the device-secret staging key, decrypt the staged raw
  /// messages via the normal pipeline (idempotent dedupe), and refresh the UI —
  /// no network. Best-effort: a missing device secret / locked state / empty
  /// stage is a silent no-op (the cursor-based sync remains authoritative).
  Future<void> drainWakeStage() async {
    try {
      final key = await ref.read(dekManagerProvider).deriveStagingKey();
      final store = WakeStageStore(stagingKey: key);
      final staged = await store.drain();
      if (staged.isEmpty) return;
      final count = await _messageService.ingestRawMessages([
        for (final e in staged) e.toRawMessage(),
      ]);
      if (count > 0) {
        await refresh();
        bumpRefresh();
      }
    } catch (e) {
      if (kDebugMode) Log.d('[MessagesNotifier] wake-stage drain skipped: $e');
    }
  }

  // Force a full resync by clearing cache and resetting sync state
  Future<void> forceResync() async {
    if (_isSyncing) {
      if (kDebugMode)
        Log.d(
          '[MessagesNotifier] ⚠️ Sync already in progress, skipping forceResync',
        );
      return;
    }

    _isSyncing = true;
    _pollingTimer?.cancel();
    _pollingTimer = null;

    if (kDebugMode)
      Log.d(
        '[MessagesNotifier] 🔄 forceResync() - delegating to MessageService',
      );
    try {
      const preferredLayer = SyncLayer.blockchain;

      await _messageService.forceResync(preferredLayer);
      await refresh();
    } finally {
      _startBlockchainPolling();
      _isSyncing = false;
    }
  }

  /// Refresh conversations from cache
  Future<List<ChatPreview>> refresh() async {
    if (kDebugMode)
      Log.d('[MessagesNotifier] 🔄 refresh() - reloading conversations');
    // read, not watch: this runs outside build(); watching here would register
    // a phantom dependency and is unsupported by Riverpod.
    final chainClient = await ref.read(sealedChainClientProvider.future);
    final userWallet = chainClient.wallet.walletAddress;

    if (userWallet == null) {
      if (kDebugMode)
        Log.d('[MessagesNotifier] ⚠️ No wallet address available for refresh');
      state = AsyncValue.data([]);
      return [];
    }

    final conversations = await _messageCache.getConversations(
      currentUserWallet: userWallet,
    );
    if (kDebugMode)
      Log.d(
        '[MessagesNotifier] ✅ Loaded ${conversations.length} conversations',
      );
    state = AsyncValue.data(conversations);
    ref.invalidate(conversationMessagesProvider);

    return conversations;
  }

  /// Get all conversations (alias for consistency with MessageService API)
  Future<List<ChatPreview>> getAllConversations() async {
    return refresh();
  }

  /// Bump the refresh counter so family providers (conversationMessages,
  /// aliasContactMessages, unifiedChatPreviews) re-evaluate. UI must not
  /// poke the StateProvider directly.
  void bumpRefresh() {
    // Bumping the counter is the ONLY refresh signal here. chatPreviewsProvider
    // watches messageRefreshCounterProvider (its "reliable refresh signal") and
    // recomputes on this bump.
    //
    // Do NOT `ref.invalidate(chatPreviewsProvider)` from this notifier:
    // chatPreviewsProvider now `ref.watch(messagesNotifierProvider)` for
    // lifecycle, so invalidating it from inside the notifier it depends on is a
    // self-cycle — Riverpod throws CircularDependencyError, which propagated up
    // through sendMessage() and surfaced a spurious "Failed to send message"
    // snackbar AFTER the message was already sent + cached. (Both the watch edge
    // and the old invalidate landed in the same commit, c6c5b3ba.)
    ref.read(messageRefreshCounterProvider.notifier).state++;
  }

  /// Send a direct (wallet-to-wallet) message via the message service.
  /// Refreshes the conversation list + per-conversation provider on success.
  Future<void> sendMessage({
    required String recipientWallet,
    String? recipientUsername,
    required String plaintext,
  }) async {
    final chainClient = await ref.read(sealedChainClientProvider.future);
    final senderWallet = chainClient.wallet.walletAddress;
    if (senderWallet == null) {
      throw StateError('No wallet address available for send');
    }
    await _messageService.sendMessage(
      recipientWallet: recipientWallet,
      recipientUsername: recipientUsername,
      plaintext: plaintext,
      senderWallet: senderWallet,
    );
    // The send has succeeded here: the TX is on-chain and the outgoing message
    // is already persisted to the local cache. Everything below is best-effort
    // UI refresh. A failure in refresh() (chain-client re-watch or cache read)
    // must NOT propagate — otherwise the screen shows a "send failed" snackbar
    // (with a retry that double-sends and double-burns credits) on a message
    // that actually went through.
    try {
      ref.invalidate(conversationMessagesProvider(recipientWallet));
      await refresh();
    } catch (e, st) {
      if (kDebugMode) {
        Log.d(
          '[MessagesNotifier] ⚠️ post-send refresh failed; '
          'message already sent and cached: $e\n$st',
        );
      }
    }
    // refresh() reloads this notifier's own wallet list, but the chat list
    // renders the MERGED surface (chatPreviewsProvider), which only re-runs
    // when the refresh counter bumps (via its aliasPreviews dependency).
    // Without this bump the preview keeps showing the previous message even
    // though the thread (conversationMessagesProvider, invalidated above) is
    // already current — matching the sync path, which also bumps after refresh.
    // Kept outside the try above so the cached send still surfaces in the
    // merged preview even when refresh() throws.
    bumpRefresh();
    // Sending spent a credit on-chain; refresh the watched balance so the
    // settings screen ticks down immediately rather than waiting for the next
    // poll. Outside the try so it runs even if the UI refresh above threw.
    ref.invalidate(creditsBalanceProvider);
  }

  /// Send pre-encoded sealed bytes (used by alias-onboarding flows).
  /// Returns the on-chain message id.
  Future<String> sendMessageBytes({
    required String recipientWallet,
    required Uint8List plaintextBytes,
  }) async {
    final chainClient = await ref.read(sealedChainClientProvider.future);
    final senderWallet = chainClient.wallet.walletAddress;
    if (senderWallet == null) {
      throw StateError('No wallet address available for send');
    }
    return _messageService.sendMessageBytes(
      recipientWallet: recipientWallet,
      plaintextBytes: plaintextBytes,
      senderWallet: senderWallet,
    );
  }

  /// Send a message on an existing alias chat.
  Future<void> sendAliasMessage({
    required String contactId,
    required String plaintext,
  }) async {
    await _messageService.sendAliasMessage(
      contactId: contactId,
      plaintext: plaintext,
    );
    ref.invalidate(aliasContactMessagesProvider(contactId));
    // Sending spends a credit on-chain; refresh the watched balance so it ticks
    // down immediately rather than waiting for the next poll.
    ref.invalidate(creditsBalanceProvider);
    bumpRefresh();
  }

  /// Mark a direct conversation as read. Triggers a refresh so the unread
  /// badge clears in the chat list. No-op (no refresh) when nothing was
  /// unread — callers may invoke this on every thread update, and the
  /// zero-row case must not bump providers (refresh → rebuild → mark-read
  /// would loop forever).
  Future<void> markConversationAsRead(String contactWallet) async {
    final flipped = await _messageService.markConversationAsRead(contactWallet);
    if (flipped == 0) return;
    // refresh() reloads the chat list without disposing this notifier
    // (invalidate() would kill the polling timer).
    await refresh();
    // refresh() alone does not reach the merged chat-list surface
    // (chatPreviewsProvider) — its badge only re-reads on a counter bump.
    bumpRefresh();
  }

  /// Mark alias messages as read locally and trigger a UI refresh. Same
  /// zero-row guard as [markConversationAsRead].
  Future<void> markAliasAsRead(String contactId) async {
    final repo = ref.read(contactRepositoryProvider);
    final flipped = await repo.markContactMessagesRead(contactId);
    if (flipped == 0) return;
    bumpRefresh();
  }

  /// Rename a contact (set/clear nickname). Bumps the refresh counter so
  /// the chat list and per-contact preview reflect the new value.
  Future<void> updateNickname(String contactId, String? nickname) async {
    final repo = ref.read(contactRepositoryProvider);
    await repo.updateNickname(contactId, nickname);
    bumpRefresh();
  }

  /// Destroy an alias chat: deletes messages, keys, and on-chain data.
  Future<void> deleteAliasContact(String contactId) async {
    await _messageService.deleteAliasContact(contactId);
    bumpRefresh();
  }

  /// Destroy ALL alias chats. Enumerates every alias contact and runs the same
  /// per-contact delete path ([deleteAliasContact]) for each — erasing key
  /// material, repo rows, messages, and unregistering per-alias push.
  ///
  /// Best-effort: if one contact fails to delete, the error is swallowed,
  /// counted as a failure, and the loop continues. Returns how many were
  /// deleted vs failed. Tolerates an empty registry (returns `(0, 0)`).
  ///
  /// Refreshes the chat list once at the end (one [bumpRefresh] rather than
  /// per-contact) so the UI reflects the full result in a single rebuild.
  Future<({int deleted, int failed})> deleteAllAliasChats() async {
    final contactIds = await _messageService.getAllAliasContacts();
    var deleted = 0;
    var failed = 0;
    for (final contactId in contactIds) {
      try {
        await _messageService.deleteAliasContact(contactId);
        deleted++;
      } catch (e) {
        failed++;
        if (kDebugMode) {
          Log.d(
            '[MessagesNotifier] ⚠️ deleteAllAliasChats: failed to delete '
            '$contactId: $e',
          );
        }
      }
    }
    if (deleted > 0) bumpRefresh();
    return (deleted: deleted, failed: failed);
  }

  /// Block a wallet contact. Persists is_blocked; the conversation moves to the
  /// Spam bucket (the sole spam predicate) and its messages stop triggering
  /// local notifications. Survives sync/restart. Reloads the chat list.
  Future<void> blockContact(String contactWallet) async {
    final repo = ref.read(contactRepositoryProvider);
    await repo.blockContact(contactWallet);
    // Write-through to the PIN-free block mirror so the background isolate can
    // suppress this sender's push (#17) without unlocking the DB.
    await _mirrorBlock(contactWallet, blocked: true);
    await refresh();
    // refresh() reloads the chat list but does NOT touch the refresh counter —
    // bump it so contactBlockedProvider/contactIsContactProvider (profile
    // badge + action rows) re-evaluate immediately.
    bumpRefresh();
  }

  /// Unblock a wallet contact: clears is_blocked, returning it to Chats and
  /// re-enabling notifications.
  Future<void> unblockContact(String contactWallet) async {
    final repo = ref.read(contactRepositoryProvider);
    await repo.unblockContact(contactWallet);
    await _mirrorBlock(contactWallet, blocked: false);
    await refresh();
    bumpRefresh();
  }

  /// Best-effort write-through of one block/unblock to the device-secret block
  /// mirror. A missing device secret (pre-bootstrap) is a silent no-op; the
  /// next full-sync reconcile rebuilds the mirror from the DB anyway.
  Future<void> _mirrorBlock(String wallet, {required bool blocked}) async {
    try {
      final key = await ref.read(dekManagerProvider).deriveBlockMirrorKey();
      final mirror = BlockMirror(mirrorKey: key);
      if (blocked) {
        await mirror.add(wallet);
      } else {
        await mirror.remove(wallet);
      }
    } catch (e) {
      if (kDebugMode)
        Log.d('[MessagesNotifier] block-mirror write skipped: $e');
    }
  }

  /// Rebuild the block mirror from the DB block list — converges out-of-band
  /// changes (e.g. a block synced from another device). Cheap; called on full
  /// sync. Best-effort.
  Future<void> reconcileBlockMirror() async {
    try {
      final blocked = await ref
          .read(contactRepositoryProvider)
          .getBlockedWallets();
      final key = await ref.read(dekManagerProvider).deriveBlockMirrorKey();
      await BlockMirror(mirrorKey: key).reconcile(blocked);
    } catch (e) {
      if (kDebugMode) {
        Log.d('[MessagesNotifier] block-mirror reconcile skipped: $e');
      }
    }
  }

  /// Manually add a wallet peer to Contacts (is_contact flag). Lazily creates
  /// the key-cache row if the peer was never messaged; throws if the row
  /// cannot be created (offline + unresolvable keys). No chat-list change —
  /// a counter bump refreshes the badge + Contacts list.
  Future<void> addToContacts(String contactWallet) async {
    final repo = ref.read(contactRepositoryProvider);
    await repo.addToContacts(contactWallet);
    bumpRefresh();
  }

  /// Remove a wallet peer from Contacts. The key-cache row (and any chat)
  /// stays — only the manual-contact flag is cleared.
  Future<void> removeFromContacts(String contactWallet) async {
    final repo = ref.read(contactRepositoryProvider);
    await repo.removeFromContacts(contactWallet);
    bumpRefresh();
  }

  /// Delete a wallet-addressed conversation: removes all local message rows for
  /// this peer. On-chain data is unaffected. Reloads the chat list.
  Future<void> deleteConversation(String contactWallet) async {
    await _messageCache.deleteConversation(contactWallet);
    await refresh();
  }

  /// Start periodic checks for contact username changes
  void _startUsernameRefresh() {
    _usernameRefreshTimer?.cancel();
    if (kDebugMode)
      Log.d(
        '[MessagesNotifier] 👤 Starting username refresh (every ${_usernameRefreshInterval.inSeconds}s)',
      );
    // Delay first run slightly so build() completes first
    _usernameRefreshTimer = Timer(const Duration(seconds: 3), () {
      _refreshContactUsernames();
      // Then repeat on interval
      _usernameRefreshTimer = Timer.periodic(_usernameRefreshInterval, (_) {
        _refreshContactUsernames();
      });
    });
  }

  /// Check all conversation contacts for username changes via the indexer.
  /// If a contact set or changed their username, update the messages table
  /// and contacts cache, then refresh the conversation list.
  Future<void> _refreshContactUsernames() async {
    try {
      final chainClient = await ref.read(sealedChainClientProvider.future);
      final userWallet = chainClient.wallet.walletAddress;
      if (kDebugMode)
        Log.d(
          userWallet == null
              ? '[MessagesNotifier] ⚠️ No wallet address available for username refresh'
              : '[MessagesNotifier] 🔍 Checking for username changes for contacts of $userWallet  ',
        );
      if (userWallet == null) return;

      final contactRepo = ref.read(contactRepositoryProvider);
      final contactWallets = await _messageCache.getContactWallets(userWallet);

      if (contactWallets.isEmpty) return;

      bool anyUpdated = false;

      if (kDebugMode)
        Log.d(
          '[MessagesNotifier] 🔍 Checking usernames for ${contactWallets.length} contacts',
        );

      for (final wallet in contactWallets) {
        try {
          final profile = await chainClient.getUserByWallet(wallet);
          if (profile == null) {
            // Contact not registered on-chain — normal for new users
            if (kDebugMode)
              Log.d('[MessagesNotifier] 👤 $wallet: not on-chain (skipped)');
            continue;
          }

          final freshUsername = profile.username;
          final cached = await contactRepo.getContact(wallet);
          final cachedUsername = cached?.username;

          if (kDebugMode)
            Log.d(
              '[MessagesNotifier] 👤 $wallet: chain="$freshUsername", cached="$cachedUsername"',
            );

          // Skip if username hasn't changed
          if (freshUsername == cachedUsername) {
            continue;
          }

          if (kDebugMode)
            Log.d(
              '[MessagesNotifier] 🔄 Username changed for $wallet: '
              '"$cachedUsername" → "$freshUsername"',
            );

          // Update messages table
          await _messageCache.updateContactUsername(
            wallet,
            freshUsername ?? '',
          );

          // Update contacts cache
          if (cached != null) {
            await contactRepo.saveContact(
              cached.copyWith(username: freshUsername),
            );
          }

          anyUpdated = true;
        } catch (e) {
          // Skip individual failures — don't block other contacts
          continue;
        }
      }

      if (anyUpdated) {
        await refresh();
        // refresh() reloads the raw wallet list but doesn't reach the
        // counter-driven surfaces (chatPreviewsProvider, walletPeerNameProvider,
        // the open chat header). Bump so a peer's new nickname shows without an
        // app restart.
        bumpRefresh();
      }
    } catch (e) {
      if (kDebugMode)
        Log.d('[MessagesNotifier] ⚠️ Username refresh failed: $e');
    }
  }
}

final messagesNotifierProvider =
    AsyncNotifierProvider<MessagesNotifier, List<ChatPreview>>(
      MessagesNotifier.new,
    );

// ============================================================================
// MESSAGE SERVICE
// ============================================================================

final messageServiceProvider = FutureProvider<MessageService>((ref) async {
  final keyService = await ref.watch(keyServiceProvider.future);
  final userService = await ref.watch(userServiceProvider.future);
  final indexerService = await ref.watch(indexerServiceProvider.future);
  // Credits pre-flight — non-fatal if the unified-SC client isn't ready yet.
  // MessageService treats null as "skip pre-flight".
  CreditsService? creditsService;
  try {
    creditsService = await ref
        .watch(creditsServiceProvider.future)
        .timeout(const Duration(seconds: 3));
  } catch (_) {
    creditsService = null;
  }

  final sealedClientForMsg = await ref.watch(sealedChainClientProvider.future);

  return MessageService(
    sealedClient: sealedClientForMsg,
    syncState: ref.watch(syncStateProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    userService: userService,
    contacts: ref.watch(contactRepositoryProvider),
    keyService: keyService,
    messageCache: ref.watch(messageRepositoryProvider),
    indexerService: indexerService,
    aliasKeyService: ref.watch(aliasKeyServiceProvider),
    aliasOnboardingService: await ref.watch(
      aliasOnboardingServiceProvider.future,
    ),
    creditsService: creditsService,
  );
});

// ============================================================================
// DATA PROVIDERS (Read-only, reactive)
// ============================================================================

/// All conversations for the current user
final conversationsProvider = FutureProvider<List<ChatPreview>>((ref) async {
  final keys = ref.watch(currentKeysProvider);
  if (keys == null) return [];

  final messageRepo = ref.watch(messageRepositoryProvider);
  return messageRepo.getConversations();
});

/// Counter bumped when new messages arrive via WebSocket.
/// conversationMessagesProvider watches this to trigger re-fetch.
final messageRefreshCounterProvider = StateProvider<int>((ref) => 0);

/// Messages for a specific conversation
final conversationMessagesProvider =
    FutureProvider.family<List<DecryptedMessage>, String>((
      ref,
      contactWallet,
    ) async {
      // Watch the refresh counter so we re-run when new messages arrive
      ref.watch(messageRefreshCounterProvider);

      final sealedClient = await ref.watch(sealedChainClientProvider.future);
      final myWallet = sealedClient.wallet.walletAddress;
      if (myWallet == null) return [];

      final messageRepo = ref.watch(messageRepositoryProvider);
      return messageRepo.getConversationMessages(myWallet, contactWallet);
    });

// ============================================================================
// SILENT-PUSH BINDER (Task 2.7.6)
// ============================================================================

/// Wires the singleton [NotificationService] with the bounded sync callback
/// it needs for silent APNs wake handling. Tor gate removed — push arrives
/// via OHTTP, sync happens via OHTTP, no clearnet leak.
///
/// Without this binding the wake handler returns `kResultNoData` but is
/// permanently inert: every silent push is dropped.
///
/// Awaited once from `_AppShellState.initState`. Idempotent — calling twice
/// is safe; `bindBackgroundDependencies` simply replaces the previous values.
final silentPushBinderProvider = FutureProvider<void>((ref) async {
  final messageService = await ref.watch(messageServiceProvider.future);

  NotificationService().bindBackgroundDependencies(
    // Bounded sync: prefer blockchain layer (direct + OHTTP) over indexer poll.
    // fullSync=false keeps wake budget short.
    // Returns the NOTIFIABLE count (new messages minus blocked senders) so a
    // wake that only fetched blocked-sender messages presents no notification.
    runBoundedSync: () async {
      // Foreground FCM (onMessage) can fire while the screen is locked — the DEK
      // DB is PIN-gated, so a normal sync would throw "PIN session not
      // unlocked". When locked, run the no-DB wake path instead (PIN-free
      // tag-check + block gate + stage), which self-presents the block-aware
      // notification; return 0 so the caller doesn't double-present.
      final unlocked = ref.read(pinSessionProvider).phase == PinPhase.unlocked;
      if (!unlocked) {
        await runBackgroundWakeSync();
        return 0;
      }
      await messageService.syncMessages(
        preferredLayer: SyncLayer.blockchain,
        fullSync: false,
      );
      // This calls the SERVICE sync directly, which stores rows but never
      // touches the counter-driven UI providers. Bump the refresh counter so a
      // push-driven sync surfaces the new message/conversation in the chat list
      // (#16) and a synced invite shows its banner (#7) without opening a thread.
      ref.read(messagesNotifierProvider.notifier).bumpRefresh();
      return messageService.lastNotifiableCount;
    },
  );
});

// ============================================================================
// ALIAS
// ============================================================================

/// AliasOnboardingService (requires async chain client)
final aliasOnboardingServiceProvider = FutureProvider<AliasOnboardingService>((
  ref,
) async {
  return AliasOnboardingService(
    repo: ref.watch(contactRepositoryProvider),
    keyService: ref.watch(aliasKeyServiceProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    chain: SealedClientGateway(
      await ref.watch(sealedChainClientProvider.future),
    ),
    // Auto-enable per-alias push on create/accept when global push is on.
    // Best-effort; never blocks the handshake.
    onContactEstablished: (contactId) async {
      try {
        final indexer = await ref.read(indexerServiceProvider.future);
        await indexer.enableAliasPushIfGlobalOn(contactId);
      } catch (e) {
        // ignore: avoid_print
        Log.d('[alias-onboarding] auto-enable push failed for $contactId: $e');
      }
    },
  );
});

/// Alias-contact previews (Spec H) joined with each contact's latest message.
/// Refreshes whenever [messageRefreshCounterProvider] bumps. The merged
/// chat-list surface lives in [chatPreviewsProvider].
final aliasPreviewsProvider = FutureProvider<List<ChatPreview>>((ref) async {
  ref.watch(messageRefreshCounterProvider);
  final repo = ref.watch(contactRepositoryProvider);
  return repo.getAliasPreviews();
});

/// Filter raw pending invites down to those the receiver should be offered to
/// accept: incoming (`isCreator == false`) and not dismissed. Pure — exposed
/// for unit testing. Creator-side pending rows (waiting for the peer to accept)
/// are not invitations to act on and are excluded here.
List<PendingInvite> visibleIncomingInvites(List<PendingInvite> all) => [
  for (final p in all)
    if (!p.isCreator && !p.inviteDismissed) p,
];

/// Creator-side pending invites still waiting for the peer to accept
/// (`isCreator == true`, not dismissed). These render in the Alias Chats list
/// as "Pending…" rows and open the waiting state. Pure — exposed for testing.
List<PendingInvite> visibleCreatorPending(List<PendingInvite> all) => [
  for (final p in all)
    if (p.isCreator && !p.inviteDismissed) p,
];

/// Creator-side pending invites (waiting for acceptance). Re-runs on every
/// [messageRefreshCounterProvider] bump so a row disappears the moment the
/// handshake promotes it to a real alias contact.
final creatorPendingInvitesProvider = FutureProvider<List<PendingInvite>>((
  ref,
) async {
  ref.watch(messageRefreshCounterProvider);
  final repo = ref.watch(contactRepositoryProvider);
  return visibleCreatorPending(await repo.getAllPendingInvites());
});

/// Whether a wallet contact is manually blocked. Refreshes on
/// [messageRefreshCounterProvider] so the Contact Profile toggle reflects
/// block/unblock immediately.
final contactBlockedProvider = FutureProvider.family<bool, String>((
  ref,
  wallet,
) async {
  ref.watch(messageRefreshCounterProvider);
  final repo = ref.watch(contactRepositoryProvider);
  return repo.isBlocked(wallet);
});

/// Whether a wallet contact was manually added to contacts (is_contact flag).
/// Drives the "In contacts" badge + Add/Remove action on the Contact Profile.
/// Refreshes on [messageRefreshCounterProvider] so toggles reflect immediately.
final contactIsContactProvider = FutureProvider.family<bool, String>((
  ref,
  wallet,
) async {
  ref.watch(messageRefreshCounterProvider);
  final repo = ref.watch(contactRepositoryProvider);
  return repo.isContact(wallet);
});

/// Receiver-facing pending alias invitations. Feeds the `AliasInvitations`
/// banner count and the `AliasInvitation` rows ONLY — these are NOT mixed into
/// the chat-row buckets ([chatPreviewsProvider] / [partitionChats]).
/// Refreshes whenever [messageRefreshCounterProvider] bumps.
final pendingInvitesProvider = FutureProvider<List<PendingInvite>>((ref) async {
  ref.watch(messageRefreshCounterProvider);
  final repo = ref.watch(contactRepositoryProvider);
  final visible = visibleIncomingInvites(await repo.getAllPendingInvites());
  // Hide invites from blocked/spam senders — covers the case where a contact is
  // blocked AFTER their invite already landed (aliasDisplay = inviter wallet).
  final out = <PendingInvite>[];
  for (final inv in visible) {
    if (!await repo.isBlocked(inv.aliasDisplay)) out.add(inv);
  }
  return out;
});

/// Unified chat-list surface. Concats wallet-side previews (from
/// [messagesNotifierProvider]) with alias-side previews (from
/// [aliasPreviewsProvider]). Order within tabs is decided downstream by
/// [partitionChats]. Errors in either upstream propagate; partial-degraded
/// mode is not supported in Phase 1b.
final chatPreviewsProvider = FutureProvider<List<ChatPreview>>((ref) async {
  // Re-run on every local mutation (send / sync / read / rename / restore).
  // Every write path bumps this counter, so a counter-gated read is the
  // reliable refresh signal.
  ref.watch(messageRefreshCounterProvider);

  // Keep MessagesNotifier alive so its build() fires the initial full sync and
  // sets up blockchain polling — but do NOT source the chat list from its
  // imperative AsyncNotifier state. On restore that state is unreliable: build()
  // churns (repeated empty-DB reads, each re-firing the fire-and-forget sync)
  // and the post-sync `state = AsyncData(...)` reassignment did not propagate
  // here, so recovered conversations stayed at 0 until a manual setState (the
  // "go to alias chats and back" bug). Watch the .notifier handle, NOT the
  // state: a state watch re-runs this provider on every refresh()/poll state
  // assignment, which paired with the counter bump produced two back-to-back
  // recomputes per mutation (visible chat-list jitter on unread changes).
  ref.watch(messagesNotifierProvider.notifier);

  // Source wallet conversations from the repository directly, gated on the
  // refresh counter. Once sync writes the DB and bumps the counter, this
  // re-runs and reads the fresh rows deterministically — immune to notifier
  // build() churn. Mirrors conversationsProvider.
  final messageRepo = ref.watch(messageRepositoryProvider);
  final sealedClient = await ref.watch(sealedChainClientProvider.future);
  final myWallet = sealedClient.wallet.walletAddress;
  final wallet = myWallet == null
      ? const <ChatPreview>[]
      : await messageRepo.getConversations(currentUserWallet: myWallet);

  // Alias previews as a LIVE AsyncValue — NOT `.future`. Awaiting the future
  // suspends this whole merged provider until alias previews resolve, which on
  // restore hid an already-synced wallet conversation behind the await.
  final aliasAsync = ref.watch(aliasPreviewsProvider);
  final alias = aliasAsync.value ?? const <ChatPreview>[];

  return [...wallet, ...alias];
});

/// Messages for a specific alias contact (keyed by contactId).
/// Refreshes whenever [messageRefreshCounterProvider] bumps.
final aliasContactMessagesProvider =
    FutureProvider.family<List<DecryptedMessage>, String>((
      ref,
      contactId,
    ) async {
      ref.watch(messageRefreshCounterProvider);
      final repo = ref.watch(contactRepositoryProvider);
      final rows = await repo.getContactMessages(contactId);
      return rows
          .map(
            (m) => DecryptedMessage(
              id: m.id,
              senderWallet: '',
              recipientWallet: '',
              content: m.content,
              timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
              isOutgoing: m.direction == 1,
              onChainPubkey: m.onChainRef ?? '',
            ),
          )
          .toList();
    });

/// Resolve an [inviteSecret] (raw string from URI) to an [AliasContact]
/// contactId. Returns null if no alias contact exists for that invite yet.
final aliasContactIdByInviteSecretProvider =
    FutureProvider.family<String?, String>((ref, inviteSecret) async {
      ref.watch(messageRefreshCounterProvider);
      // inviteRef = sha256hex(inviteSecret bytes)
      final bytes = Uint8List.fromList(utf8.encode(inviteSecret));
      final hash = await Sha256().hash(bytes);
      final inviteRef = hash.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final repo = ref.watch(contactRepositoryProvider);
      final contact = await repo.getContactByInviteRef(inviteRef);
      return contact?.contactId;
    });

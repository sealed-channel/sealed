// lib/providers/messages_provider.dart

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/local/message_cache.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/providers/app_providers.dart';
import 'package:sealed_app/remote/indexer_client.dart';
import 'package:sealed_app/services/message_service.dart';

class MessagesNotifier extends AsyncNotifier<List<ConversationPreview>> {
  late MessageService _messageService;
  late MessageCache _messageCache;
  bool _isSyncing = false;
  Timer? _pollingTimer;
  Timer? _usernameRefreshTimer;

  /// How often we check if contacts updated their usernames (60s)
  static const _usernameRefreshInterval = Duration(seconds: 60);

  /// Blockchain polling interval (5s for OHTTP-only / no real-time mode)
  static const _blockchainPollInterval = Duration(seconds: 5);

  /// Indexer fallback polling interval (safety net when WebSocket fails)
  static const _indexerPollInterval = Duration(seconds: 5);

  @override
  Future<List<ConversationPreview>> build() async {
    print('[MessagesNotifier] 🔨 build() - initializing messages provider');
    _messageService = await ref.watch(messageServiceProvider.future);
    final chainClient = await ref.watch(chainClientProvider.future);
    // Use read instead of watch to avoid circular dependency:
    // indexerInitializerProvider's callback invalidates messagesNotifierProvider
    ref.read(indexerInitializerProvider);
    print('[MessagesNotifier] ✅ MessageService initialized');
    _messageCache = ref.watch(messageCacheProvider);
    print('[MessagesNotifier] ✅ MessageCache initialized');

    final userWallet = chainClient.activeWalletAddress;
    if (userWallet == null) {
      print('[MessagesNotifier] ⚠️ No wallet address available');
      return [];
    }

    // Set up blockchain auto-refresh polling if sync method is blockchain
    _pollingTimer?.cancel();
    _pollingTimer = null;
    final settings = await ref.read(appSettingsServiceProvider.future);
    final syncLayer = settings.preferredSyncLayer;
    if (syncLayer == SyncLayer.blockchain) {
      _startBlockchainPolling();
    } else {
      _startIndexerPolling();
    }

    // Clean up timers when provider is disposed/rebuilt
    ref.onDispose(() {
      _pollingTimer?.cancel();
      _pollingTimer = null;
      _usernameRefreshTimer?.cancel();
      _usernameRefreshTimer = null;
    });

    // Remove any leftover Solana-chain conversations before displaying the list.
    await _messageCache.purgeSolanaConversations();

    final conversations = await _messageCache.getConversations(
      currentUserWallet: userWallet,
    );
    print('[MessagesNotifier] ✅ Loaded ${conversations.length} conversations');

    // 🔥 Auto-sync on fresh login (when cache is empty)
    if (conversations.isEmpty && !_isSyncing) {
      print(
        '[MessagesNotifier] 📥 Empty cache detected - triggering initial sync',
      );

      // Don't await to avoid blocking UI
      syncMessages(fullSync: true);
    }

    // Start periodic username refresh AFTER conversations are loaded
    // so getContactWallets() has data to work with
    if (conversations.isNotEmpty) {
      _startUsernameRefresh();
    }

    return conversations;
  }

  /// Start periodic blockchain polling for new messages
  void _startBlockchainPolling() {
    _pollingTimer?.cancel();
    print(
      '[MessagesNotifier] ⛓️ Starting blockchain polling (every ${_blockchainPollInterval.inSeconds}s)',
    );
    _pollingTimer = Timer.periodic(_blockchainPollInterval, (_) async {
      if (!_isSyncing) {
        final newMessageCount = await syncMessages();
        if (newMessageCount > 0) {
          print(
            '[MessagesNotifier] ✅ Found $newMessageCount new messages, UI updated',
          );
        }
        // Remove no-op logging to reduce I/O overhead in hot path
      }
    });
  }

  /// Start periodic indexer polling as fallback when WebSocket real-time fails
  void _startIndexerPolling() {
    _pollingTimer?.cancel();
    print(
      '[MessagesNotifier] 📡 Starting indexer fallback polling (every ${_indexerPollInterval.inSeconds}s)',
    );
    _pollingTimer = Timer.periodic(_indexerPollInterval, (_) async {
      if (!_isSyncing) {
        final newMessageCount = await syncMessages();
        if (newMessageCount > 0) {
          print(
            '[MessagesNotifier] ✅ Found $newMessageCount new messages via indexer',
          );
        }
        // Remove no-op logging to reduce I/O overhead
      }
    });
  }

  Future<int> syncMessages({bool fullSync = false}) async {
    // Guard against concurrent syncs and syncs during logout
    if (_isSyncing) {
      print('[MessagesNotifier] ⚠️ Sync already in progress, skipping');
      return 0;
    }

    _isSyncing = true;
    try {
      // Get preferred sync layer from settings
      final settings = await ref.read(appSettingsServiceProvider.future);
      final preferredLayer = settings.preferredSyncLayer;

      print(
        '[MessagesNotifier] 🔄 syncMessages() - triggering sync, fullSync: $fullSync, preferredLayer: $preferredLayer',
      );
      final count = await _messageService.syncMessages(
        fullSync: fullSync,
        preferredLayer: preferredLayer,
      );

      // Also sync alias chat messages
      int aliasCount = 0;
      try {
        final aliasService = await ref.read(aliasChatServiceProvider.future);
        aliasCount = await aliasService.syncAliasMessages();
        if (aliasCount > 0) {
          ref.read(messageRefreshCounterProvider.notifier).state++;
        }
      } catch (_) {
        // Alias sync failure shouldn't block regular sync
      }

      // Only refresh UI if we actually found new messages
      final totalNewMessages = count + aliasCount;
      if (totalNewMessages > 0 || fullSync) {
        print(
          '[MessagesNotifier] ✅ Sync completed with $totalNewMessages new messages, refreshing UI',
        );
        await refresh();
      }
      // Remove no-op logging for better performance

      return count;
    } catch (e) {
      print('[MessagesNotifier] ❌ Sync error: $e');
      // Don't rethrow - just log and return 0
      return 0;
    } finally {
      _isSyncing = false;
    }
  }

  // Force a full resync by clearing cache and resetting sync state
  Future<void> forceResync() async {
    if (_isSyncing) {
      print(
        '[MessagesNotifier] ⚠️ Sync already in progress, skipping forceResync',
      );
      return;
    }

    _isSyncing = true;
    _pollingTimer?.cancel();
    _pollingTimer = null;

    print('[MessagesNotifier] 🔄 forceResync() - delegating to MessageService');
    try {
      final settings = await ref.read(appSettingsServiceProvider.future);
      final preferredLayer = settings.preferredSyncLayer;

      await _messageService.forceResync(preferredLayer!);
      await refresh();
    } finally {
      final settings = await ref.read(appSettingsServiceProvider.future);
      if (settings.preferredSyncLayer == SyncLayer.blockchain) {
        _startBlockchainPolling();
      }
      _isSyncing = false;
    }
  }

  /// Refresh conversations from cache
  Future<List<ConversationPreview>> refresh() async {
    print('[MessagesNotifier] 🔄 refresh() - reloading conversations');
    final chainClient = await ref.watch(chainClientProvider.future);
    final userWallet = chainClient.activeWalletAddress;

    if (userWallet == null) {
      print('[MessagesNotifier] ⚠️ No wallet address available for refresh');
      state = AsyncValue.data([]);
      return [];
    }

    await _messageCache.purgeSolanaConversations();

    final conversations = await _messageCache.getConversations(
      currentUserWallet: userWallet,
    );
    print('[MessagesNotifier] ✅ Loaded ${conversations.length} conversations');
    state = AsyncValue.data(conversations);

    // Also invalidate the per-conversation provider so chat detail screens
    // pick up any new/changed messages (e.g. after resync)
    ref.invalidate(conversationMessagesProvider);

    return conversations;
  }

  /// Get all conversations (alias for consistency with MessageService API)
  Future<List<ConversationPreview>> getAllConversations() async {
    return refresh();
  }

  /// Start periodic checks for contact username changes
  void _startUsernameRefresh() {
    _usernameRefreshTimer?.cancel();
    print(
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
      final chainClient = await ref.read(chainClientProvider.future);
      final userWallet = chainClient.activeWalletAddress;
      print(
        userWallet == null
            ? '[MessagesNotifier] ⚠️ No wallet address available for username refresh'
            : '[MessagesNotifier] 🔍 Checking for username changes for contacts of $userWallet  ',
      );
      if (userWallet == null) return;

      final indexerClient = ref.read(indexerClientProvider);
      final userCache = ref.read(userCacheProvider);
      final contactWallets = await _messageCache.getContactWallets(userWallet);

      if (contactWallets.isEmpty) return;

      bool anyUpdated = false;

      print(
        '[MessagesNotifier] 🔍 Checking usernames for ${contactWallets.length} contacts',
      );

      for (final wallet in contactWallets) {
        try {
          final result = await indexerClient.getUserByOwner(wallet);
          if (result is! IndexerSuccess<IndexerUserLookup>) {
            // Contact not registered on indexer — normal for new users
            print('[MessagesNotifier] 👤 $wallet: not on indexer (skipped)');
            continue;
          }

          final freshUsername = result.data.username;
          final cached = await userCache.getCachedContact(wallet);
          final cachedUsername = cached?.username;

          print(
            '[MessagesNotifier] 👤 $wallet: indexer="$freshUsername", cached="$cachedUsername"',
          );

          // Skip if username hasn't changed
          if (freshUsername == cachedUsername) {
            continue;
          }

          print(
            '[MessagesNotifier] 🔄 Username changed for $wallet: '
            '"$cachedUsername" → "$freshUsername"',
          );

          // Update messages table
          await _messageCache.updateContactUsername(wallet, freshUsername);

          // Update contacts cache
          if (cached != null) {
            await userCache.cacheContact(
              cached.copyWith(
                username: freshUsername,
                displayName: freshUsername,
              ),
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
      }
    } catch (e) {
      print('[MessagesNotifier] ⚠️ Username refresh failed: $e');
    }
  }
}

final messagesNotifierProvider =
    AsyncNotifierProvider<MessagesNotifier, List<ConversationPreview>>(
      MessagesNotifier.new,
    );

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:sealed_app/chain/algorand_chain_client.dart';
import 'package:sealed_app/chain/chain_client.dart';

import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/models/alias_chat.dart';
import 'package:sealed_app/models/conversation.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/providers/keys_provider.dart';
import 'package:sealed_app/providers/message_provider.dart';
import 'package:sealed_app/remote/indexer_client.dart';
import 'package:sealed_app/remote/ohttp/algo_ohttp_interceptor.dart';
import 'package:sealed_app/remote/ohttp/indexer_ohttp_interceptor.dart';
import 'package:sealed_app/services/alias_chat_service.dart';
import 'package:sealed_app/services/indexer_service.dart';
import 'package:sealed_app/services/message_service.dart';
import 'package:sealed_app/services/notification_service.dart';
import 'package:sealed_app/services/user_service.dart';
import 'package:sealed_app/services/faucet_service.dart';

/// In-app TestNet faucet — sends 1 ALGO to the user's wallet, 24h cooldown.
final faucetServiceProvider = Provider<FaucetService>((ref) => FaucetService());

final chainClientProvider = FutureProvider<ChainClient>((ref) async {
  if (PRIMARY_CHAIN == 'algorand') {
    final wallet = await ref.watch(algorandWalletProvider.future);
    final keyService = await ref.watch(keyServiceProvider.future);

    // Dio with OHTTP interceptor only — algod traffic flows through the
    // Algorand Foundation OHTTP gateway. Tor SOCKS transport removed.
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );

    dio.interceptors.add(AlgoOhttpInterceptor());

    return AlgorandChainClient(
      wallet: wallet,
      keyService: keyService,
      dio: dio,
    );
  } else {
    throw UnsupportedError('Unsupported chain: $PRIMARY_CHAIN');
  }
});

// ============================================================================
// USER SERVICE
// ============================================================================

final userServiceProvider = FutureProvider<UserService>((ref) async {
  print('🔧 userServiceProvider: Starting...');
  final chainClient = await ref.watch(chainClientProvider.future);
  print('🔧 userServiceProvider: chainClient ready');
  final keyService = await ref.watch(keyServiceProvider.future);
  print('🔧 userServiceProvider: keyService ready');

  return UserService(
    chainClient: chainClient,
    keyService: keyService,
    userCache: ref.watch(userCacheProvider),
    indexerClient: ref.watch(indexerClientProvider),
  );
});

// ============================================================================
// MESSAGE SERVICE
// ============================================================================

final messageServiceProvider = FutureProvider<MessageService>((ref) async {
  final chainClient = await ref.watch(chainClientProvider.future);
  final keyService = await ref.watch(keyServiceProvider.future);
  final userService = await ref.watch(userServiceProvider.future);
  final indexerService = await ref.watch(indexerServiceProvider.future);

  return MessageService(
    chainClient: chainClient,
    syncState: ref.watch(syncStateProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
    userService: userService,
    userCache: ref.watch(userCacheProvider),
    keyService: keyService,
    messageCache: ref.watch(messageCacheProvider),
    indexerService: indexerService,
    aliasChatCache: ref.watch(aliasChatCacheProvider),
    aliasKeyService: ref.watch(aliasKeyServiceProvider),
  );
});

// ============================================================================
// INDEXER SERVICE
// ============================================================================

/// Indexer URL - configure based on environment. Default points at the
/// Tailscale Funnel hostname of the Pi gateway; OHTTP encapsulates the request.
const _indexerBaseUrl = String.fromEnvironment(
  'INDEXER_BASE_URL',
  defaultValue: 'https://sealed-pi.taile8602b.ts.net',
);

/// IndexerClient provider (HTTP client for indexer API). Reaches the Pi
/// indexer via OHTTP — relay sees ciphertext+IP, gateway sees plaintext+relay-IP.
final indexerClientProvider = Provider<IndexerClient>((ref) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  // Pi OHTTP interceptor — encapsulates outgoing requests to the
  // Oblivious.Network relay slug pinned to the Pi gateway. The relay sees
  // ciphertext + client IP; the Pi gateway sees plaintext + relay IP.
  dio.interceptors.add(IndexerOhttpInterceptor());

  return IndexerClient(baseUrl: _indexerBaseUrl, dioClient: dio);
});

/// IndexerService provider - manages view key registration, push tokens, WebSocket
final indexerServiceProvider = FutureProvider<IndexerService>((ref) async {
  final keyService = await ref.watch(keyServiceProvider.future);
  final chainWallet = await ref.watch(algorandWalletProvider.future);

  final service = IndexerService(
    indexerClient: ref.watch(indexerClientProvider),
    syncState: ref.watch(syncStateProvider),
    keyService: keyService,
    chainWallet: chainWallet,
  );

  // Indexer connection state is no longer derived from a persistent WebSocket;
  // it surfaces through the registration state and HTTP probe. UI consumers
  // that previously listened on connection status now read indexerStatusProvider
  // directly after registration.

  return service;
});

/// Initialize indexer connection (only if user has opted in via push or sync settings)
final indexerInitializerProvider = FutureProvider<void>((ref) async {
  // Check if user wants indexer-based features
  final settings = await ref.watch(appSettingsServiceProvider.future);
  final syncLayer = settings.preferredSyncLayer;
  // Indexer is only needed for non-blockchain sync methods.
  // Blockchain mode = fully direct, no indexer connection at all.

  final indexerService = await ref.watch(indexerServiceProvider.future);
  final messageService = await ref.watch(messageServiceProvider.future);

  // Update status to connecting
  ref.read(indexerStatusProvider.notifier).state = IndexerStatus.connecting;

  try {
    await indexerService.initializeWithIndexer();
    ref.read(indexerStatusProvider.notifier).state = IndexerStatus.connected;

    // Set callbacks BEFORE starting real-time sync to avoid race conditions
    // where messages arrive before callbacks are registered
    messageService.onNewMessageReceived = (message) {
      print(
        '[IndexerProvider] New message received from ${message.senderWallet}, refreshing UI...',
      );
      // Refresh the conversations list (chat list screen)
      ref.invalidate(messagesNotifierProvider);
      // Bump the refresh counter so conversationMessagesProvider re-evaluates
      ref.read(messageRefreshCounterProvider.notifier).state++;
    };

    // When an alias message is processed, refresh alias chat UI
    messageService.onAliasMessageReceived = () {
      print('[IndexerProvider] Alias message received, refreshing UI...');
      ref.read(messageRefreshCounterProvider.notifier).state++;
    };

    // Start real-time push sync so incoming messages are processed
    messageService.startRealtimeSync();
  } catch (e) {
    print('[IndexerProvider] Failed to initialize indexer: $e');
    ref.read(indexerStatusProvider.notifier).state = IndexerStatus.error;
    // Don't rethrow - indexer failure shouldn't block the app
  }
});

// ============================================================================
// DATA PROVIDERS (Read-only, reactive)
// ============================================================================

/// All conversations for the current user
final conversationsProvider = FutureProvider<List<ConversationPreview>>((
  ref,
) async {
  final keys = ref.watch(currentKeysProvider);
  if (keys == null) return [];

  final messageCache = ref.watch(messageCacheProvider);
  return messageCache.getConversations();
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

      final chainClient = await ref.watch(chainClientProvider.future);
      final myWallet = chainClient.activeWalletAddress;
      if (myWallet == null) return [];

      final messageCache = ref.watch(messageCacheProvider);
      return messageCache.getConversationMessages(myWallet, contactWallet);
    });

// ============================================================================
// ALIAS CHAT PROVIDERS
// ============================================================================

/// AliasChatService (requires async chain client)
final aliasChatServiceProvider = FutureProvider<AliasChatService>((ref) async {
  final chainClient = await ref.watch(chainClientProvider.future);
  if (chainClient is! AlgorandChainClient) {
    throw UnsupportedError('Alias chat is only supported on Algorand');
  }
  return AliasChatService(
    cache: ref.watch(aliasChatCacheProvider),
    aliasKeyService: ref.watch(aliasKeyServiceProvider),
    chainClient: chainClient,
    cryptoService: ref.watch(cryptoServiceProvider),
    indexerService: await ref.watch(indexerServiceProvider.future),
  );
});

/// Alias conversation previews for the unified chat list
final aliasConversationPreviewsProvider =
    FutureProvider<List<AliasConversationPreview>>((ref) async {
      // Watch refresh counter so alias list updates when messages arrive
      ref.watch(messageRefreshCounterProvider);
      final cache = ref.watch(aliasChatCacheProvider);
      return cache.getAliasConversationPreviews();
    });

/// Invite-level status probe — keyed by inviteSecret.
final aliasInviteStatusProvider =
    FutureProvider.family<AliasChannelStatus, String>((
      ref,
      inviteSecret,
    ) async {
      // Shortcut: if local previews already know the answer, skip network
      final previews = ref.watch(aliasConversationPreviewsProvider).value ?? [];
      final match = previews
          .where((p) => p.inviteSecret == inviteSecret)
          .firstOrNull;
      if (match != null) {
        if (match.status == AliasChannelStatus.active) {
          return AliasChannelStatus.active;
        }
        if (match.status == AliasChannelStatus.deleted) {
          return AliasChannelStatus.deleted;
        }
        if (match.status == AliasChannelStatus.pending) {
          return AliasChannelStatus.pending;
        }
      }

      final service = await ref.read(aliasChatServiceProvider.future);
      return service.probeInviteStatus(inviteSecret: inviteSecret);
    });

/// Alias messages for a specific channel
final aliasMessagesProvider = FutureProvider.family<List<AliasMessage>, String>(
  (ref, inviteSecret) async {
    ref.watch(messageRefreshCounterProvider);
    final cache = ref.watch(aliasChatCacheProvider);
    return cache.getAliasMessages(inviteSecret);
  },
);

/// Whether the invite card for a given alias channel has been dismissed.
/// Persisted in SQLite so it survives app restarts.
final aliasInviteDismissedProvider = FutureProvider.family<bool, String>((
  ref,
  inviteSecret,
) async {
  ref.watch(messageRefreshCounterProvider);
  final cache = ref.watch(aliasChatCacheProvider);
  return cache.isInviteDismissed(inviteSecret);
});

// ============================================================================
// STATUS PROVIDERS
// ============================================================================

enum SyncStatus { idle, syncing, error }

enum IndexerStatus { disconnected, connecting, connected, error }

final syncStatusProvider = StateProvider<SyncStatus>((ref) => SyncStatus.idle);

final indexerStatusProvider = StateProvider<IndexerStatus>(
  (ref) => IndexerStatus.disconnected,
);

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
    runBoundedSync: () => messageService.syncMessages(
      preferredLayer: SyncLayer.blockchain,
      fullSync: false,
    ),
  );
});

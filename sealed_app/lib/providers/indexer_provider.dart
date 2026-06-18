import 'package:dio/dio.dart';
import 'package:sealed_app/core/log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;

import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/features/messaging/message_service.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/infra/network/indexer_service.dart';
import 'package:sealed_app/infra/network/ohttp/ohttp_interceptor.dart';
import 'package:sealed_app/providers/message_provider.dart';

// ============================================================================
// INDEXER SERVICE
// ============================================================================

/// Indexer URL - configure based on environment. Defaults to the VPS gateway
/// (gw.sealed.channel, Caddy-fronted); OHTTP encapsulates the request. Override
/// via --dart-define=INDEXER_BASE_URL for smoke tests. Keep in sync with
/// INDEXER_BASE_URL in core/constants.dart.
const _indexerBaseUrl = String.fromEnvironment(
  'INDEXER_BASE_URL',
  defaultValue: 'https://gw.sealed.channel',
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
  dio.interceptors.add(OhttpInterceptor.indexer());

  return IndexerClient(baseUrl: _indexerBaseUrl, dioClient: dio);
});

/// IndexerService provider - manages view key registration, push tokens, WebSocket
final indexerServiceProvider = FutureProvider<IndexerService>((ref) async {
  final keyService = await ref.watch(keyServiceProvider.future);
  final chainWallet = await ref.watch(algorandWalletProvider.future);
  final settings = await ref.watch(appSettingsServiceProvider.future);

  final service = IndexerService(
    indexerClient: ref.watch(indexerClientProvider),
    syncState: ref.watch(syncStateProvider),
    keyService: keyService,
    chainWallet: chainWallet,
    aliasKeyService: ref.watch(aliasKeyServiceProvider),
    appSettings: settings,
  );

  // Indexer connection state is no longer derived from a persistent WebSocket;
  // it surfaces through the registration state and HTTP probe. UI consumers
  // that previously listened on connection status now read indexerStatusProvider
  // directly after registration.

  return service;
});

/// Initialize indexer connection (only if user has opted in via push or sync settings)
final indexerInitializerProvider = FutureProvider<void>((ref) async {
  await ref.watch(appSettingsServiceProvider.future);
  final indexerService = await ref.watch(indexerServiceProvider.future);
  final messageService = await ref.watch(messageServiceProvider.future);

  ref.read(indexerStatusProvider.notifier).state = IndexerStatus.connecting;
  try {
    await indexerService.initializeWithIndexer();
    _wireIndexerCallbacks(ref, indexerService, messageService);
    ref.read(indexerStatusProvider.notifier).state = IndexerStatus.connected;
  } catch (e) {
    Log.d('[IndexerProvider] Failed to initialize indexer: $e');
    ref.read(indexerStatusProvider.notifier).state = IndexerStatus.error;
    // Don't rethrow - indexer failure shouldn't block the app
  }
});

/// Wires MessageService + IndexerService callbacks into Riverpod refresh
/// signals. Pure provider-layer glue — kept out of services so neither has
/// to know about Riverpod or the refresh counter.
void _wireIndexerCallbacks(
  Ref ref,
  IndexerService indexerService,
  MessageService messageService,
) {
  void bumpRefresh() {
    ref.read(messageRefreshCounterProvider.notifier).state++;
  }

  // New direct message → invalidate conversation list + bump per-conversation counter.
  messageService.onNewMessageReceived = (message) {
    Log.d(
      '[IndexerProvider] New message received from ${message.senderWallet}, refreshing UI...',
    );
    ref.invalidate(messagesNotifierProvider);
    bumpRefresh();
  };

  // Alias delta lands in contact_messages table; only counter bump needed.
  messageService.onAliasMessageReceived = () {
    Log.d('[IndexerProvider] New alias message received, refreshing UI...');
    bumpRefresh();
  };

  // Silent push wake → chain scan, then refresh.
  indexerService.onPushWakeup = () async {
    await messageService.onPushWakeup();
    bumpRefresh();
  };
}

// ============================================================================
// STATUS
// ============================================================================

enum IndexerStatus { disconnected, connecting, connected, error }

final indexerStatusProvider = StateProvider<IndexerStatus>(
  (ref) => IndexerStatus.disconnected,
);

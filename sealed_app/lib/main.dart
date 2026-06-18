import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sealed_app/app.dart';
import 'package:sealed_app/core/service_locator.dart';
import 'package:sealed_app/providers/indexer_provider.dart';
import 'package:sealed_app/providers/wallet_provider.dart';
import 'package:sealed_app/providers/search_provider.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/features/notifications/notification_service.dart';
import 'package:sealed_app/features/search/search_scope.dart';
import 'package:sealed_app/features/search/username_scope.dart';
import 'package:sealed_app/features/search/search_service.dart';
import 'package:sealed_app/features/messaging/background_wake_runner.dart';
import 'package:sealed_app/features/messaging/wake_nonce_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background FCM handler — runs in a separate Dart isolate (no Riverpod, no
/// DEK: the DB is PIN-gated and off-limits here).
///   1. Re-initialise Firebase (required in background isolate).
///   2. Read only `data['n']` (wake-up nonce). Ignore all other fields.
///   3. Persist nonce to WakeNonceQueue (loss-recovery backstop).
///   4. Push pre-sync (ADR 0003): fetch + PIN-free tag-check + block-mirror gate
///      + stage to WakeStageStore, then post a generic notification. NEVER opens
///      the DEK DB or advances the cursor; the main isolate decrypts on unlock.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage msg) async {
  await Firebase.initializeApp();

  // Read ONLY the nonce. Any other field is intentionally ignored.
  final dynamic rawNonce = msg.data['n'];
  final String? nonce = rawNonce is String ? rawNonce : null;

  final prefs = await SharedPreferences.getInstance();
  final queue = WakeNonceQueue(prefs);
  await queue.enqueue(nonce, DateTime.now());

  // Push pre-sync: fetch recent, match (PIN-free), drop blocked, stage, and post
  // the generic notification for a non-blocked message. Best-effort; the nonce
  // queue above is the loss-recovery backstop if this can't complete in-window.
  try {
    await runBackgroundWakeSync();
  } catch (e) {
    debugPrint('[BackgroundWake] run failed: $e');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Crypto runs through the pure-Dart `cryptography` backend. The native
  // `cryptography_flutter` plugin was removed: it added ~5MB (Tink via
  // androidx.security-crypto) and its native HMAC rejects empty HKDF salts
  // (SecretKeySpec "Empty key"), crashing key derivation. If off-main-isolate
  // crypto is ever needed for sync perf, run the pure-Dart ops in an Isolate
  // rather than reintroducing the native delegate.

  // Lock to vertical (portrait) orientation only — no landscape rotation.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Firebase init for Android FCM push delivery (UnifiedPush is deprecated).
  // iOS continues to use APNs; Firebase is benign on iOS without an APNs cert.
  await Firebase.initializeApp();

  // Register background handler before runApp — FCM SDK requirement.
  // Must be a top-level function annotated @pragma('vm:entry-point').
  FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

  // Android foreground push: drive bounded sync via NotificationService.
  // Reads only data['n'] — no notification/alert fields cross the boundary.
  // ignore: discarded_futures
  FirebaseMessaging.onMessage.listen(NotificationService().handleFcmMessage);

  // ignore: discarded_futures
  NotificationService().initialize();

  runApp(
    ProviderScope(
      overrides: [
        // Wire searchServiceProvider with the real IndexerService + contact repo.
        // The provider declaration in search_provider.dart is a throw-stub so
        // that test files can override it without pulling in app_providers.dartR
        // (which has heavy transitive imports).
        searchServiceProvider.overrideWith((ref) async {
          final indexer = await ref.watch(indexerServiceProvider.future);
          final contacts = ref.watch(contactRepositoryProvider);
          return SearchService(
            contacts: contacts,
            scopes: <String, SearchScope>{
              'username': UsernameSearchScope(
                _IndexerUsernameSearcher(indexer),
              ),
            },
            selfWalletGetter: () => ref.read(walletAddressProvider),
          );
        }),
      ],
      child: const SealedApp(),
    ),
  );

  // Warm the haptic platform channel on the first frame. The FIRST
  // HapticFeedback call pays a one-time cost — MethodChannel setup + Android
  // Vibrator-service binder warmup + HAL wakeup — which otherwise lands on the
  // user's first PIN-keypad tap and reads as input lag (smooth thereafter).
  // Doing it once at launch warms the channel for every haptic surface; the
  // single selectionClick is imperceptible behind app start.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // ignore: discarded_futures
    HapticFeedback.selectionClick();
  });
}

/// Adapter: bridge IndexerService → narrow UsernameSearcher interface.
/// Typed `dynamic` to avoid analysis-time coupling to the rest of
/// IndexerService while it has unrelated compile errors on this branch.
class _IndexerUsernameSearcher implements UsernameSearcher {
  final dynamic _indexer;
  const _IndexerUsernameSearcher(this._indexer);

  @override
  Future<IndexerResult<UsernameSearchResult>> searchUsers(
    String query, {
    int limit = 20,
  }) {
    return _indexer.searchUsers(query, limit: limit)
        as Future<IndexerResult<UsernameSearchResult>>;
  }
}

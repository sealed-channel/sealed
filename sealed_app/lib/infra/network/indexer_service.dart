/// Real-time messaging infrastructure and push notification service.
/// Manages WebSocket connections, Firebase Cloud Messaging tokens,
/// and encrypted communication with the indexer for instant message delivery.
library;

import 'dart:async';
import 'package:sealed_app/core/log.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
// FCM is back for Android push delivery (UnifiedPush is deprecated upstream).
// iOS continues to use APNs tokens registered via the platform AppDelegate.
import 'package:sealed_app/infra/chain/wallet_interface.dart';
import 'package:sealed_app/infra/local/repositories/sync_repository.dart';
import 'package:sealed_app/infra/network/indexer_client.dart';
import 'package:sealed_app/infra/crypto/key_service.dart';
import 'package:sealed_app/features/messaging/alias/alias_key_service.dart';
import 'package:sealed_app/features/settings/app_settings_service.dart';

// =============================================================================
// EXCEPTIONS
// =============================================================================

class IndexerServiceException implements Exception {
  final String message;
  final String? code;

  IndexerServiceException(this.message, {this.code});

  @override
  String toString() =>
      'IndexerServiceException: $message${code != null ? ' ($code)' : ''}';
}

class IndexerRegistrationException extends IndexerServiceException {
  IndexerRegistrationException(super.message)
    : super(code: 'REGISTRATION_ERROR');
}

class IndexerConnectionException extends IndexerServiceException {
  IndexerConnectionException(super.message) : super(code: 'CONNECTION_ERROR');
}

// =============================================================================
// PUSH EVENT TYPES
// =============================================================================

/// New message notification data, mirroring the indexer's push payload
/// which itself mirrors the AlgoKit Subscriber `app-calls` shape.
///
/// Wire shape (from `sealed-indexer/src/notifications/push-fanout.ts`):
/// ```
/// { ciphertext: <base64>, messageId: <string>, timestamp: <int>,
///   appId: <stringified bigint>?, txId: <string>?,
///   confirmedRound: <stringified bigint>?, sender: <string>? }
/// ```
class NewMessageNotification {
  /// Indexer-assigned message id (e.g. `msg-<epoch>` for the mock,
  /// or the Algorand txId for the real watcher).
  final String messageId;

  /// Unix epoch (ms) when the indexer observed/emitted the event.
  final int timestamp;

  /// Encrypted message ciphertext, decoded from base64. Opaque to the
  /// indexer; the client decrypts locally.
  final Uint8List ciphertext;

  /// AlgoKit Subscriber fields (optional — populated by the real watcher
  /// and the mock; absent on legacy/unknown events).
  final BigInt? appId;
  final String? txId;
  final BigInt? confirmedRound;
  final String? sender;

  NewMessageNotification({
    required this.messageId,
    required this.timestamp,
    required this.ciphertext,
    this.appId,
    this.txId,
    this.confirmedRound,
    this.sender,
  });

  factory NewMessageNotification.fromJson(Map<String, dynamic> json) {
    final ciphertextB64 = json['ciphertext'] as String?;
    final ciphertext = ciphertextB64 != null
        ? Uint8List.fromList(base64.decode(ciphertextB64))
        : Uint8List(0);

    BigInt? parseBigInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return BigInt.from(v);
      if (v is String) return BigInt.tryParse(v);
      return null;
    }

    int parseTimestamp(dynamic v) {
      if (v is int) return v;
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    return NewMessageNotification(
      messageId: json['messageId']?.toString() ?? '',
      timestamp: parseTimestamp(json['timestamp']),
      ciphertext: ciphertext,
      appId: parseBigInt(json['appId']),
      txId: json['txId'] as String?,
      confirmedRound: parseBigInt(json['confirmedRound']),
      sender: json['sender'] as String?,
    );
  }

  /// Stable dedup key. Prefer the on-chain txId; fall back to indexer
  /// messageId so dev-mode events (mock) are still de-duplicated.
  String get dedupKey => txId ?? messageId;
}

// =============================================================================
// REGISTRATION STATE
// =============================================================================

enum IndexerRegistrationStatus { unregistered, registering, registered, failed }

class IndexerRegistrationState {
  final IndexerRegistrationStatus status;
  final String? userId;
  final String? viewKeyHash;
  final DateTime? registeredAt;
  final String? error;

  const IndexerRegistrationState({
    this.status = IndexerRegistrationStatus.unregistered,
    this.userId,
    this.viewKeyHash,
    this.registeredAt,
    this.error,
  });

  IndexerRegistrationState copyWith({
    IndexerRegistrationStatus? status,
    String? userId,
    String? viewKeyHash,
    DateTime? registeredAt,
    String? error,
  }) {
    return IndexerRegistrationState(
      status: status ?? this.status,
      userId: userId ?? this.userId,
      viewKeyHash: viewKeyHash ?? this.viewKeyHash,
      registeredAt: registeredAt ?? this.registeredAt,
      error: error,
    );
  }

  bool get isRegistered => status == IndexerRegistrationStatus.registered;
}

// =============================================================================
// AUTH CREDENTIALS
// =============================================================================

class IndexerAuthCredentials {
  final int timestamp;
  final String nonce;
  final String signature;
  final String walletAddress;

  const IndexerAuthCredentials({
    required this.timestamp,
    required this.nonce,
    required this.signature,
    required this.walletAddress,
  });
}

// =============================================================================
// PUSH TOKEN VERIFICATION
// =============================================================================

enum PushTokenStatus { synced, missing, reRegistered, error }

class PushTokenVerification {
  final PushTokenStatus status;
  final String message;

  PushTokenVerification({required this.status, required this.message});

  bool get isSynced => status == PushTokenStatus.synced;
  bool get wasFixed => status == PushTokenStatus.reRegistered;
}

// =============================================================================
// INDEXER SERVICE
// =============================================================================

class IndexerService {
  final IndexerClient indexerClient;
  final KeyService keyService;

  final ChainWallet? chainWallet;
  final SyncRepository syncState;

  /// Optional alias key service used to enumerate per-alias scan_privs when
  /// (un)registering alias push rows. Wired in via the IndexerService
  /// provider; tests can leave it null when the alias surface isn't under
  /// test.
  final AliasKeyService? aliasKeyService;

  /// Optional settings service used to read the per-alias opt-in flags. The
  /// boot reconciler / settings cascade pass this in so unregister logic can
  /// inspect which aliases were toggled on.
  final AppSettingsService? appSettings;

  // State
  IndexerRegistrationState _registrationState =
      const IndexerRegistrationState();

  // ignore: unused_field
  final bool _pushTokenRegistered =
      false; // Track if push was registered this session
  // ignore: unused_field
  StreamSubscription<String>? _tokenRefreshSub;

  // Callbacks
  void Function(IndexerRegistrationState)? onRegistrationStateChanged;

  /// Optional override for the platform push token used by alias-push
  /// (un)register paths. Production code leaves this null and the real
  /// FCM/APNs lookup runs. Tests set it to a stub token so the alias methods
  /// can exercise the indexer-client path on host runners without a real
  /// push subsystem.
  @visibleForTesting
  String? debugPlatformTokenOverride;

  /// Optional override for the platform string ("ios" / "android"). Same
  /// motivation as [debugPlatformTokenOverride].
  @visibleForTesting
  String? debugPlatformOverride;

  IndexerService({
    required this.indexerClient,
    required this.syncState,
    required this.keyService,
    this.chainWallet,
    this.aliasKeyService,
    this.appSettings,
  });

  // ===========================================================================
  // GETTERS
  // ===========================================================================

  IndexerRegistrationState get registrationState => _registrationState;

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  /// Initialize the indexer service: load keys and mark registration state.
  ///
  /// The `/register-view-key` endpoint was removed during the indexer cutover.
  /// State is set locally so downstream callers (e.g. [registerTargetedPush])
  /// can gate on `registrationState.isRegistered`.
  Future<void> initializeWithIndexer() async {
    Log.d('[IndexerService] 🚀 Initializing...');
    try {
      final keys = await keyService.loadKeys();
      if (keys == null) {
        throw IndexerRegistrationException('Keys not found in storage');
      }
      final viewKeyHash = sha256.convert(keys.viewPrivateKey).toString();
      _updateRegistrationState(
        IndexerRegistrationState(
          status: IndexerRegistrationStatus.registered,
          viewKeyHash: viewKeyHash,
          registeredAt: DateTime.now(),
        ),
      );
      Log.d('[IndexerService] ✅ Initialization complete');
    } catch (e) {
      _updateRegistrationState(
        _registrationState.copyWith(
          status: IndexerRegistrationStatus.failed,
          error: e.toString(),
        ),
      );
      Log.d('[IndexerService] ❌ Initialization failed: $e');
      rethrow;
    }
  }

  /// Get platform push token.
  /// - Android: FCM registration token via FirebaseMessaging.
  /// - iOS: APNs device token (hex) via the `sealed/apns_token` MethodChannel
  ///   wired in `ios/Runner/AppDelegate.swift`. Polls briefly because APNs
  ///   may complete registration after the app finishes launching.
  Future<String?> _getPlatformToken() async {
    if (Platform.isAndroid) {
      try {
        final messaging = FirebaseMessaging.instance;
        await messaging.requestPermission();
        final token = await messaging.getToken();
        if (token == null || token.isEmpty) {
          Log.d('[IndexerService] ⚠️ FCM getToken returned null/empty');
          return null;
        }
        return token;
      } catch (e) {
        Log.d('[IndexerService] ❌ FCM getToken failed: $e');
        return null;
      }
    }
    // iOS: pull the cached APNs token from AppDelegate over a method channel.
    // No Firebase / FCM dependency on this path.
    if (Platform.isIOS) {
      const channel = MethodChannel('sealed/apns_token');
      // Poll for up to ~6s. iOS typically delivers the token within a few
      // hundred ms of `registerForRemoteNotifications`, but the first launch
      // after install can be slower.
      const maxAttempts = 20;
      const delay = Duration(milliseconds: 300);
      for (var i = 0; i < maxAttempts; i++) {
        try {
          final token = await channel.invokeMethod<String>('getApnsToken');
          if (token != null && token.isNotEmpty) {
            if (kDebugMode) {
              // Full token printed only in debug builds. Copy this value into
              // sealed-indexer/scripts/send_apns_test.ts to send a test
              // push directly to this device, bypassing the chain/fanout path.
              Log.d('[IndexerService] 🔑 APNS_TOKEN_DEBUG=$token');
            }
            return token;
          }
        } on PlatformException catch (e) {
          Log.d('[IndexerService] ❌ APNs channel error: ${e.message}');
          return null;
        } on MissingPluginException catch (_) {
          // Channel not yet registered (engine still initializing). Retry.
        }
        if (i + 1 < maxAttempts) {
          await Future<void>.delayed(delay);
        }
      }
      // Timed out. Surface the registration error if iOS reported one.
      try {
        final err = await channel.invokeMethod<String>('getLastApnsError');
        if (err != null && err.isNotEmpty) {
          Log.d('[IndexerService] ❌ APNs registration error: $err');
        } else {
          Log.d(
            '[IndexerService] ⚠️ APNs token unavailable after polling '
            '(simulator? push entitlement missing? offline?)',
          );
        }
      } catch (_) {
        // Channel still not up — already logged above.
      }
      return null;
    }
    // Other platforms (macOS/web/desktop) don't have a push token here.
    return null;
  }

  /// Register the device with the **Push Notifications** registry (opt-in).
  ///
  /// This hands `view_priv` to the indexer; only call after the user has
  /// accepted the dual-disclosure dialog (see settings_screen.dart). Returns
  /// `true` only on indexer 2xx + `{ok: true}`; the caller is responsible for
  /// flipping the persisted setting bit.
  Future<bool> registerTargetedPush() async {
    Log.d('[IndexerService] ➡️ registerTargetedPush() entry');
    final viewKeyBytes = await keyService.getViewKey();
    if (viewKeyBytes.length != 32) {
      Log.d('[IndexerService] ❌ Invalid view key for Push Notifications');
      return false;
    }
    Log.d('[IndexerService] ✅ view key loaded len=${viewKeyBytes.length}');
    final platformToken = await _getPlatformToken();
    if (platformToken == null) {
      Log.d('[IndexerService] ⚠️ No platform token for Push Notifications');
      return false;
    }
    final platform = Platform.isIOS ? 'ios' : 'android';
    final tokenPrefix = platformToken.length >= 6
        ? platformToken.substring(0, 6)
        : platformToken;
    Log.d(
      '[IndexerService] ✅ platform=$platform tokenLen=${platformToken.length} tokenPrefix=$tokenPrefix',
    );

    // Wallet enables KEM first-contact push (indexer matches the handshake
    // discovery tag for new conversations). Best-effort: if the address can't
    // be loaded, register without it — steady-state push still works.
    String? walletAddress;
    try {
      walletAddress = await keyService.getWalletAddress();
    } catch (e) {
      Log.d('[IndexerService] ⚠️ wallet address unavailable for KEM push: $e');
    }

    Log.d('[IndexerService] ➡️ calling registerPushToken');
    final result = await indexerClient.registerPushToken(
      viewKey: viewKeyBytes,
      token: platformToken,
      platform: platform,
      wallet: walletAddress,
    );
    return switch (result) {
      IndexerSuccess(data: final r) => () {
        Log.d(
          '[IndexerService] ✅ targeted-push register result success=${r.success}',
        );
        return r.success;
      }(),
      IndexerFailure(error: final e) => () {
        Log.d('[IndexerService] ❌ targeted-push register failed: $e');
        return false;
      }(),
    };
  }

  /// Unregister from the Push Notifications registry; falls back to blinded fanout.
  Future<bool> unregisterTargetedPush() async {
    Log.d('[IndexerService] ➡️ unregisterTargetedPush() entry');
    final viewKeyBytes = await keyService.getViewKey();
    if (viewKeyBytes.length != 32) {
      Log.d('[IndexerService] ❌ Invalid view key for unregister');
      return false;
    }
    Log.d('[IndexerService] ✅ view key loaded len=${viewKeyBytes.length}');
    Log.d('[IndexerService] ➡️ calling unregisterPushToken');
    final result = await indexerClient.unregisterPushToken(
      viewKey: viewKeyBytes,
    );
    return switch (result) {
      IndexerSuccess(data: final r) => () {
        Log.d(
          '[IndexerService] ✅ targeted-push unregister result success=${r.success}',
        );
        return r.success;
      }(),
      IndexerFailure(error: final e) => () {
        Log.d('[IndexerService] ❌ targeted-push unregister failed: $e');
        return false;
      }(),
    };
  }

  // ===========================================================================
  // PER-ALIAS PUSH (privacy opt-in, per alias contact)
  // ===========================================================================
  //
  // Outgoing alias-chat messages tag the on-chain payload with
  //   recipient_tag = HMAC(X25519(eph_sk, peerScanPub_alias),
  //                        "sealed-recipient-tag-v1")
  // The peer's alias scan_priv (`myX25519ScanSk` on the [AliasContact] row) is
  // the only key that can re-derive this tag on receipt. The main wallet
  // view_priv we register via [registerTargetedPush] therefore does NOT match
  // alias messages — fanout will not dispatch a push for them.
  //
  // To deliver push for alias chats we register the alias scan_priv as an
  // additional row in the indexer's `targeted_push_tokens` table, sharing the
  // same device push token (enc_token) but with a distinct blinded_id +
  // view_priv. We reuse [IndexerClient.registerPushToken] / .unregisterPushToken
  // — no new endpoint, no schema change.
  //
  // 8-char `blinded_id` prefix appears in logs only; raw scan_priv bytes are
  // never logged.
  // ---------------------------------------------------------------------------

  String _blindedIdPrefixFor(Uint8List viewKey) {
    // Mirrors the indexer's `blinded_id = HMAC(view_priv, "push-v1")`
    // derivation so logs use the same 8-char prefix the indexer prints.
    final h = Hmac(sha256, viewKey).convert(utf8.encode('push-v1'));
    return h.toString().substring(0, 8);
  }

  /// Register one alias contact's scan_priv as an additional view-key row in
  /// the indexer push registry. Shares the device push token (enc_token) with
  /// the main wallet's row but has its own blinded_id.
  ///
  /// Returns true on indexer 2xx + `{ok: true}`. The caller is responsible
  /// for flipping the per-alias persisted flag.
  Future<bool> registerAliasViewKey({required Uint8List aliasScanPriv}) async {
    if (aliasScanPriv.length != 32) {
      Log.d('[IndexerService] ❌ alias register: scan_priv length != 32');
      return false;
    }
    final platformToken =
        debugPlatformTokenOverride ?? await _getPlatformToken();
    if (platformToken == null) {
      Log.d('[IndexerService] ⚠️ alias register: no platform token');
      return false;
    }
    final platform =
        debugPlatformOverride ?? (Platform.isIOS ? 'ios' : 'android');
    final bidPrefix = _blindedIdPrefixFor(aliasScanPriv);
    Log.d(
      '[IndexerService] ➡️ registerAliasViewKey bid=$bidPrefix platform=$platform',
    );
    final result = await indexerClient.registerPushToken(
      viewKey: aliasScanPriv,
      token: platformToken,
      platform: platform,
    );
    return switch (result) {
      IndexerSuccess(data: final r) => () {
        Log.d(
          '[IndexerService] ✅ alias register bid=$bidPrefix success=${r.success}',
        );
        return r.success;
      }(),
      IndexerFailure(error: final e) => () {
        Log.d('[IndexerService] ❌ alias register bid=$bidPrefix failed: $e');
        return false;
      }(),
    };
  }

  /// Unregister one alias contact's scan_priv from the indexer push registry.
  Future<bool> unregisterAliasViewKey({
    required Uint8List aliasScanPriv,
  }) async {
    if (aliasScanPriv.length != 32) return false;
    final bidPrefix = _blindedIdPrefixFor(aliasScanPriv);
    Log.d('[IndexerService] ➡️ unregisterAliasViewKey bid=$bidPrefix');
    final result = await indexerClient.unregisterPushToken(
      viewKey: aliasScanPriv,
    );
    return switch (result) {
      IndexerSuccess(data: final r) => () {
        Log.d(
          '[IndexerService] ✅ alias unregister bid=$bidPrefix success=${r.success}',
        );
        return r.success;
      }(),
      IndexerFailure(error: final e) => () {
        Log.d('[IndexerService] ❌ alias unregister bid=$bidPrefix failed: $e');
        return false;
      }(),
    };
  }

  /// Register every alias contact currently opted in via the per-alias push
  /// flag. Reads enabled contactIds from [appSettings] and pulls each
  /// scan_priv via [aliasKeyService]. Best-effort: failures are logged and
  /// the loop continues.
  ///
  /// No-op when either collaborator is null (tests / partial-wiring paths).
  Future<void> registerEnabledAliasViewKeys() async {
    final settings = appSettings;
    final keys = aliasKeyService;
    if (settings == null || keys == null) {
      Log.d(
        '[IndexerService] registerEnabledAliasViewKeys: settings/aliasKeyService not wired, skipping',
      );
      return;
    }
    if (!settings.targetedPushEnabled) {
      // Global push gates alias push — no point registering alias rows if the
      // device's main push channel is off (the indexer fanout would still
      // dispatch, but the device wouldn't be allowed to receive).
      Log.d(
        '[IndexerService] registerEnabledAliasViewKeys: global push off, skipping',
      );
      return;
    }
    final enabled = settings.listEnabledAliasContactIds();
    Log.d(
      '[IndexerService] registerEnabledAliasViewKeys: ${enabled.length} alias(es) enabled',
    );
    for (final contactId in enabled) {
      try {
        final scanPriv = await keys.loadAliasScanPrivForContact(contactId);
        if (scanPriv == null) {
          Log.d(
            '[IndexerService] ⚠️ alias register: scan_priv missing for contact=$contactId',
          );
          continue;
        }
        await registerAliasViewKey(aliasScanPriv: scanPriv);
      } catch (e) {
        Log.d('[IndexerService] ⚠️ alias register fail contact=$contactId: $e');
      }
    }
  }

  /// Auto-enable alias push for [contactId] when the device's global push is
  /// already ON. Called on alias create/accept so a freshly established alias
  /// chat receives push without a manual per-contact toggle.
  ///
  /// Gated on `targetedPushEnabled` (same gate as [registerEnabledAliasViewKeys]):
  /// if global push is off, does nothing — the user opts into push globally
  /// first. No-op when collaborators aren't wired. Best-effort: failures only
  /// log and never block the alias handshake.
  Future<void> enableAliasPushIfGlobalOn(String contactId) async {
    final settings = appSettings;
    final keys = aliasKeyService;
    if (settings == null || keys == null) return;
    if (!settings.targetedPushEnabled) {
      Log.d(
        '[IndexerService] alias auto-push: global push off, skipping contact=$contactId',
      );
      return;
    }
    try {
      final scanPriv = await keys.loadAliasScanPrivForContact(contactId);
      if (scanPriv == null) {
        Log.d(
          '[IndexerService] ⚠️ alias auto-push: scan_priv missing for contact=$contactId',
        );
        return;
      }
      final ok = await registerAliasViewKey(aliasScanPriv: scanPriv);
      if (ok) {
        await settings.setAliasPushEnabled(contactId, true);
        Log.d('[IndexerService] ✅ alias auto-push enabled contact=$contactId');
      }
    } catch (e) {
      Log.d('[IndexerService] ⚠️ alias auto-push fail contact=$contactId: $e');
    }
  }

  /// Unregister **every** known alias scan_priv from the indexer push
  /// registry. Used by logout / wipe / global-push-OFF cascade.
  ///
  /// Intentionally iterates *all* contacts (not just opted-in ones) so a row
  /// left behind by a stale flag is still cleaned up. Best-effort: failures
  /// are logged.
  Future<void> unregisterAllAliasViewKeys() async {
    final keys = aliasKeyService;
    if (keys == null) {
      Log.d(
        '[IndexerService] unregisterAllAliasViewKeys: aliasKeyService not wired, skipping',
      );
      return;
    }
    final all = await keys.loadAllAliasScanPrivs();
    Log.d(
      '[IndexerService] unregisterAllAliasViewKeys: clearing ${all.length} alias row(s)',
    );
    for (final entry in all) {
      try {
        await unregisterAliasViewKey(aliasScanPriv: entry.scanPriv);
      } catch (e) {
        Log.d(
          '[IndexerService] ⚠️ alias unregister fail contact=${entry.contactId}: $e',
        );
      }
    }
  }

  // ===========================================================================
  // MESSAGE FETCHING (HTTP FALLBACK) Soon
  // ===========================================================================

  // ===========================================================================
  // USERNAME SEARCH
  // ===========================================================================

  /// Fuzzy username search via `GET /username/search`.
  ///
  /// Thin pass-through over [IndexerClient.searchUsers]. Returns the raw
  /// [IndexerResult] so callers can branch on success/failure. Caller is
  /// responsible for trimming and empty-query short-circuiting.
  ///
  /// [limit] is clamped to `[1, 50]` by the underlying client.
  Future<IndexerResult<UsernameSearchResult>> searchUsers(
    String query, {
    int limit = 20,
  }) {
    return indexerClient.searchUsers(query, limit: limit);
  }

  // ===========================================================================
  // HEALTH & AVAILABILITY
  // ===========================================================================

  /// Returns true if the indexer is reachable. Uses a lightweight GET to the
  /// search endpoint rather than a dedicated health route (removed in cutover).
  Future<bool> isIndexerAvailable() async {
    try {
      final result = await indexerClient.searchUsers('a', limit: 1);
      return switch (result) {
        IndexerSuccess() => true,
        IndexerFailure(statusCode: final code) =>
          code != null && code >= 200 && code < 500,
      };
    } catch (_) {
      return false;
    }
  }

  // ===========================================================================
  // PUSH NOTIFICATION HANDLING
  // ===========================================================================

  /// Invoked when a silent `new_message` push arrives. Push body is treated
  /// as a wake signal only; the listener should trigger a chain scan.
  Future<void> Function()? onPushWakeup;

  Future<void> handlePushNotification(Map<String, dynamic> payload) async {
    final type = payload['type'] as String?;

    if (type == 'new_message') {
      try {
        await onPushWakeup?.call();
      } catch (e) {
        Log.d('[IndexerService] ⚠️ push wake-up handler error: $e');
      }
    }
  }

  // ===========================================================================
  // STATE UPDATES
  // ===========================================================================
  void _updateRegistrationState(IndexerRegistrationState state) {
    _registrationState = state;
    onRegistrationStateChanged?.call(state);
  }

  // ===========================================================================
  // AUTH HELPERS
  // ===========================================================================


  // ===========================================================================
  // CLEANUP
  // ===========================================================================

  Future<void> dispose() async {
    _tokenRefreshSub?.cancel();
  }
}

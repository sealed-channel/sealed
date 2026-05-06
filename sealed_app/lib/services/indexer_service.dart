/// Real-time messaging infrastructure and push notification service.
/// Manages WebSocket connections, Firebase Cloud Messaging tokens,
/// and encrypted communication with the indexer for instant message delivery.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
// FCM is back for Android push delivery (UnifiedPush is deprecated upstream).
// iOS continues to use APNs tokens registered via the platform AppDelegate.
import 'package:sealed_app/chain/wallet_interface.dart';
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/local/sync_state.dart';
import 'package:sealed_app/remote/indexer_client.dart';
import 'package:sealed_app/services/key_service.dart';

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
  final SyncState syncState;

  // State
  IndexerRegistrationState _registrationState =
      const IndexerRegistrationState();

  // ignore: unused_field
  bool _pushTokenRegistered =
      false; // Track if push was registered this session
  // ignore: unused_field
  StreamSubscription<String>? _tokenRefreshSub;

  // Callbacks
  void Function(NewMessageNotification)? onNewMessage;
  void Function(IndexerRegistrationState)? onRegistrationStateChanged;

  // Stream controllers
  final _messageController =
      StreamController<NewMessageNotification>.broadcast();
  Stream<NewMessageNotification> get messageStream => _messageController.stream;

  IndexerService({
    required this.indexerClient,
    required this.syncState,
    required this.keyService,
    this.chainWallet,
  });

  // ===========================================================================
  // GETTERS
  // ===========================================================================

  IndexerRegistrationState get registrationState => _registrationState;

  // ===========================================================================
  // INITIALIZATION
  // ===========================================================================

  /// Full initialization: register view key.
  ///
  /// Push registration is opt-in and lives behind the dedicated
  /// [registerTargetedPush] entry point — it is no longer driven from here.
  /// Real-time delivery happens via push wake-up + on-chain pull (OHTTP),
  /// not via persistent WebSocket.
  Future<void> initializeWithIndexer() async {
    print('[IndexerService] 🚀 Starting full initialization...');

    try {
      await registerViewKey();

      print('[IndexerService] ✅ Initialization complete');
    } catch (e) {
      print('[IndexerService] ❌ Initialization failed: $e');
      rethrow;
    }
  }

  // ===========================================================================
  // VIEW KEY REGISTRATION
  // ===========================================================================

  /// Register view key with the indexer
  Future<void> registerViewKey() async {
    print('[IndexerService] 🔑 Registering view key...');

    _updateRegistrationState(
      _registrationState.copyWith(
        status: IndexerRegistrationStatus.registering,
      ),
    );

    try {
      final keys = await keyService.loadKeys();
      if (keys == null) {
        throw IndexerRegistrationException('Keys not found in storage');
      }

      // Create message for signing: "Register view key: <viewKeyBase64>"
      // IMPORTANT: Send the view PRIVATE key (not public). The indexer needs
      // the private scalar to compute ECDH(viewPrivate, senderEphemeralPub)
      // for message detection. This is safe — the view key allows detection
      // but NOT decryption (which requires the separate encryption private key).
      final viewKeyBase64 = base64.encode(keys.viewPrivateKey);
      final message = 'Register view key: $viewKeyBase64';

      // Sign with wallet to prove ownership
      final signatureBytes = await chainWallet!.signMessage(message);
      final signature = base64.encode(signatureBytes);

      // Use the actual chain wallet address, not the (possibly stale) one
      // stored in keys — after a Solana→Algorand migration the persisted
      // address may still be the old Solana address.
      final walletAddress = chainWallet?.walletAddress ?? keys.walletAddress;

      // Compute view key hash (SHA256 hex) for WebSocket auth
      final viewKeyHash = sha256.convert(keys.viewPrivateKey).toString();
      print(
        '[IndexerService] 🔍 Local identity: wallet=$walletAddress, viewKeyHash=$viewKeyHash',
      );

      // Also compute the wallet-derived X25519 private key so the indexer
      // can detect messages encrypted with the wallet's Ed25519→X25519 key
      // (fallback path when sender can't reach the indexer for published keys).
      Uint8List? walletDerivedKey;
      try {
        final walletKp = await keyService.getWalletDerivedX25519KeyPair();
        if (walletKp != null) {
          final seed = await walletKp.extractPrivateKeyBytes();
          walletDerivedKey = Uint8List.fromList(seed);
        }
      } catch (e) {
        print('[IndexerService] ⚠️ Failed to compute wallet-derived key: $e');
      }

      // Register with indexer
      final result = await indexerClient.registerViewKey(
        viewKey: keys.viewPrivateKey,
        signature: signature,
        walletAddress: walletAddress,
        walletDerivedKey: walletDerivedKey,
      );

      switch (result) {
        case IndexerSuccess(:final data):
          if (data.success) {
            _updateRegistrationState(
              IndexerRegistrationState(
                status: IndexerRegistrationStatus.registered,
                userId: data.userId,
                viewKeyHash: viewKeyHash,
                registeredAt: DateTime.now(),
              ),
            );
            print(
              '[IndexerService] ✅ View key registered, userId: ${data.userId}',
            );
            print(
              '[IndexerService] 🔍 Registration mapping: wallet=$walletAddress, userId=${data.userId}, viewKeyHash=$viewKeyHash',
            );
          } else {
            throw IndexerRegistrationException(
              data.error ?? 'Registration failed',
            );
          }
        case IndexerFailure(:final error, :final statusCode):
          // Handle "already registered" as success
          if (statusCode == 409) {
            _updateRegistrationState(
              IndexerRegistrationState(
                status: IndexerRegistrationStatus.registered,
                viewKeyHash: viewKeyHash,
                registeredAt: DateTime.now(),
              ),
            );
            print('[IndexerService] ✅ View key already registered');
            print(
              '[IndexerService] 🔍 Existing registration mapping: wallet=$walletAddress, viewKeyHash=$viewKeyHash',
            );
          } else {
            throw IndexerRegistrationException(error);
          }
      }
    } catch (e) {
      _updateRegistrationState(
        _registrationState.copyWith(
          status: IndexerRegistrationStatus.failed,
          error: e.toString(),
        ),
      );
      rethrow;
    }
  }

  // ===========================================================================
  // ALIAS VIEW KEY REGISTRATION
  // ===========================================================================

  /// Register an alias recipientTag with the indexer for message detection.
  /// Sends only the tag (32 bytes), never the private enc_key.
  Future<bool> registerAliasTag({
    required String channelId,
    required Uint8List recipientTag,
  }) async {
    final userId = _registrationState.userId ?? indexerClient.registeredUserId;
    if (userId == null) {
      print('[IndexerService] ⚠️ No userId, re-registering first...');
      try {
        await registerViewKey();
      } catch (_) {}
    }

    final effectiveUserId =
        _registrationState.userId ?? indexerClient.registeredUserId;
    if (effectiveUserId == null) {
      print('[IndexerService] ❌ Cannot register alias tag: no userId');
      return false;
    }

    final keys = await keyService.loadKeys();
    if (keys == null) return false;

    final auth = await _generateAuthCredentials();

    final result = await indexerClient.registerAliasTag(
      userId: int.parse(effectiveUserId),
      channelId: channelId,
      recipientTag: recipientTag,
      walletAddress: auth.walletAddress,
      signature: auth.signature,
      timestamp: auth.timestamp,
      nonce: auth.nonce,
    );

    switch (result) {
      case IndexerSuccess():
        print('[IndexerService] ✅ Alias tag registered for channel $channelId');
        return true;
      case IndexerFailure(:final error):
        print('[IndexerService] ❌ Alias tag registration failed: $error');
        return false;
    }
  }

  /// Unregister an alias tag from the indexer.
  Future<bool> unregisterAliasTag({required String channelId}) async {
    final userId = _registrationState.userId ?? indexerClient.registeredUserId;
    if (userId == null) return false;

    final keys = await keyService.loadKeys();
    if (keys == null) return false;

    final auth = await _generateAuthCredentials();

    final result = await indexerClient.unregisterAliasTag(
      userId: int.parse(userId),
      channelId: channelId,
      walletAddress: auth.walletAddress,
      signature: auth.signature,
      timestamp: auth.timestamp,
      nonce: auth.nonce,
    );

    switch (result) {
      case IndexerSuccess():
        print(
          '[IndexerService] ✅ Alias tag unregistered for channel $channelId',
        );
        return true;
      case IndexerFailure(:final error):
        print('[IndexerService] ❌ Alias tag unregistration failed: $error');
        return false;
    }
  }

  /// Register an alias chat view key with the indexer so it can detect
  /// incoming alias messages and link them to this user.
  Future<bool> registerAliasViewKey({
    required String channelId,
    required Uint8List aliasPrivateKey,
    String? counterpartWallet,
  }) async {
    final userId = _registrationState.userId ?? indexerClient.registeredUserId;
    if (userId == null) {
      print('[IndexerService] ⚠️ No userId, re-registering view key first...');
      try {
        await registerViewKey();
      } catch (_) {}
    }

    final effectiveUserId =
        _registrationState.userId ?? indexerClient.registeredUserId;
    if (effectiveUserId == null) {
      print('[IndexerService] ❌ Cannot register alias key: no userId');
      return false;
    }

    final keys = await keyService.loadKeys();
    if (keys == null) return false;

    final auth = await _generateAuthCredentials();

    final result = await indexerClient.registerAliasViewKey(
      userId: int.parse(effectiveUserId),
      channelId: channelId,
      viewKey: aliasPrivateKey,
      walletAddress: auth.walletAddress,
      signature: auth.signature,
      timestamp: auth.timestamp,
      nonce: auth.nonce,
      counterpartWallet: counterpartWallet,
    );

    switch (result) {
      case IndexerSuccess():
        print(
          '[IndexerService] ✅ Alias view key registered for channel $channelId',
        );
        return true;
      case IndexerFailure(:final error):
        print('[IndexerService] ❌ Alias view key registration failed: $error');
        return false;
    }
  }

  /// Unregister an alias chat view key from the indexer.
  Future<bool> unregisterAliasViewKey({required String channelId}) async {
    final userId = _registrationState.userId ?? indexerClient.registeredUserId;
    if (userId == null) return false;

    final keys = await keyService.loadKeys();
    if (keys == null) return false;

    final auth = await _generateAuthCredentials();

    final result = await indexerClient.unregisterAliasViewKey(
      userId: int.parse(userId),
      channelId: channelId,
      walletAddress: auth.walletAddress,
      signature: auth.signature,
      timestamp: auth.timestamp,
      nonce: auth.nonce,
    );

    switch (result) {
      case IndexerSuccess():
        print(
          '[IndexerService] ✅ Alias view key unregistered for channel $channelId',
        );
        return true;
      case IndexerFailure(:final error):
        print(
          '[IndexerService] ❌ Alias view key unregistration failed: $error',
        );
        return false;
    }
  }

  // ===========================================================================
  // PUSH TOKEN REGISTRATION
  // ===========================================================================

  /// Verify the push endpoint is in sync with the indexer.
  ///
  /// Targeted-push registration has its own dedicated entry point
  /// ([registerTargetedPush]); this verification helper is currently
  /// deferred until that path also exposes a status endpoint.
  Future<PushTokenVerification> verifyPushToken() async {
    if (!_registrationState.isRegistered) {
      return PushTokenVerification(
        status: PushTokenStatus.error,
        message: 'Not registered with indexer',
      );
    }
    return PushTokenVerification(
      status: PushTokenStatus.missing,
      message: 'Push endpoint verification deferred (Task 2.5 follow-up)',
    );
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
          print('[IndexerService] ⚠️ FCM getToken returned null/empty');
          return null;
        }
        return token;
      } catch (e) {
        print('[IndexerService] ❌ FCM getToken failed: $e');
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
              print('[IndexerService] 🔑 APNS_TOKEN_DEBUG=$token');
            }
            return token;
          }
        } on PlatformException catch (e) {
          print('[IndexerService] ❌ APNs channel error: ${e.message}');
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
          print('[IndexerService] ❌ APNs registration error: $err');
        } else {
          print(
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
    print('[IndexerService] ➡️ registerTargetedPush() entry');
    final viewKeyBytes = await keyService.getViewKey();
    if (viewKeyBytes == null || viewKeyBytes.length != 32) {
      print('[IndexerService] ❌ Invalid view key for Push Notifications');
      return false;
    }
    print('[IndexerService] ✅ view key loaded len=${viewKeyBytes.length}');
    final platformToken = await _getPlatformToken();
    if (platformToken == null) {
      print('[IndexerService] ⚠️ No platform token for Push Notifications');
      return false;
    }
    final platform = Platform.isIOS ? 'ios' : 'android';
    final tokenPrefix = platformToken.length >= 6
        ? platformToken.substring(0, 6)
        : platformToken;
    print(
      '[IndexerService] ✅ platform=$platform tokenLen=${platformToken.length} tokenPrefix=$tokenPrefix',
    );

    print('[IndexerService] ➡️ calling register-targeted');
    final result = await indexerClient.registerTargetedPushToken(
      viewKey: viewKeyBytes,
      token: platformToken,
      platform: platform,
    );
    return switch (result) {
      IndexerSuccess(data: final r) => () {
        print(
          '[IndexerService] ✅ targeted-push register result success=${r.success}',
        );
        return r.success;
      }(),
      IndexerFailure(error: final e) => () {
        print('[IndexerService] ❌ targeted-push register failed: $e');
        return false;
      }(),
    };
  }

  /// Unregister from the Push Notifications registry; falls back to blinded fanout.
  Future<bool> unregisterTargetedPush() async {
    print('[IndexerService] ➡️ unregisterTargetedPush() entry');
    final viewKeyBytes = await keyService.getViewKey();
    if (viewKeyBytes == null || viewKeyBytes.length != 32) {
      print('[IndexerService] ❌ Invalid view key for unregister');
      return false;
    }
    print('[IndexerService] ✅ view key loaded len=${viewKeyBytes.length}');
    print('[IndexerService] ➡️ calling unregister-targeted');
    final result = await indexerClient.unregisterTargetedPushToken(
      viewKey: viewKeyBytes,
    );
    return switch (result) {
      IndexerSuccess(data: final r) => () {
        print(
          '[IndexerService] ✅ targeted-push unregister result success=${r.success}',
        );
        return r.success;
      }(),
      IndexerFailure(error: final e) => () {
        print('[IndexerService] ❌ targeted-push unregister failed: $e');
        return false;
      }(),
    };
  }

  // ===========================================================================
  // MESSAGE FETCHING (HTTP FALLBACK)
  // ===========================================================================

  /// Fetches new message pointers from the indexer since last sync.
  /// Returns metadata only - messages need to be fetched from chain and decrypted separately.
  ///
  /// **Task 2.4:** real-time sync is WebSocket-only in production. This HTTP
  /// polling path is gated behind [kDebugPollingFallback] (dev-only). In
  /// production builds this throws [IndexerServiceException] immediately;
  /// callers should rely on `messageStream` for live events and on the
  /// blockchain sync layer (`MessageService._syncViaBlockchain`) for backfill.
  ///
  /// [sinceTimestamp] - Optional Unix timestamp in seconds. If null, uses lastSyncTime from DB.
  ///                    Pass 0 or negative value to fetch ALL messages (full sync).
  Future<List<IndexerMessagePointer>> fetchNewMessages({
    int? sinceTimestamp,
  }) async {
    if (!kDebugPollingFallback) {
      throw IndexerServiceException(
        'HTTP polling disabled in production (Task 2.4). '
        'Use the WebSocket messageStream or the blockchain sync layer.',
        code: 'POLLING_DISABLED',
      );
    }
    // Use provided timestamp, or fall back to last sync time from DB
    int effectiveTimestamp;
    if (sinceTimestamp != null) {
      effectiveTimestamp = sinceTimestamp;
      print(
        '[IndexerService] 📡 Using provided timestamp: $effectiveTimestamp',
      );
    } else {
      final lastSync = await syncState.lastSyncTime;
      effectiveTimestamp = (lastSync.millisecondsSinceEpoch / 1000).floor();
      print('[IndexerService] 📡 Using lastSyncTime: $effectiveTimestamp');
    }

    final keys = await keyService.loadKeys();
    if (keys == null) {
      throw Exception('Keys not found in storage');
    }

    // If no userId registered (e.g. after chain migration), re-register first
    if (indexerClient.registeredUserId == null) {
      print(
        '[IndexerService] ⚠️ No registeredUserId, re-registering view key before fetch...',
      );
      try {
        await registerViewKey();
      } catch (e) {
        print('[IndexerService] ❌ View key re-registration failed: $e');
      }
    }

    final auth = await _generateAuthCredentials();

    final result = await indexerClient.getMessagesSince(
      sinceTimestamp: effectiveTimestamp,
      walletAddress: auth.walletAddress,
      signature: auth.signature,
      timestamp: auth.timestamp,
      nonce: auth.nonce,
    );

    switch (result) {
      case IndexerSuccess(:final data):
        if (data.hasMessages) {
          await syncState.updateLastSyncTime(DateTime.now());
        }
        return data.messages;
      case IndexerFailure(:final error, :final statusCode):
        // If user not found (404), the indexer DB was likely reset.
        // Re-register and retry once.
        if (statusCode == 404) {
          print('[IndexerService] ⚠️ User not found, re-registering...');
          await registerViewKey();
          final retryAuth = await _generateAuthCredentials();
          final retryResult = await indexerClient.getMessagesSince(
            sinceTimestamp: effectiveTimestamp,
            walletAddress: retryAuth.walletAddress,
            signature: retryAuth.signature,
            timestamp: retryAuth.timestamp,
            nonce: retryAuth.nonce,
          );
          switch (retryResult) {
            case IndexerSuccess(:final data):
              if (data.hasMessages) {
                await syncState.updateLastSyncTime(DateTime.now());
              }
              return data.messages;
            case IndexerFailure(:final error):
              throw Exception(
                'Failed to fetch messages after re-register: $error',
              );
          }
        }
        throw Exception('Failed to fetch messages: $error');
    }
  }

  // ===========================================================================
  // HEALTH & AVAILABILITY
  // ===========================================================================

  Future<bool> isIndexerAvailable() async {
    final result = await indexerClient.checkHealth();
    switch (result) {
      case IndexerSuccess(:final data):
        return data.isHealthy;
      case IndexerFailure():
        return false;
    }
  }

  // ===========================================================================
  // PUSH NOTIFICATION HANDLING
  // ===========================================================================

  Future<void> handlePushNotification(Map<String, dynamic> payload) async {
    final type = payload['type'] as String?;
    final data = payload['data'] as Map<String, dynamic>?;

    if (type == 'new_message' && data != null) {
      try {
        final notification = NewMessageNotification.fromJson(data);
        _messageController.add(notification);
        onNewMessage?.call(notification);
      } catch (e) {
        print('[IndexerService] ⚠️ Failed to parse push notification: $e');
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

  /// Generate authentication credentials for indexer API calls.
  ///
  /// Creates a timestamp-nonce pair, signs the auth message with the wallet,
  /// and returns structured credentials for API authentication.
  Future<IndexerAuthCredentials> _generateAuthCredentials() async {
    final keys = await keyService.loadKeys();
    if (keys == null) {
      throw IndexerServiceException(
        'Keys not found for auth credential generation',
      );
    }

    if (chainWallet == null) {
      throw IndexerServiceException('Chain wallet not available for signing');
    }

    final timestamp = (DateTime.now().millisecondsSinceEpoch / 1000).floor();
    final nonce = base64.encode(
      List.generate(16, (_) => DateTime.now().microsecond % 256),
    );
    final message = 'Sealed Indexer Auth: $timestamp:$nonce';

    final signatureBytes = await chainWallet!.signMessage(message);
    final signature = base64.encode(signatureBytes);
    final walletAddress = chainWallet?.walletAddress ?? keys.walletAddress;

    return IndexerAuthCredentials(
      timestamp: timestamp,
      nonce: nonce,
      signature: signature,
      walletAddress: walletAddress,
    );
  }

  // ===========================================================================
  // CLEANUP
  // ===========================================================================

  Future<void> dispose() async {
    _tokenRefreshSub?.cancel();
    await _messageController.close();
  }
}


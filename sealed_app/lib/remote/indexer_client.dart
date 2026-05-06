// lib/data/remote/indexer_client.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as legacy_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:sealed_app/remote/seal_dispatcher.dart';

// ============================================================================
// Exceptions
// ============================================================================

/// Security exception raised when the OHTTP gateway path is not usable.
class SecurityException implements Exception {
  final String message;
  SecurityException(this.message);

  @override
  String toString() => 'SecurityException: $message';
}

// ============================================================================
// Response Models
// ============================================================================

/// Response from view key registration
class ViewKeyRegistrationResponse {
  final bool success;
  final String? userId;
  final String? error;

  ViewKeyRegistrationResponse({required this.success, this.userId, this.error});

  factory ViewKeyRegistrationResponse.fromJson(Map<String, dynamic> json) {
    // userId can be int or String from the server
    final rawUserId = json['userId'];
    final userId = rawUserId?.toString();

    return ViewKeyRegistrationResponse(
      success: json['success'] as bool? ?? false,
      userId: userId,
      error: json['error'] as String?,
    );
  }
}

/// Response from push token registration
class PushTokenRegistrationResponse {
  final bool success;
  final String? error;

  PushTokenRegistrationResponse({required this.success, this.error});

  factory PushTokenRegistrationResponse.fromJson(Map<String, dynamic> json) {
    // Server replies in two equivalent shapes depending on endpoint:
    //   { "ok": true }            ← /push/register-blinded etc.
    //   { "success": true, ... }  ← legacy clients (kept for compatibility)
    // Treat either truthy flag as success.
    final success =
        (json['success'] as bool?) ?? (json['ok'] as bool?) ?? false;
    return PushTokenRegistrationResponse(
      success: success,
      error: json['error'] as String?,
    );
  }
}

/// Response from push token status check
class PushTokenStatusResponse {
  final bool registered;
  final String? tokenPrefix;
  final String? platform;

  PushTokenStatusResponse({
    required this.registered,
    this.tokenPrefix,
    this.platform,
  });

  factory PushTokenStatusResponse.fromJson(Map<String, dynamic> json) {
    return PushTokenStatusResponse(
      registered: json['registered'] as bool? ?? false,
      tokenPrefix: json['tokenPrefix'] as String?,
      platform: json['platform'] as String?,
    );
  }
}

/// Pointer to a message stored on-chain (returned by indexer)
///
/// This is NOT the full message content - just metadata to locate it.
/// Use [SolanaClient.fetchMessage()] to get the full [OnChainMessage],
/// then decrypt it locally to get a [DecryptedMessage].
///
/// Data flow:
/// 1. Indexer returns [IndexerMessagePointer] (this class)
/// 2. Client fetches [OnChainMessage] from Solana using accountPubkey
/// 3. Client decrypts → [DecryptedMessage]
/// 4. Client caches [DecryptedMessage] in SQLite
class IndexerMessagePointer {
  /// The Solana account address (base58) where the message is stored
  final String accountPubkey;

  /// Unix timestamp in milliseconds when the message was sent
  final int timestamp;

  /// Solana slot number (used for ordering and pagination)
  final int slot;

  IndexerMessagePointer({
    required this.accountPubkey,
    required this.timestamp,
    required this.slot,
  });

  factory IndexerMessagePointer.fromJson(Map<String, dynamic> json) {
    return IndexerMessagePointer(
      accountPubkey: json['accountPubkey']?.toString() ?? '',
      timestamp: json['timestamp'] as int,
      slot: json['slot'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accountPubkey': accountPubkey,
      'timestamp': timestamp,
      'slot': slot,
    };
  }

  @override
  String toString() {
    return 'IndexerMessagePointer(account: $accountPubkey, slot: $slot)';
  }
}

/// Response from messages since endpoint
class MessagesSinceResponse {
  /// List of message pointers (use these to fetch full messages from chain)
  final List<IndexerMessagePointer> messages;

  /// The last slot processed by the indexer (use for pagination)
  final int lastProcessedSlot;

  MessagesSinceResponse({
    required this.messages,
    required this.lastProcessedSlot,
  });

  factory MessagesSinceResponse.fromJson(Map<String, dynamic> json) {
    final messagesJson = json['messages'] as List<dynamic>? ?? [];
    return MessagesSinceResponse(
      messages: messagesJson
          .map((m) => IndexerMessagePointer.fromJson(m as Map<String, dynamic>))
          .where((p) => p.accountPubkey.length >= 10)
          .toList(),
      lastProcessedSlot: json['lastProcessedSlot'] as int? ?? 0,
    );
  }

  /// Check if there are new messages
  bool get hasMessages => messages.isNotEmpty;

  /// Get the number of new messages
  int get messageCount => messages.length;
}

/// Health check response
class HealthResponse {
  final String status;
  final int lastProcessedSlot;
  final int connectedClients;
  final int uptime;

  HealthResponse({
    required this.status,
    required this.lastProcessedSlot,
    required this.connectedClients,
    required this.uptime,
  });

  factory HealthResponse.fromJson(Map<String, dynamic> json) {
    return HealthResponse(
      status: json['status'] as String? ?? 'unknown',
      lastProcessedSlot: json['lastProcessedSlot'] as int? ?? 0,
      connectedClients: json['connectedClients'] as int? ?? 0,
      uptime: json['uptime'] as int? ?? 0,
    );
  }

  bool get isHealthy => status == 'ok';
}

class IndexerUserLookup {
  final String username;
  final String ownerPubkey;
  final Uint8List? encryptionPubkey;
  final Uint8List? scanPubkey;
  final Uint8List? pqPublicKey;

  IndexerUserLookup({
    required this.username,
    required this.ownerPubkey,
    this.encryptionPubkey,
    this.scanPubkey,
    this.pqPublicKey,
  });

  factory IndexerUserLookup.fromJson(Map<String, dynamic> json) {
    Uint8List? decodeMaybe(String? value) {
      if (value == null || value.isEmpty) return null;
      return Uint8List.fromList(base64Decode(value));
    }

    return IndexerUserLookup(
      username: json['username'] as String,
      ownerPubkey: json['ownerPubkey'] as String,
      encryptionPubkey: decodeMaybe(json['encryptionPubkey'] as String?),
      scanPubkey: decodeMaybe(json['scanPubkey'] as String?),
      pqPublicKey: decodeMaybe(json['pqPublicKey'] as String?),
    );
  }
}

class UsernameSearchResponse {
  final String query;
  final List<IndexerUserLookup> users;

  UsernameSearchResponse({required this.query, required this.users});

  factory UsernameSearchResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['users'] as List<dynamic>? ?? const [];
    return UsernameSearchResponse(
      query: json['query'] as String? ?? '',
      users: raw
          .map(
            (entry) =>
                IndexerUserLookup.fromJson(entry as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

/// Read-only view of a pre-Algorand username imported from the old
/// indexer-service (`registered_users`). Owner is a Solana base58
/// address — these accounts were never published on Algorand chain
/// and cannot currently be messaged. The indexer always sets
/// `legacy: true` on responses for this directory; it's preserved
/// here as a static field for symmetry with the wire format.
class IndexerLegacyUserLookup {
  final String username;
  final String ownerPubkey;
  final String? encryptionPubkeyBase64;
  final String? scanPubkeyBase64;
  final int registeredAt;
  final String source;

  bool get legacy => true;

  IndexerLegacyUserLookup({
    required this.username,
    required this.ownerPubkey,
    this.encryptionPubkeyBase64,
    this.scanPubkeyBase64,
    required this.registeredAt,
    required this.source,
  });

  factory IndexerLegacyUserLookup.fromJson(Map<String, dynamic> json) {
    return IndexerLegacyUserLookup(
      username: json['username'] as String,
      ownerPubkey: json['ownerPubkey'] as String,
      encryptionPubkeyBase64: json['encryptionPubkey'] as String?,
      scanPubkeyBase64: json['scanPubkey'] as String?,
      registeredAt: (json['registeredAt'] as num?)?.toInt() ?? 0,
      source: json['source'] as String? ?? 'unknown',
    );
  }
}

class LegacyUsernameSearchResponse {
  final String query;
  final List<IndexerLegacyUserLookup> users;

  LegacyUsernameSearchResponse({required this.query, required this.users});

  factory LegacyUsernameSearchResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['users'] as List<dynamic>? ?? const [];
    return LegacyUsernameSearchResponse(
      query: json['query'] as String? ?? '',
      users: raw
          .map(
            (entry) =>
                IndexerLegacyUserLookup.fromJson(entry as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

/// Result wrapper for API calls
sealed class IndexerResult<T> {
  const IndexerResult();
}

class IndexerSuccess<T> extends IndexerResult<T> {
  final T data;
  const IndexerSuccess(this.data);
}

class IndexerFailure<T> extends IndexerResult<T> {
  final String error;
  final int? statusCode;
  const IndexerFailure(this.error, {this.statusCode});
}

/// Client for communicating with the Sealed indexer service
///
/// The indexer provides:
/// - Real-time message detection via view key registration
/// - Push notification delivery
/// - Fast message lookup without scanning the entire blockchain
class IndexerClient {
  final String baseUrl;
  final Dio _dio;

  /// User ID returned from view key registration (stored for subsequent calls)
  String? _registeredUserId;

  /// Cached dispatcher X25519 public key + when it was fetched. Refreshed
  /// at most once per [_dispatcherKeyTtl] or after a decrypt-side error.
  Uint8List? _cachedDispatcherPubKey;
  DateTime? _cachedDispatcherPubKeyFetchedAt;
  static const Duration _dispatcherKeyTtl = Duration(hours: 24);
  final DispatcherSeal _dispatcherSeal = DispatcherSeal();

  IndexerClient({
    required String baseUrl,
    Dio? dioClient,
    Duration timeout = const Duration(seconds: 30),
  }) : baseUrl = _normalizeBaseUrl(baseUrl),
       _dio =
           dioClient ??
           Dio(
             BaseOptions(
               baseUrl: _normalizeBaseUrl(baseUrl),
               connectTimeout: timeout,
               receiveTimeout: timeout,
             ),
           ) {
    // Set baseUrl for provided Dio client if not already set
    if (dioClient != null && dioClient.options.baseUrl.isEmpty) {
      dioClient.options.baseUrl = this.baseUrl;
    }
  }

  /// Normalize a raw base URL: pass `http://` / `https://` URLs through,
  /// otherwise prepend `https://` (the Pi gateway is HTTPS via Tailscale Funnel).
  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return 'https://$trimmed';
  }

  /// Get the registered user ID (set after successful view key registration)
  String? get registeredUserId => _registeredUserId;

  /// Fail-closed pre-flight before any indexer call. The OhttpInterceptor on
  /// the Dio chain encapsulates the request to the Pi's OHTTP gateway via the
  /// public relay; here we just refuse to send if the configured base URL is
  /// not HTTPS, so a misconfiguration cannot leak plaintext over the relay.
  Future<void> _ensureGatewayReady() async {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw SecurityException(
        'Indexer base URL must be https with a host; got "$baseUrl"',
      );
    }
  }

  /// Register a view key with the indexer for message detection
  ///
  /// The view key allows the indexer to detect incoming messages for this user
  /// without being able to decrypt the message content.
  ///
  /// [viewKey] - The 32-byte X25519 public view key (scan_pubkey)
  /// [signature] - Signature proving ownership of the wallet
  /// [walletAddress] - The user's Solana wallet address
  ///
  /// Returns [ViewKeyRegistrationResponse] with userId on success
  Future<IndexerResult<ViewKeyRegistrationResponse>> registerViewKey({
    required Uint8List viewKey,
    required String signature,
    required String walletAddress,
    Uint8List? walletDerivedKey,
  }) async {
    // Validate view key length
    if (viewKey.length != 32) {
      return const IndexerFailure(
        'View key must be exactly 32 bytes',
        statusCode: 400,
      );
    }

    // Server contract: no /register-view-key endpoint exists. Identity on the
    // server is keyed by sha256(viewKey) hex. Compute locally and cache it as
    // _registeredUserId so subsequent push (un)register calls can reference it.
    final viewKeyHash = legacy_crypto.sha256.convert(viewKey).toString();
    _registeredUserId = viewKeyHash;
    return IndexerSuccess(
      ViewKeyRegistrationResponse(success: true, userId: viewKeyHash),
    );
  }

  /// Check if the current push token on the indexer matches local token
  Future<IndexerResult<PushTokenStatusResponse>> getPushTokenStatus() async {
    if (_registeredUserId == null) {
      return const IndexerFailure(
        'Must register view key first',
        statusCode: 400,
      );
    }

    try {
      final response = await _dio.get(
        '/push-token-status/$_registeredUserId',
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(PushTokenStatusResponse.fromJson(json));
      } else {
        return IndexerFailure(
          'Failed to check push token status',
          statusCode: response.statusCode,
        );
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Get messages since a given timestamp
  ///
  /// Uses user-specific endpoint when userId is available (from view key registration).
  /// This returns only messages that match the user's registered view key.
  ///
  /// [sinceTimestamp] - Unix timestamp in seconds
  /// [walletAddress] - Base58 wallet address
  /// [signature] - Base64 signature of auth message
  /// [timestamp] - Unix timestamp (seconds) used in signature
  /// [nonce] - Random nonce used in signature
  Future<IndexerResult<MessagesSinceResponse>> getMessagesSince({
    required int sinceTimestamp,
    required String walletAddress,
    required String signature,
    required int timestamp,
    required String nonce,
  }) async {
    try {
      // Use user-specific endpoint if we have a registered userId
      // This returns only messages that match our view key (much more efficient)
      final String endpoint;
      if (_registeredUserId != null) {
        endpoint = '/messages/user/$_registeredUserId/since/$sinceTimestamp';
        print(
          '[IndexerClient] 📡 Fetching messages for user $_registeredUserId since $sinceTimestamp',
        );
      } else {
        // Fallback to general endpoint (returns ALL messages - not recommended)
        endpoint = '/messages/since/$sinceTimestamp';
        print(
          '[IndexerClient] ⚠️ No userId, using general endpoint (will return all messages)',
        );
      }

      final response = await _dio.get(
        endpoint,
        options: Options(
          headers: {
            'Accept': 'application/json',
            'X-Wallet-Address': walletAddress,
            'X-Signature': signature,
            'X-Timestamp': timestamp.toString(),
            'X-Nonce': nonce,
          },
        ),
      );

      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        final result = MessagesSinceResponse.fromJson(json);
        print(
          '[IndexerClient] ✅ Got ${result.messageCount} message pointers from indexer',
        );
        return IndexerSuccess(result);
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage = json['error'] as String? ?? 'Failed to fetch messages';
        } catch (_) {
          errorMessage =
              'Failed to fetch messages with status ${response.statusCode}';
        }
        print('[IndexerClient] ❌ Failed to fetch messages: $errorMessage');
        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Register a username directly with the indexer so it's immediately
  /// searchable, without waiting for the catchup worker.
  Future<IndexerResult<bool>> registerUsername({
    required String username,
    required String ownerPubkey,
    required String encryptionPubkeyBase64,
    required String scanPubkeyBase64,
    String? pqPublicKeyBase64,
    String? txSignature,
  }) async {
    try {
      final response = await _dio.post(
        '/user/register-username',
        data: {
          'username': username,
          'ownerPubkey': ownerPubkey,
          'encryptionPubkey': encryptionPubkeyBase64,
          'scanPubkey': scanPubkeyBase64,
          if (pqPublicKeyBase64 != null) 'pqPublicKey': pqPublicKeyBase64,
          if (txSignature != null) 'txSignature': txSignature,
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return const IndexerSuccess(true);
      }

      String errorMessage;
      try {
        final json = response.data as Map<String, dynamic>;
        errorMessage =
            json['error'] as String? ?? 'Username registration failed';
      } catch (_) {
        errorMessage =
            'Username registration failed with status ${response.statusCode}';
      }
      return IndexerFailure(errorMessage, statusCode: response.statusCode);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  Future<IndexerResult<IndexerUserLookup>> getUserByUsername(
    String username,
  ) async {
    try {
      final response = await _dio.get(
        '/user/by-username/$username',
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(IndexerUserLookup.fromJson(json));
      }

      String errorMessage;
      try {
        final json = response.data as Map<String, dynamic>;
        errorMessage = json['error'] as String? ?? 'User lookup failed';
      } catch (_) {
        errorMessage = 'User lookup failed with status ${response.statusCode}';
      }
      return IndexerFailure(errorMessage, statusCode: response.statusCode);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  Future<IndexerResult<IndexerUserLookup>> getUserByOwner(
    String ownerPubkey,
  ) async {
    try {
      final response = await _dio.get(
        '/user/by-owner/$ownerPubkey',
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(IndexerUserLookup.fromJson(json));
      }

      String errorMessage;
      try {
        final json = response.data as Map<String, dynamic>;
        errorMessage = json['error'] as String? ?? 'Owner lookup failed';
      } catch (_) {
        errorMessage = 'Owner lookup failed with status ${response.statusCode}';
      }
      return IndexerFailure(errorMessage, statusCode: response.statusCode);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  Future<IndexerResult<UsernameSearchResponse>> searchUsersByUsername(
    String query, {
    int limit = 20,
  }) async {
    try {
      final response = await _dio.get(
        '/user/search',
        queryParameters: {'q': query, 'limit': limit},
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(UsernameSearchResponse.fromJson(json));
      }

      String errorMessage;
      try {
        final json = response.data as Map<String, dynamic>;
        errorMessage = json['error'] as String? ?? 'User search failed';
      } catch (_) {
        errorMessage = 'User search failed with status ${response.statusCode}';
      }
      return IndexerFailure(errorMessage, statusCode: response.statusCode);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Look up a single legacy (pre-Algorand) user by username.
  /// Returns null when the indexer responds 404 (no legacy entry for that name).
  Future<IndexerResult<IndexerLegacyUserLookup?>> getLegacyUserByUsername(
    String username,
  ) async {
    try {
      final response = await _dio.get(
        '/legacy/by-username/$username',
        options: Options(
          headers: {'Accept': 'application/json'},
          validateStatus: (s) =>
              s != null && (s == 404 || (s >= 200 && s < 300)),
        ),
      );

      if (response.statusCode == 404) {
        return const IndexerSuccess(null);
      }
      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(IndexerLegacyUserLookup.fromJson(json));
      }
      return IndexerFailure(
        'Legacy lookup failed',
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Prefix-search the legacy directory. Results are dimmed/non-messageable
  /// in the UI (these names predate Algorand and have Solana owners).
  Future<IndexerResult<LegacyUsernameSearchResponse>> searchLegacyUsers(
    String query, {
    int limit = 20,
  }) async {
    try {
      final response = await _dio.get(
        '/legacy/search',
        queryParameters: {'q': query, 'limit': limit},
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(LegacyUsernameSearchResponse.fromJson(json));
      }
      return IndexerFailure(
        'Legacy search failed',
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Check if the indexer service is healthy
  Future<IndexerResult<HealthResponse>> checkHealth() async {
    try {
      final response = await _dio.get(
        '/health',
        options: Options(
          headers: {'Accept': 'application/json'},
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(HealthResponse.fromJson(json));
      } else {
        return IndexerFailure(
          'Health check failed',
          statusCode: response.statusCode,
        );
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Unregister from the indexer service
  ///
  /// Deletes all user data including view key and push token registrations.
  ///
  /// [signature] - Signature proving ownership for authorization
  Future<IndexerResult<bool>> unregister({required String signature}) async {
    if (_registeredUserId == null) {
      return const IndexerFailure(
        'No registered user to unregister',
        statusCode: 400,
      );
    }

    try {
      final response = await _dio.delete(
        '/unregister',
        data: {'userId': _registeredUserId, 'signature': signature},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      if (response.statusCode == 200) {
        _registeredUserId = null;
        return const IndexerSuccess(true);
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage = json['error'] as String? ?? 'Unregister failed';
        } catch (_) {
          errorMessage = 'Unregister failed with status ${response.statusCode}';
        }

        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Register an alias chat view key with the indexer for message detection.
  ///
  /// [userId] - The registered user ID (from view key registration)
  /// [channelId] - The alias channel ID
  /// Register the alias recipientTag (32 bytes, base64) with the indexer.
  /// The indexer uses it for O(1) message detection — no private key is sent.
  Future<IndexerResult<bool>> registerAliasTag({
    required int userId,
    required String channelId,
    required Uint8List recipientTag,
    required String walletAddress,
    required String signature,
    required int timestamp,
    required String nonce,
  }) async {
    try {
      final response = await _dio.post(
        '/register-alias-tag',
        data: {
          'userId': userId,
          'channelId': channelId,
          'recipientTag': base64Encode(recipientTag),
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Wallet-Address': walletAddress,
            'X-Signature': signature,
            'X-Timestamp': timestamp.toString(),
            'X-Nonce': nonce,
          },
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return const IndexerSuccess(true);
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage =
              json['error'] as String? ?? 'Alias tag registration failed';
        } catch (_) {
          errorMessage =
              'Alias tag registration failed with status ${response.statusCode}';
        }
        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Unregister an alias tag from the indexer.
  Future<IndexerResult<bool>> unregisterAliasTag({
    required int userId,
    required String channelId,
    required String walletAddress,
    required String signature,
    required int timestamp,
    required String nonce,
  }) async {
    try {
      final response = await _dio.delete(
        '/unregister-alias-tag',
        data: {'userId': userId, 'channelId': channelId},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Wallet-Address': walletAddress,
            'X-Signature': signature,
            'X-Timestamp': timestamp.toString(),
            'X-Nonce': nonce,
          },
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        return const IndexerSuccess(true);
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage =
              json['error'] as String? ?? 'Alias tag unregistration failed';
        } catch (_) {
          errorMessage =
              'Alias tag unregistration failed with status ${response.statusCode}';
        }
        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// [viewKey] - The 32-byte X25519 private key for the alias chat
  /// [walletAddress] - The user's wallet address for auth
  /// [signature] - Signature proving wallet ownership
  /// [timestamp] - Unix timestamp used in auth message
  /// [nonce] - Random nonce used in auth message
  Future<IndexerResult<bool>> registerAliasViewKey({
    required int userId,
    required String channelId,
    required Uint8List viewKey,
    required String walletAddress,
    required String signature,
    required int timestamp,
    required String nonce,
    String? counterpartWallet,
  }) async {
    try {
      final bodyMap = {
        'userId': userId,
        'channelId': channelId,
        'viewKey': base64Encode(viewKey),
        if (counterpartWallet != null) 'counterpartWallet': counterpartWallet,
      };

      final response = await _dio.post(
        '/register-alias-view-key',
        data: bodyMap,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Wallet-Address': walletAddress,
            'X-Signature': signature,
            'X-Timestamp': timestamp.toString(),
            'X-Nonce': nonce,
          },
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        return const IndexerSuccess(true);
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage =
              json['error'] as String? ?? 'Alias view key registration failed';
        } catch (_) {
          errorMessage =
              'Alias view key registration failed with status ${response.statusCode}';
        }
        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Unregister an alias chat view key from the indexer.
  Future<IndexerResult<bool>> unregisterAliasViewKey({
    required int userId,
    required String channelId,
    required String walletAddress,
    required String signature,
    required int timestamp,
    required String nonce,
  }) async {
    try {
      final response = await _dio.delete(
        '/unregister-alias-view-key',
        data: {'userId': userId, 'channelId': channelId},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Wallet-Address': walletAddress,
            'X-Signature': signature,
            'X-Timestamp': timestamp.toString(),
            'X-Nonce': nonce,
          },
        ),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        return const IndexerSuccess(true);
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage =
              json['error'] as String? ??
              'Alias view key unregistration failed';
        } catch (_) {
          errorMessage =
              'Alias view key unregistration failed with status ${response.statusCode}';
        }
        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Check if the indexer is available
  Future<bool> isAvailable() async {
    final result = await checkHealth();
    return switch (result) {
      IndexerSuccess(data: final health) => health.isHealthy,
      IndexerFailure() => false,
    };
  }

  /// Dispose of the HTTP client
  void dispose() {
    _dio.close();
  }

  // ============================================================================
  // Push Notifications (OPT-IN): server holds view_priv to dispatch visible alerts
  // ============================================================================

  /// Register for **targeted** push (opt-in mode). Unlike the blinded path,
  /// this hands the indexer `view_priv` so the watcher can trial-decrypt
  /// chain events for this user and dispatch one visible-alert push per match.
  ///
  /// Privacy trade-offs (must be disclosed to the user before calling):
  ///   1. The indexer learns *which* on-chain messages belong to this user.
  ///   2. Apple/Google see per-message wake-up timing.
  ///
  /// The server enforces two cryptographic proofs at the route level:
  ///   - derivePublicKey(view_priv) === view_pub
  ///   - HMAC(view_priv, "push-v1") === blinded_id
  ///
  /// [viewKey] — the raw 32-byte X25519 private seed. `view_pub` is derived
  /// locally and posted alongside `view_priv` in hex.
  Future<IndexerResult<PushTokenRegistrationResponse>>
  registerTargetedPushToken({
    required Uint8List viewKey,
    required String token,
    required String platform,
  }) async {
    print(
      '[IndexerClient] register-targeted: validating inputs platform=$platform tokenLen=${token.length} viewKeyLen=${viewKey.length}',
    );
    if (platform != 'ios' && platform != 'android') {
      return const IndexerFailure(
        'Platform must be either "ios" or "android"',
        statusCode: 400,
      );
    }
    if (viewKey.length != 32) {
      return const IndexerFailure(
        'View key must be exactly 32 bytes',
        statusCode: 400,
      );
    }

    try {
      await _ensureGatewayReady();
      print('[IndexerClient] gateway ready');

      // Derive view_pub from the seed. Hex-encode both for the wire format.
      final x25519 = X25519();
      final keyPair = await x25519.newKeyPairFromSeed(viewKey);
      final viewPubKey = await keyPair.extractPublicKey();
      final viewPubBytes = Uint8List.fromList(viewPubKey.bytes);
      final viewPubHex = viewPubBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final viewPrivHex = viewKey
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      print('[IndexerClient] view_pub prefix=${viewPubHex.substring(0, 8)}');

      final blindedId = await _computeBlindedId(viewKey);
      print('[IndexerClient] blinded_id prefix=${blindedId.substring(0, 8)}');
      print('[IndexerClient] fetching dispatcher key + encrypting token');
      final encryptedToken = await _encryptToken(token);
      print('[IndexerClient] enc_token ready len=${encryptedToken.length}');

      print('[IndexerClient] POST /push/register-targeted');
      final response = await _dio.post(
        '/push/register-targeted',
        data: {
          'blinded_id': blindedId,
          'enc_token': encryptedToken,
          'platform': platform,
          'view_priv': viewPrivHex,
          'view_pub': viewPubHex,
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      print('[IndexerClient] register-targeted status=${response.statusCode}');
      if (response.statusCode == 200 || response.statusCode == 201) {
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(PushTokenRegistrationResponse.fromJson(json));
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage =
              json['error'] as String? ??
              json['message'] as String? ??
              'Push Notifications registration failed';
        } catch (_) {
          errorMessage =
              'Push Notifications registration failed with status ${response.statusCode}';
        }
        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on SecurityException catch (e) {
      return IndexerFailure('Security error: ${e.message}', statusCode: 403);
    } on DioException catch (e) {
      print(
        '[IndexerClient] register-targeted DioException type=${e.type} message=${e.message}',
      );
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      print('[IndexerClient] register-targeted threw: $e');
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Unregister from Push Notifications.
  Future<IndexerResult<PushTokenRegistrationResponse>>
  unregisterTargetedPushToken({required Uint8List viewKey}) async {
    try {
      await _ensureGatewayReady();
      final blindedId = await _computeBlindedId(viewKey);

      print('[IndexerClient] POST /push/unregister-targeted');
      final response = await _dio.post(
        '/push/unregister-targeted',
        data: {'blinded_id': blindedId},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      print(
        '[IndexerClient] unregister-targeted status=${response.statusCode}',
      );
      if (response.statusCode == 200 || response.statusCode == 204) {
        if (response.data == null || response.data == '') {
          return IndexerSuccess(
            PushTokenRegistrationResponse(success: true, error: null),
          );
        }
        final json = response.data as Map<String, dynamic>;
        return IndexerSuccess(PushTokenRegistrationResponse.fromJson(json));
      } else {
        String errorMessage;
        try {
          final json = response.data as Map<String, dynamic>;
          errorMessage =
              json['error'] as String? ??
              json['message'] as String? ??
              'Push Notifications unregistration failed';
        } catch (_) {
          errorMessage =
              'Push Notifications unregistration failed with status ${response.statusCode}';
        }
        return IndexerFailure(errorMessage, statusCode: response.statusCode);
      }
    } on SecurityException catch (e) {
      return IndexerFailure('Security error: ${e.message}', statusCode: 403);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const IndexerFailure('Network timeout');
      } else if (e.type == DioExceptionType.connectionError) {
        return IndexerFailure('Connection error: ${e.message}');
      }
      return IndexerFailure('Network error: ${e.message}');
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Compute blinded ID using HMAC(view_key, "push-v1") as required by Task 2.3
  Future<String> _computeBlindedId(Uint8List viewKey) async {
    final hmac = Hmac.sha256();
    final secretKey = SecretKey(viewKey);
    final mac = await hmac.calculateMac(
      utf8.encode('push-v1'),
      secretKey: secretKey,
    );
    return mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Encrypt push token under the dispatcher's X25519 public key using a
  /// sealed-box style envelope. See [DispatcherSeal] for the byte layout —
  /// this method MUST stay byte-exact with the server's
  /// `createDispatcherDecryptor` in dispatcher-seal.ts. Failure here is a
  /// hard error: shipping a plaintext token to the indexer would break the
  /// privacy guarantee documented in PRIVACY.md.
  Future<String> _encryptToken(String token) async {
    final dispatcherPubKey = await _getDispatcherPublicKey();
    final envelope = await _dispatcherSeal.sealToken(token, dispatcherPubKey);
    return base64Encode(envelope);
  }

  /// Get the dispatcher's public key from the indexer with a 24h cache.
  /// The dispatcher handles encrypted push tokens and forwards them to FCM/APNs.
  /// Call [invalidateDispatcherKey] to force a refetch (e.g. after the server
  /// signals a decrypt failure).
  Future<Uint8List> _getDispatcherPublicKey() async {
    final cached = _cachedDispatcherPubKey;
    final fetchedAt = _cachedDispatcherPubKeyFetchedAt;
    if (cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _dispatcherKeyTtl) {
      return cached;
    }
    try {
      final response = await _dio.get(
        '/dispatcher/public-key',
        options: Options(headers: {'Accept': 'application/json'}),
      );

      if (response.statusCode == 200) {
        final body = response.data;
        if (body is! Map<String, dynamic>) {
          final ct = response.headers.value('content-type') ?? 'unknown';
          throw Exception(
            'Dispatcher key endpoint returned non-JSON '
            '(content-type=$ct, runtimeType=${body.runtimeType})',
          );
        }
        final pubKeyBase64 = body['public_key'] as String?;
        if (pubKeyBase64 == null || pubKeyBase64.isEmpty) {
          throw Exception('Empty public key from dispatcher');
        }
        final pubKeyBytes = base64Decode(pubKeyBase64);
        if (pubKeyBytes.length != 32) {
          throw Exception(
            'Invalid dispatcher public key length: ${pubKeyBytes.length}',
          );
        }
        final fresh = Uint8List.fromList(pubKeyBytes);
        _cachedDispatcherPubKey = fresh;
        _cachedDispatcherPubKeyFetchedAt = DateTime.now();
        return fresh;
      } else {
        throw Exception(
          'Dispatcher public key fetch failed: ${response.statusCode}',
        );
      }
    } catch (e) {
      throw Exception('Failed to get dispatcher public key: $e');
    }
  }

  /// Drop the cached dispatcher public key — call after the server reports
  /// it could not decrypt a token, so the next encryption refetches.
  void invalidateDispatcherKey() {
    _cachedDispatcherPubKey = null;
    _cachedDispatcherPubKeyFetchedAt = null;
  }
}

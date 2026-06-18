// lib/data/remote/indexer_client.dart

import 'dart:convert';
import 'package:sealed_app/core/log.dart';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:sealed_app/models/search_hit.dart';
import 'package:sealed_app/infra/network/ohttp/seal_dispatcher.dart';
import 'package:sealed_app/infra/network/root_cache.dart';

export 'package:sealed_app/infra/network/root_cache.dart'
    show
        RootCache,
        InMemoryRootCache,
        EncryptedRootCache,
        RootRecord,
        RootHit,
        RootCacheReader,
        RootCacheWriter,
        frFromHex,
        frToHex,
        frFromDecimal,
        frModulus;

// ============================================================================
// IndexerClient
// ============================================================================

/// Client for communicating with the Sealed indexer service.
///
/// Public surface (4 + 3 methods + ctor + dispose):
///   1. [searchUsers]              — fuzzy username search
///   2. [checkUsernameAvailable]   — boolean availability
///   3. [registerPushToken]        — opt-in targeted push registration
///   4. [getPqPublicKey]           — fetch PQ pubkey + on-chain hash
///   5. [findRootContaining]       — locate a Merkle root holding a given leaf
///   6. [refreshRoots]             — refetch + replace the roots cache
///   7. [clearRootCache]           — drop cached roots (wire to logout)
class IndexerClient {
  final String baseUrl;
  final Dio _dio;
  final RootCache _rootCache;

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
    RootCache? rootCache,
  }) : baseUrl = _normalizeBaseUrl(baseUrl),
       _rootCache = rootCache ?? InMemoryRootCache(),
       _dio =
           dioClient ??
           Dio(
             BaseOptions(
               baseUrl: _normalizeBaseUrl(baseUrl),
               connectTimeout: timeout,
               receiveTimeout: timeout,
             ),
           ) {
    if (dioClient != null && dioClient.options.baseUrl.isEmpty) {
      dioClient.options.baseUrl = this.baseUrl;
    }
  }

  /// Normalize a raw base URL: pass `http://` / `https://` URLs through,
  /// otherwise prepend `https://`.
  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return 'https://$trimmed';
  }

  /// Fail-closed pre-flight: reject non-HTTPS base URLs before any network call.
  Future<void> _ensureGatewayReady() async {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw SecurityException(
        'Indexer base URL must be https with a host; got "$baseUrl"',
      );
    }
  }

  /// Dispose of the HTTP client.
  void dispose() {
    _dio.close();
  }

  // ============================================================================
  // 1. Username search
  // ============================================================================

  /// Fuzzy username search — `GET /username/search?q=&limit=`.
  ///
  /// [query] must be non-empty after trim (throws [ArgumentError] otherwise).
  /// [limit] is clamped to [1, 50].
  Future<IndexerResult<UsernameSearchResult>> searchUsers(
    String query, {
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(query, 'query', 'must be non-empty');
    }
    final clampedLimit = limit.clamp(1, 50);

    try {
      // ignore: avoid_print
      Log.d(
        '[searchUsers] → GET $baseUrl/username/search?q=$trimmed limit=$clampedLimit',
      );
      final response = await _dio.get(
        '/username/search',
        queryParameters: {'q': trimmed, 'limit': clampedLimit},
        options: Options(headers: {'Accept': 'application/json'}),
      );
      // ignore: avoid_print
      Log.d(
        '[searchUsers] ← status=${response.statusCode} body=${response.data}',
      );
      if (response.statusCode == 200) {
        return IndexerSuccess(
          UsernameSearchResult.fromJson(response.data as Map<String, dynamic>),
        );
      }
      return IndexerFailure(
        _extractError(response.data, 'search failed'),
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      // ignore: avoid_print
      Log.d(
        '[searchUsers] ✗ DioException: type=${e.type} msg=${e.message} resp=${e.response?.statusCode} ${e.response?.data}',
      );
      return IndexerFailure(_dioMessage(e));
    } catch (e, st) {
      // ignore: avoid_print
      Log.d('[searchUsers] ✗ unexpected: $e\n$st');
      return IndexerFailure('Unexpected error: $e');
    }
  }

  // ============================================================================
  // 2. Username availability
  // ============================================================================

  /// Check availability of a username — `GET /username/:name/available`.
  ///
  /// [name] must match `^[a-z][a-z0-9_]*[a-z0-9]$`, length 3..20.
  /// Lowercased before URI-encoding.
  Future<IndexerResult<UsernameAvailabilityResponse>> checkUsernameAvailable(
    String name,
  ) async {
    final lower = name.toLowerCase();
    if (lower.length < 3 ||
        lower.length > 20 ||
        !RegExp(r'^[a-z][a-z0-9_]*[a-z0-9]$').hasMatch(lower)) {
      throw ArgumentError.value(
        name,
        'name',
        'must be 3-20 chars matching ^[a-z][a-z0-9_]*[a-z0-9]\$',
      );
    }

    try {
      final response = await _dio.get(
        '/username/${Uri.encodeComponent(lower)}/available',
        options: Options(headers: {'Accept': 'application/json'}),
      );
      if (response.statusCode == 200) {
        return IndexerSuccess(
          UsernameAvailabilityResponse.fromJson(
            response.data as Map<String, dynamic>,
          ),
        );
      }
      return IndexerFailure(
        _extractError(response.data, 'availability check failed'),
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      return IndexerFailure(_dioMessage(e));
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  // ============================================================================
  // 3. Push registration
  // ============================================================================

  /// Register for targeted push — `POST /push/register`.
  ///
  /// Privacy trade-offs (must be disclosed to the user before calling):
  ///   1. The indexer learns *which* on-chain messages belong to this user.
  ///   2. Apple/Google see per-message wake-up timing.
  ///
  /// [viewKey] — 32-byte X25519 private seed. `view_pub` derived locally.
  Future<IndexerResult<PushTokenRegistrationResponse>> registerPushToken({
    required Uint8List viewKey,
    required String token,
    required String platform,
    String? wallet,
  }) async {
    _log(
      'registerPushToken: platform=$platform tokenLen=${token.length} viewKeyLen=${viewKey.length}',
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

      final x25519 = X25519();
      final keyPair = await x25519.newKeyPairFromSeed(viewKey);
      final viewPubKey = await keyPair.extractPublicKey();
      final viewPubBytes = Uint8List.fromList(viewPubKey.bytes);
      final viewPubHex = _toHex(viewPubBytes);
      final viewPrivHex = _toHex(viewKey);
      _log('view_pub prefix=${viewPubHex.substring(0, 8)}');

      final blindedId = await _computeBlindedId(viewKey);
      _log('blinded_id prefix=${blindedId.substring(0, 8)}');
      final encryptedToken = await _encryptToken(token);
      _log('enc_token ready len=${encryptedToken.length}');

      _log('POST /push/register');
      final response = await _dio.post(
        '/push/register',
        data: {
          'blinded_id': blindedId,
          'enc_token': encryptedToken,
          'platform': platform,
          'view_priv': viewPrivHex,
          'view_pub': viewPubHex,
          // Optional: enables KEM first-contact push (indexer matches the
          // deterministic handshake discovery tag for new conversations).
          if (wallet != null && wallet.isNotEmpty) 'wallet': wallet,
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      _log('registerPushToken status=${response.statusCode}');
      if (response.statusCode == 200 || response.statusCode == 201) {
        return IndexerSuccess(
          PushTokenRegistrationResponse.fromJson(
            response.data as Map<String, dynamic>,
          ),
        );
      }
      return IndexerFailure(
        _extractError(response.data, 'push registration failed'),
        statusCode: response.statusCode,
      );
    } on SecurityException catch (e) {
      return IndexerFailure('Security error: ${e.message}', statusCode: 403);
    } on DioException catch (e) {
      _log(
        'registerPushToken DioException type=${e.type} message=${e.message}',
      );
      return IndexerFailure(_dioMessage(e));
    } catch (e) {
      _log('registerPushToken threw: $e');
      return IndexerFailure('Unexpected error: $e');
    }
  }

  /// Unregister from push notifications — `POST /push/unregister`.
  ///
  /// Kept because logout flow in `indexer_service.dart` calls this.
  Future<IndexerResult<PushTokenRegistrationResponse>> unregisterPushToken({
    required Uint8List viewKey,
  }) async {
    try {
      await _ensureGatewayReady();
      final blindedId = await _computeBlindedId(viewKey);

      _log('POST /push/unregister');
      final response = await _dio.post(
        '/push/unregister',
        data: {'blinded_id': blindedId},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        ),
      );

      _log('unregisterPushToken status=${response.statusCode}');
      if (response.statusCode == 200 || response.statusCode == 204) {
        if (response.data == null || response.data == '') {
          return IndexerSuccess(
            PushTokenRegistrationResponse(success: true, error: null),
          );
        }
        return IndexerSuccess(
          PushTokenRegistrationResponse.fromJson(
            response.data as Map<String, dynamic>,
          ),
        );
      }
      return IndexerFailure(
        _extractError(response.data, 'push unregistration failed'),
        statusCode: response.statusCode,
      );
    } on SecurityException catch (e) {
      return IndexerFailure('Security error: ${e.message}', statusCode: 403);
    } on DioException catch (e) {
      return IndexerFailure(_dioMessage(e));
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  // ============================================================================
  // 4. PQ pubkey
  // ============================================================================

  /// Fetch the user's PQ public key and on-chain hash — `GET /user/:wallet/pq-pubkey`.
  ///
  /// [walletAddress] must be 58 characters (Algorand base32 address).
  /// 404 → `IndexerFailure('NOT_PUBLISHED', statusCode: 404)`.
  Future<IndexerResult<PqPublicKeyResponse>> getPqPublicKey(
    String walletAddress,
  ) async {
    if (walletAddress.length != 58) {
      throw ArgumentError.value(
        walletAddress,
        'walletAddress',
        'must be 58-char Algorand base32 address',
      );
    }

    try {
      final response = await _dio.get(
        '/user/${Uri.encodeComponent(walletAddress)}/pq-pubkey',
        options: Options(headers: {'Accept': 'application/json'}),
      );
      if (response.statusCode == 200) {
        return IndexerSuccess(
          PqPublicKeyResponse.fromJson(response.data as Map<String, dynamic>),
        );
      }
      if (response.statusCode == 404) {
        return const IndexerFailure('NOT_PUBLISHED', statusCode: 404);
      }
      return IndexerFailure(
        _extractError(response.data, 'pq-pubkey fetch failed'),
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return const IndexerFailure('NOT_PUBLISHED', statusCode: 404);
      }
      return IndexerFailure(_dioMessage(e));
    } catch (e) {
      return IndexerFailure('Unexpected error: $e');
    }
  }

  // ============================================================================
  // 5-7. Roots registry
  // ============================================================================

  /// Find the first cached root whose leaf-set contains [leafHex] (64-char
  /// lowercase hex of a BN254 Fr element).
  ///
  /// On cache miss, transparently calls [refreshRoots] and retries once.
  /// Returns `null` if no root contains the leaf even after refresh — the
  /// caller should surface "leaf not yet finalised" UX.
  ///
  /// Network egress is over the same OHTTP-routed Dio as every other method
  /// on this client.
  Future<RootHit?> findRootContaining(String leafHex) async {
    final firstTry = await _rootCache.findRootContaining(leafHex);
    if (firstTry != null) return firstTry;
    final ok = await refreshRoots();
    if (!ok) return null;
    return _rootCache.findRootContaining(leafHex);
  }

  /// Like [findRootContaining] but returns EVERY cached root whose leaf-set
  /// contains [leafHex]. The `/roots` table is cumulative across apps and old
  /// batches can reuse a preimage, so a single leaf can match more than one
  /// root — the redeem flow picks the one whose box exists on the configured
  /// app. On cache miss, refreshes once and retries.
  Future<List<RootHit>> findAllRootsContaining(String leafHex) async {
    final firstTry = await _rootCache.findAllRootsContaining(leafHex);
    if (firstTry.isNotEmpty) return firstTry;
    final ok = await refreshRoots();
    if (!ok) return const [];
    return _rootCache.findAllRootsContaining(leafHex);
  }

  /// Refetch `GET /roots` and replace the cache atomically.
  /// Returns `true` on success, `false` on network/parse failure (cache is
  /// left untouched so callers degrade to last-known-good).
  Future<bool> refreshRoots() async {
    try {
      final response = await _dio.get(
        '/roots',
        options: Options(headers: {'Accept': 'application/json'}),
      );
      if (response.statusCode != 200) return false;
      final raw = response.data;
      if (raw is! List) return false;
      final records = raw
          .cast<Map<String, dynamic>>()
          .map(RootRecord.fromJson)
          .toList(growable: false);
      await _rootCache.replaceAll(records);
      return true;
    } catch (_) {
      // No PII in this log line — refresh failure is operational, not secret.
      _log('refreshRoots failed');
      return false;
    }
  }

  /// Drop all cached roots (RAM + on-disk blob). Wired into the logout flow.
  Future<void> clearRootCache() => _rootCache.clear();

  // ============================================================================
  // Private helpers
  // ============================================================================

  static void _log(String msg) {
    if (kDebugMode) Log.d('[IndexerClient] $msg');
  }

  Future<String> _computeBlindedId(Uint8List viewKey) async {
    final hmac = Hmac.sha256();
    final secretKey = SecretKey(viewKey);
    final mac = await hmac.calculateMac(
      utf8.encode('push-v1'),
      secretKey: secretKey,
    );
    return _toHex(Uint8List.fromList(mac.bytes));
  }

  /// Encrypt push token under the dispatcher's X25519 public key.
  /// Must stay byte-exact with server's `createDispatcherDecryptor`.
  Future<String> _encryptToken(String token) async {
    final dispatcherPubKey = await _getDispatcherPublicKey();
    final envelope = await _dispatcherSeal.sealToken(token, dispatcherPubKey);
    return base64Encode(envelope);
  }

  /// Get the dispatcher's public key from the indexer with a 24h cache.
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
      }
      throw Exception(
        'Dispatcher public key fetch failed: ${response.statusCode}',
      );
    } catch (e) {
      throw Exception('Failed to get dispatcher public key: $e');
    }
  }

  /// Drop the cached dispatcher public key — call after the server reports
  /// it could not decrypt a token.
  void invalidateDispatcherKey() {
    _cachedDispatcherPubKey = null;
    _cachedDispatcherPubKeyFetchedAt = null;
  }

  static String _extractError(dynamic data, String fallback) {
    try {
      return (data as Map<String, dynamic>)['error'] as String? ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  static String _dioMessage(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return 'Network timeout';
    }
    if (e.type == DioExceptionType.connectionError) {
      return 'Connection error: ${e.message}';
    }
    return 'Network error: ${e.message}';
  }

  static String _toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _fromHex(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
// ============================================================================
// Response Models
// ============================================================================

/// Response from push token registration.
class PushTokenRegistrationResponse {
  final bool success;
  final String? error;

  PushTokenRegistrationResponse({required this.success, this.error});

  factory PushTokenRegistrationResponse.fromJson(Map<String, dynamic> json) {
    final success =
        (json['success'] as bool?) ?? (json['ok'] as bool?) ?? false;
    return PushTokenRegistrationResponse(
      success: success,
      error: json['error'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// Username models
// ---------------------------------------------------------------------------

/// Search result from GET /username/search.
class UsernameSearchResult {
  final String query;
  final int count;
  final List<UsernameSearchHit> users;

  const UsernameSearchResult({
    required this.query,
    required this.count,
    required this.users,
  });

  factory UsernameSearchResult.fromJson(Map<String, dynamic> json) {
    final raw = json['results'] as List<dynamic>? ?? const [];
    return UsernameSearchResult(
      query: json['query'] as String? ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      users: raw
          .map((e) => UsernameSearchHit.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Availability from GET /username/:name/available — single bool, no cooldown.
class UsernameAvailabilityResponse {
  final bool available;

  const UsernameAvailabilityResponse({required this.available});

  factory UsernameAvailabilityResponse.fromJson(Map<String, dynamic> json) {
    return UsernameAvailabilityResponse(
      available: (json['available'] as bool?) ?? false,
    );
  }
}

/// PQ pubkey + hash from GET /user/:wallet/pq-pubkey.
class PqPublicKeyResponse {
  /// Base64-decoded raw PQ public key bytes.
  final Uint8List pqPubkey;

  /// Hex-decoded 32-byte on-chain hash.
  final Uint8List pqPubkeyHash;

  final int publishedAtRound;

  const PqPublicKeyResponse({
    required this.pqPubkey,
    required this.pqPubkeyHash,
    required this.publishedAtRound,
  });

  factory PqPublicKeyResponse.fromJson(Map<String, dynamic> j) =>
      PqPublicKeyResponse(
        pqPubkey: Uint8List.fromList(base64Decode(j['pqPubkey'] as String)),
        pqPubkeyHash: IndexerClient._fromHex(j['pqPubkeyHash'] as String),
        publishedAtRound: (j['publishedAtRound'] as num).toInt(),
      );
}

/// Result wrapper for API calls.
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

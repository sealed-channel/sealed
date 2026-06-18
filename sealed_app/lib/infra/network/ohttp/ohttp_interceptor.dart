import 'dart:convert';
import 'package:sealed_app/core/log.dart';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/infra/network/ohttp/ohttp_client.dart';

/// Dio interceptor that routes requests through an OHTTP gateway.
///
/// Two flavors exposed as factories:
///   * [OhttpInterceptor.algo]    — routes Algorand RPC + Algonode indexer
///     traffic through the Algonode OHTTP gateway. Rewrites the URI host to
///     the gateway upstream; allows `.onion` hosts to bypass (handled by
///     `TorSocksAdapter` instead).
///   * [OhttpInterceptor.indexer] — routes sealed-indexer traffic through the
///     Pi-hosted OHTTP gateway. Does NOT rewrite the URI (the gateway
///     forwards by path to the local indexer container).
///
/// Host whitelists are enforced fail-closed inside [_rewrite]: any host not on
/// the whitelist throws [OhttpException] before any network egress.
class OhttpInterceptor extends Interceptor {
  final OhttpClient _client;
  final Uri Function(Uri) _rewrite;
  final Uint8List? Function(RequestOptions) _extractBody;
  final bool _allowOnionBypass;
  final bool _arbitraryMethods;
  final bool _mergeContentType;
  final String _diagName;

  OhttpInterceptor._({
    required OhttpClient client,
    required Uri Function(Uri) rewrite,
    required Uint8List? Function(RequestOptions) extractBody,
    required bool allowOnionBypass,
    required bool arbitraryMethods,
    required bool mergeContentType,
    required String diagName,
  }) : _client = client,
       _rewrite = rewrite,
       _extractBody = extractBody,
       _allowOnionBypass = allowOnionBypass,
       _arbitraryMethods = arbitraryMethods,
       _mergeContentType = mergeContentType,
       _diagName = diagName;

  /// Algonode-routed interceptor. See class docs.
  factory OhttpInterceptor.algo({OhttpClient? ohttpClient}) {
    final algodHost = Uri.parse(ALGO_ALGOD_URL).host;
    final indexerHost = Uri.parse(ALGO_INDEXER_URL).host;
    return OhttpInterceptor._(
      client:
          ohttpClient ??
          OhttpClient(
            gatewayConfigUrl: OHTTP_GATEWAY_CONFIG_URL,
            relayUrl: OHTTP_RELAY_URL,
          ),
      rewrite: (original) {
        if (original.host != algodHost && original.host != indexerHost) {
          throw OhttpException(
            'AlgoOhttpInterceptor refusing host ${original.host}; '
            'expected $algodHost or $indexerHost',
          );
        }
        final targetUrl = original.host == indexerHost
            ? OHTTP_TARGET_INDEXER_URL
            : OHTTP_TARGET_RPC_URL;
        final targetHost = Uri.parse(targetUrl).host;
        return original.replace(scheme: 'https', host: targetHost, port: 443);
      },
      extractBody: _extractBodyBytes,
      allowOnionBypass: true,
      arbitraryMethods: false,
      mergeContentType: true,
      diagName: 'AlgoOhttpInterceptor',
    );
  }

  /// Pi-gateway sealed-indexer interceptor. See class docs.
  factory OhttpInterceptor.indexer({OhttpClient? ohttpClient}) {
    final indexerHost = Uri.parse(INDEXER_BASE_URL).host;
    return OhttpInterceptor._(
      client:
          ohttpClient ??
          OhttpClient(
            gatewayConfigUrl: PI_OHTTP_GATEWAY_CONFIG_URL,
            relayUrl: PI_OHTTP_RELAY_URL,
          ),
      rewrite: (original) {
        if (original.host != indexerHost) {
          throw OhttpException(
            'IndexerOhttpInterceptor refusing host ${original.host}; '
            'expected $indexerHost',
          );
        }
        return original;
      },
      extractBody: _extractBodyBytesOrJson,
      allowOnionBypass: false,
      arbitraryMethods: true,
      mergeContentType: false,
      diagName: 'IndexerOhttpInterceptor',
    );
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      if (_allowOnionBypass && options.uri.host.endsWith('.onion')) {
        return handler.next(options);
      }

      final targetUri = _rewrite(options.uri);
      final outHeaders = _extractHeaders(options);
      final outBody = _extractBody(options);

      final OhttpResponse ohttpResponse;
      if (options.method == 'GET') {
        ohttpResponse = await _client.get(targetUri, headers: outHeaders);
      } else if (options.method == 'POST') {
        ohttpResponse = await _client.post(
          targetUri,
          headers: outHeaders,
          body: outBody,
        );
      } else if (_arbitraryMethods) {
        // Indexer flavor supports arbitrary methods via OhttpClient.request.
        ohttpResponse = await _client.request(
          options.method,
          targetUri,
          headers: outHeaders,
          body: outBody,
        );
      } else {
        return handler.next(options);
      }

      final contentType = _findHeader(ohttpResponse.headers, 'content-type');
      final decoded = _decodeBody(ohttpResponse.body, contentType);

      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: ohttpResponse.statusCode,
          data: decoded,
          headers: Headers.fromMap(
            ohttpResponse.headers.map((k, v) => MapEntry(k, [v])),
          ),
        ),
      );
    } catch (e) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: e,
          message: '$_diagName request failed: $e',
        ),
      );
    }
  }

  Map<String, String> _extractHeaders(RequestOptions options) {
    final headers = <String, String>{};
    options.headers.forEach((key, value) {
      if (value != null) headers[key] = value.toString();
    });
    // dio stores Content-Type in options.contentType separately from headers.
    // Merge for algod msgpack endpoints that reject default application/json.
    if (_mergeContentType &&
        options.contentType != null &&
        options.contentType!.isNotEmpty) {
      headers['Content-Type'] = options.contentType!;
    }
    return headers;
  }

  void close() => _client.close();

  // ---------------------------------------------------------------------------
  // Shared body/header helpers
  // ---------------------------------------------------------------------------

  static String? _findHeader(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  static dynamic _decodeBody(Uint8List body, String? contentType) {
    if (body.isEmpty) return null;
    final ct = contentType?.toLowerCase() ?? '';
    try {
      if (ct.contains('application/json') || ct.contains('+json')) {
        return jsonDecode(utf8.decode(body));
      }
      if (ct.startsWith('text/')) return utf8.decode(body);
    } catch (e) {
      if (kDebugMode) {
        Log.d(
          '⚠️ OhttpInterceptor body decode failed '
          '(content-type=$contentType, ${body.length} bytes): $e',
        );
      }
    }
    return body;
  }

  /// Algo-style body extractor: bytes-or-string only.
  static Uint8List? _extractBodyBytes(RequestOptions options) {
    final raw = options.data;
    if (raw == null) return null;
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    if (raw is String) return Uint8List.fromList(raw.codeUnits);
    return null;
  }

  /// Indexer-style body extractor: bytes-or-string, plus Map/List → JSON.
  static Uint8List? _extractBodyBytesOrJson(RequestOptions options) {
    final raw = options.data;
    if (raw == null) return null;
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    if (raw is String) return Uint8List.fromList(utf8.encode(raw));
    if (raw is Map || raw is List) {
      return Uint8List.fromList(utf8.encode(jsonEncode(raw)));
    }
    return null;
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/remote/ohttp/ohttp_http_client.dart';

/// Dio interceptor that routes Algorand RPC + indexer requests through the
/// Algonode OHTTP gateway (`ohttp.nodely.io`) via the great-apple relay.
///
/// Host whitelist: ALGO_ALGOD_URL, ALGO_INDEXER_URL. Any other host is
/// rejected fail-closed — this interceptor must NOT be used for indexer
/// (sealed-pi) traffic; the Algonode gateway pins to Nodely upstreams and
/// would route a sealed-pi request to the wrong target. Use
/// `IndexerOhttpInterceptor` for sealed-indexer traffic.
class AlgoOhttpInterceptor extends Interceptor {
  final OhttpHttpClient _ohttpClient;

  AlgoOhttpInterceptor({OhttpHttpClient? ohttpClient})
    : _ohttpClient =
          ohttpClient ??
          OhttpHttpClient(
            gatewayConfigUrl: OHTTP_GATEWAY_CONFIG_URL,
            relayUrl: OHTTP_RELAY_URL,
          );

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      // Onion traffic is handled by TorSocksAdapter, not OHTTP.
      if (options.uri.host.endsWith('.onion')) {
        return handler.next(options);
      }

      // Fail-closed host whitelist. _rewriteUri throws on unknown hosts so a
      // misrouted request can't silently exfiltrate to Algonode.
      final originalUri = options.uri;
      final targetUri = _rewriteUri(originalUri);

      final OhttpResponse ohttpResponse;
      if (options.method == 'GET') {
        ohttpResponse = await _ohttpClient.get(
          targetUri,
          headers: _extractHeaders(options),
        );
      } else if (options.method == 'POST') {
        ohttpResponse = await _ohttpClient.post(
          targetUri,
          headers: _extractHeaders(options),
          body: _extractBody(options),
        );
      } else {
        return handler.next(options);
      }

      final contentType = _findHeader(ohttpResponse.headers, 'content-type');
      final dynamic decoded = _decodeBody(ohttpResponse.body, contentType);

      final response = Response(
        requestOptions: options,
        statusCode: ohttpResponse.statusCode,
        data: decoded,
        headers: Headers.fromMap(
          ohttpResponse.headers.map((k, v) => MapEntry(k, [v])),
        ),
      );

      handler.resolve(response);
    } catch (e) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: e,
          message: 'OHTTP request failed: $e',
        ),
      );
    }
  }

  String? _findHeader(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  dynamic _decodeBody(Uint8List body, String? contentType) {
    if (body.isEmpty) return null;
    final ct = contentType?.toLowerCase() ?? '';
    try {
      if (ct.contains('application/json') || ct.contains('+json')) {
        return jsonDecode(utf8.decode(body));
      }
      if (ct.startsWith('text/')) {
        return utf8.decode(body);
      }
    } catch (e) {
      if (kDebugMode) {
        print(
          '⚠️ AlgoOhttpInterceptor: body decode failed '
          '(content-type=$contentType, ${body.length} bytes): $e',
        );
      }
    }
    return body;
  }

  /// Rewrite Algonode URLs to OHTTP gateway upstreams. Fail-closed on any
  /// host outside the Algonode whitelist.
  Uri _rewriteUri(Uri original) {
    final algodSrcHost = Uri.parse(ALGO_ALGOD_URL).host;
    final indexerSrcHost = Uri.parse(ALGO_INDEXER_URL).host;
    if (original.host != algodSrcHost && original.host != indexerSrcHost) {
      throw OhttpException(
        'AlgoOhttpInterceptor refusing host ${original.host}; '
        'expected $algodSrcHost or $indexerSrcHost',
      );
    }
    final isIndexer = original.host == indexerSrcHost;
    final targetUrl = isIndexer
        ? OHTTP_TARGET_INDEXER_URL
        : OHTTP_TARGET_RPC_URL;
    final targetHost = Uri.parse(targetUrl).host;
    return original.replace(scheme: 'https', host: targetHost, port: 443);
  }

  Map<String, String> _extractHeaders(RequestOptions options) {
    final headers = <String, String>{};
    options.headers.forEach((key, value) {
      if (value != null) {
        headers[key] = value.toString();
      }
    });
    return headers;
  }

  Uint8List? _extractBody(RequestOptions options) {
    if (options.data == null) return null;
    if (options.data is Uint8List) return options.data;
    if (options.data is List<int>) return Uint8List.fromList(options.data);
    if (options.data is String) {
      return Uint8List.fromList((options.data as String).codeUnits);
    }
    return null;
  }

  void close() {
    _ohttpClient.close();
  }
}

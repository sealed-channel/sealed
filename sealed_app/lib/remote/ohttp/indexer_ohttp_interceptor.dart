import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/remote/ohttp/ohttp_http_client.dart';

/// Dio interceptor that routes sealed-indexer requests through the Pi-hosted
/// OHTTP gateway via the Oblivious.Network relay slug pinned to that gateway.
///
/// Host whitelist: INDEXER_BASE_URL only. Other hosts → fail-closed throw.
/// Unlike [AlgoOhttpInterceptor], this interceptor does NOT rewrite the
/// target URI — the Pi gateway forwards the inner request to the local
/// sealed-indexer container, so the client target stays sealed-pi.<tailnet>.
/// Path is forced to /gateway-relative form by [OhttpHttpClient] hitting the
/// PI relay URL; the encapsulated inner request preserves the original path.
class IndexerOhttpInterceptor extends Interceptor {
  final OhttpHttpClient _ohttpClient;

  IndexerOhttpInterceptor({OhttpHttpClient? ohttpClient})
    : _ohttpClient =
          ohttpClient ??
          OhttpHttpClient(
            gatewayConfigUrl: PI_OHTTP_GATEWAY_CONFIG_URL,
            relayUrl: PI_OHTTP_RELAY_URL,
          );

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      // Fail-closed host whitelist. Indexer interceptor must NEVER carry
      // Algorand traffic — pinned to a different gateway HPKE key.
      final indexerHost = Uri.parse(INDEXER_BASE_URL).host;
      if (options.uri.host != indexerHost) {
        throw OhttpException(
          'IndexerOhttpInterceptor refusing host ${options.uri.host}; '
          'expected $indexerHost',
        );
      }

      final OhttpResponse ohttpResponse;
      if (options.method == 'GET') {
        ohttpResponse = await _ohttpClient.get(
          options.uri,
          headers: _extractHeaders(options),
        );
      } else {
        ohttpResponse = await _ohttpClient.request(
          options.method,
          options.uri,
          headers: _extractHeaders(options),
          body: _extractBody(options),
        );
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
          message: 'Indexer OHTTP request failed: $e',
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
          '⚠️ IndexerOhttpInterceptor: body decode failed '
          '(content-type=$contentType, ${body.length} bytes): $e',
        );
      }
    }
    return body;
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
      return Uint8List.fromList(utf8.encode(options.data as String));
    }
    if (options.data is Map || options.data is List) {
      return Uint8List.fromList(utf8.encode(jsonEncode(options.data)));
    }
    return null;
  }

  void close() {
    _ohttpClient.close();
  }
}

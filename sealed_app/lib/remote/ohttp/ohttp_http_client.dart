import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'package:sealed_app/core/constants.dart';
import 'package:sealed_app/remote/ohttp/ohttp_config.dart';
import 'package:sealed_app/remote/ohttp/ohttp_encapsulator.dart';

/// HTTP client that routes requests through OHTTP for IP privacy.
///
/// Usage:
/// ```dart
/// final client = OhttpHttpClient();
/// final response = await client.get(
///   Uri.parse('https://testnet-api.4160.nodely.dev/v2/status'),
/// );
/// ```
///
/// The relay sees your IP but not the request content.
/// The gateway sees the request but not your IP.
class OhttpHttpClient {
  final String gatewayConfigUrl;
  final String relayUrl;
  final http.Client _httpClient;

  OhttpConfig? _cachedConfig;
  DateTime? _configFetchedAt;
  static const _configCacheDuration = Duration(minutes: 30);

  OhttpHttpClient({
    this.gatewayConfigUrl = OHTTP_GATEWAY_CONFIG_URL,
    this.relayUrl = OHTTP_RELAY_URL,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Make a GET request through OHTTP.
  Future<OhttpResponse> get(Uri url, {Map<String, String>? headers}) async {
    return _request('GET', url, headers: headers);
  }

  /// Make a POST request through OHTTP.
  Future<OhttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Uint8List? body,
  }) async {
    return _request('POST', url, headers: headers, body: body);
  }

  /// Make a request with an arbitrary method through OHTTP. Used by callers
  /// that need DELETE / PUT / PATCH semantics — the inner BHTTP request
  /// preserves the method end-to-end to the gateway upstream.
  Future<OhttpResponse> request(
    String method,
    Uri url, {
    Map<String, String>? headers,
    Uint8List? body,
  }) async {
    return _request(method, url, headers: headers, body: body);
  }

  /// Fetch and cache the gateway's OHTTP key configuration.
  Future<OhttpConfig> getConfig() async {
    if (_cachedConfig != null && _configFetchedAt != null) {
      final age = DateTime.now().difference(_configFetchedAt!);
      if (age < _configCacheDuration) {
        return _cachedConfig!;
      }
    }

    final response = await _httpClient.get(Uri.parse(gatewayConfigUrl));
    if (response.statusCode != 200) {
      throw OhttpException(
        'Failed to fetch OHTTP config: ${response.statusCode}',
      );
    }

    _cachedConfig = OhttpConfig.fromBytes(
      Uint8List.fromList(response.bodyBytes),
    );
    _configFetchedAt = DateTime.now();

    return _cachedConfig!;
  }

  /// Send a request through OHTTP relay.
  Future<OhttpResponse> _request(
    String method,
    Uri url, {
    Map<String, String>? headers,
    Uint8List? body,
  }) async {
    if (kDebugMode) {
      print(
        '[OHTTP] ▶ _request START method=$method url=$url '
        'bodyLen=${body?.length ?? 0}',
      );
      print('[OHTTP] ① fetching gateway config from $gatewayConfigUrl');
    }
    // 1. Get gateway config
    final config = await getConfig();
    if (kDebugMode) print('[OHTTP] ① config OK');
    final encapsulator = OhttpEncapsulator(config);

    // 2. Encapsulate the request
    if (kDebugMode) print('[OHTTP] ② encapsulating request');
    final encapsulated = await encapsulator.encapsulateRequest(
      method: method,
      targetUri: url,
      headers: headers ?? {},
      body: body,
    );
    if (kDebugMode) {
      print(
        '[OHTTP] ② encapsulated: '
        '${encapsulated.encapsulatedMessage.length} bytes',
      );
    }

    // 3. Send to relay
    if (kDebugMode) print('[OHTTP] ③ POST relay $relayUrl');
    final relayResponse = await _httpClient
        .post(
          Uri.parse(relayUrl),
          headers: {
            'Content-Type': 'message/ohttp-req',
            'Accept': 'message/ohttp-res',
          },
          body: encapsulated.encapsulatedMessage,
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () {
            if (kDebugMode) print('[OHTTP] ✖ relay POST timed out after 20s');
            throw OhttpException('Relay POST timeout (20s)');
          },
        );
    if (kDebugMode) {
      print(
        '[OHTTP] ③ relay response: status=${relayResponse.statusCode} '
        'bodyLen=${relayResponse.bodyBytes.length} '
        'content-type="${relayResponse.headers['content-type']}" '
        'allHeaders=${relayResponse.headers}',
      );
    }

    if (relayResponse.statusCode != 200) {
      throw OhttpException(
        'OHTTP relay error: ${relayResponse.statusCode} ${relayResponse.reasonPhrase}',
      );
    }

    // Sanity check: a real encapsulated response MUST carry
    // content-type: message/ohttp-res. If it doesn't, the relay/gateway
    // returned a plaintext error body and trying to AEAD-decrypt it will
    // fail with a confusing MAC error. Surface the real cause instead.
    final relayContentType =
        relayResponse.headers['content-type']?.toLowerCase() ?? '';
    if (!relayContentType.contains('message/ohttp-res')) {
      // Try to peek body as utf8 for diagnostics; fall back to hex prefix.
      String preview;
      try {
        preview = String.fromCharCodes(
          relayResponse.bodyBytes.take(256).toList(),
        );
      } catch (_) {
        preview = relayResponse.bodyBytes
            .take(32)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
      }
      throw OhttpException(
        'Relay returned non-encapsulated body '
        '(content-type=$relayContentType, '
        'len=${relayResponse.bodyBytes.length}): $preview',
      );
    }

    // 4. Decapsulate the response
    if (kDebugMode) print('[OHTTP] ④ decapsulating response');
    final binaryResponse = await encapsulator.decapsulateResponse(
      encryptedResponse: Uint8List.fromList(relayResponse.bodyBytes),
      enc: encapsulated.enc,
      secret: encapsulated.secret,
    );
    if (kDebugMode) {
      print(
        '[OHTTP] ④ decapsulated: status=${binaryResponse.statusCode} '
        'bodyLen=${binaryResponse.body.length}',
      );
    }

    return OhttpResponse(
      statusCode: binaryResponse.statusCode,
      headers: binaryResponse.headers,
      body: binaryResponse.body,
    );
  }

  void close() {
    _httpClient.close();
  }
}

/// Response from an OHTTP request.
class OhttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;

  OhttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  String get bodyString => String.fromCharCodes(body);

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Exception thrown by OHTTP operations.
class OhttpException implements Exception {
  final String message;
  OhttpException(this.message);

  @override
  String toString() => 'OhttpException: $message';
}

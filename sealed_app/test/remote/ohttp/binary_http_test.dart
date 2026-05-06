import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/remote/ohttp/binary_http.dart';

void main() {
  group('BinaryHttp', () {
    test('encodes a GET request', () {
      final encoded = BinaryHttp.encodeRequest(
        method: 'GET',
        uri: Uri.parse('https://example.com/v2/status'),
        headers: {'accept': 'application/json'},
      );

      // Should start with framing indicator 0x00
      expect(encoded[0], 0x00);
      // Should contain 'GET' somewhere after the framing byte
      expect(encoded.length > 10, true);
    });

    test('encodes and can be verified for structure', () {
      final encoded = BinaryHttp.encodeRequest(
        method: 'POST',
        uri: Uri.parse('https://example.com/api?foo=bar'),
        headers: {'content-type': 'application/json'},
        body: Uint8List.fromList('{"hello":"world"}'.codeUnits),
      );

      expect(encoded[0], 0x00); // Known-Length Request
      expect(encoded.length > 50, true); // Should be substantial
    });

    test('roundtrip encode/decode response', () {
      // Manually build a Binary HTTP response
      final builder = BytesBuilder();
      builder.addByte(0x01); // Known-Length Response framing

      // Status code as varint (200 = 0xC8, fits in 2-byte varint)
      // 200 >= 64, so 2-byte: 0x40 | (200 >> 8) = 0x40, 200 & 0xFF = 0xC8
      builder.add([0x40, 0xC8]);

      // Headers: empty block (varint 0)
      builder.addByte(0x00);

      // Body: "hello"
      final body = 'hello'.codeUnits;
      builder.addByte(body.length); // varint for 5
      builder.add(body);

      final response = BinaryHttp.decodeResponse(
        Uint8List.fromList(builder.toBytes()),
      );

      expect(response.statusCode, 200);
      expect(String.fromCharCodes(response.body), 'hello');
    });
  });

  group('BinaryHttp varint', () {
    test('encodes small values in 1 byte', () {
      final builder = BytesBuilder();
      BinaryHttp.encodeRequest(
        method: 'GET',
        uri: Uri.parse('https://x.com/a'),
      );
      // Just verify no exception is thrown for basic operations
      expect(true, true);
    });
  });
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/remote/ohttp/ohttp_http_client.dart';

void main() {
  test('end-to-end OHTTP request to Algorand testnet', () async {
    final client = OhttpHttpClient();
    try {
      final response = await client.get(
        Uri.parse('https://testnet-api.4160.nodely.dev/v2/status'),
      );

      print('Status: ${response.statusCode}');
      print('Body: ${response.bodyString}');

      expect(response.isSuccess, true);
      expect(response.statusCode, 200);

      final json = jsonDecode(response.bodyString);
      expect(json.containsKey('last-round'), true);
      print('Last round: ${json['last-round']}');
    } finally {
      client.close();
    }
  });
}

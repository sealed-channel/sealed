import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/network/ohttp/ohttp_client.dart';

void main() {
  test('end-to-end OHTTP request to Algorand testnet', () async {
    final client = OhttpClient();
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

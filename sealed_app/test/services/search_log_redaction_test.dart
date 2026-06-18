// test/services/search_log_redaction_test.dart
//
// Static regression: the search layer must never log the raw query string.
// If anyone ever adds a `print($trimmed)` / `log($query)` to one of these
// files, this test fails and blocks the change.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no search-layer file logs the raw query', () {
    final files = [
      'lib/services/search_service.dart',
      'lib/services/scopes/search_scope.dart',
      'lib/services/scopes/username_scope.dart',
      'lib/providers/search_provider.dart',
    ];

    final forbidden = RegExp(
      r'(print|log|debugPrint)\s*\([^)]*(\bquery\b|\btrimmed\b|\bq\b)',
      caseSensitive: false,
    );

    for (final path in files) {
      final src = File(path).readAsStringSync();
      expect(
        forbidden.hasMatch(src),
        isFalse,
        reason: '$path logs the raw query; redact before merging',
      );
    }
  });
}

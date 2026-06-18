import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Debug-gated logging. Compiled out in release builds (`kDebugMode` is a
/// const false in release, so the calls and their argument expressions are
/// tree-shaken away).
///
/// Rules:
/// - Raw `print` is banned in `lib/`. Use these helpers.
/// - Never pass secret key/seed/shared-secret bytes. Use [secretFp] for a
///   non-reversible fingerprint when you genuinely need to correlate values.
/// - Redact chain identities (wallet addresses, usernames) with [redactAddr].
class Log {
  const Log._();

  static void d(Object? message) {
    if (kDebugMode) {
      // ignore: avoid_print
      print(message);
    }
  }

  static void w(Object? message) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('⚠️ $message');
    }
  }

  static void e(String message, [Object? error, StackTrace? stack]) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('❌ $message${error != null ? ' err=$error' : ''}');
      if (stack != null) {
        // ignore: avoid_print
        print(stack.toString());
      }
    }
  }
}

/// Redacted form of a chain identity (wallet address / username) for logs.
/// Returns at most the first 6 characters. Safe in any build, but callers
/// should still only log via [Log] (debug-gated).
String redactAddr(String? value) {
  if (value == null || value.isEmpty) return '<none>';
  if (value.length <= 6) return '${value.substring(0, 1)}…';
  return '${value.substring(0, 6)}…';
}

/// Non-reversible fingerprint of secret bytes for debug correlation only.
/// Returns the first 6 base64 chars of SHA-256(bytes) — never the bytes
/// themselves. Returns `null-fp` for null input.
String secretFp(Uint8List? bytes) {
  if (bytes == null) return 'null-fp';
  final digest = sha256.convert(bytes);
  return base64.encode(digest.bytes).substring(0, 6);
}

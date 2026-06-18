import 'dart:convert';

import 'package:blockchain_utils/bip/address/algo_addr.dart';

/// Algorand addresses are 58 base32 characters (A–Z, 2–7, no padding).
const int _kAlgorandAddressLength = 58;
final RegExp _kBase32Charset = RegExp(r'^[A-Z2-7]+$');

/// Returns `true` when [s] is a syntactically and checksum-valid Algorand
/// address. False for `null`, empty, wrong length, lowercase, non-base32, or
/// any string that isn't a valid Algorand encoding.
bool isValidAlgorandAddress(String? s) {
  if (s == null) return false;
  if (s.length != _kAlgorandAddressLength) return false;
  if (!_kBase32Charset.hasMatch(s)) return false;
  // Checksum verification: AlgoAddrDecoder throws on invalid checksums.
  try {
    AlgoAddrDecoder().decodeAddr(s);
    return true;
  } catch (_) {
    return false;
  }
}

/// Extracts a checksum-valid Algorand address from any QR payload format the
/// major wallets emit, or returns `null`.
///
/// Accepted forms:
///   - bare 58-char address (Defly account QR, Pera "copy address");
///   - `algorand://ADDR` / `algorand:ADDR` URIs, with optional
///     `?amount=...&note=...` query (Pera/Defly receive & payment-request QRs,
///     Algorand URI spec / ARC-90) — query parameters are ignored;
///   - legacy Pera (Algorand Wallet) JSON `{"version":"1.0","address":"..."}`.
String? extractAlgorandAddress(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;

  if (isValidAlgorandAddress(s)) return s;

  // Algorand URI scheme — scheme is case-insensitive, address is not.
  if (s.toLowerCase().startsWith('algorand:')) {
    var rest = s.substring('algorand:'.length);
    if (rest.startsWith('//')) rest = rest.substring(2);
    final end = rest.indexOf(RegExp(r'[?#/]'));
    final candidate = (end == -1 ? rest : rest.substring(0, end)).trim();
    return isValidAlgorandAddress(candidate) ? candidate : null;
  }

  // Legacy Pera JSON receive QR.
  if (s.startsWith('{')) {
    try {
      final decoded = jsonDecode(s);
      final address = decoded is Map ? decoded['address'] : null;
      if (address is String && isValidAlgorandAddress(address.trim())) {
        return address.trim();
      }
    } catch (_) {
      // Not JSON — fall through.
    }
  }

  return null;
}

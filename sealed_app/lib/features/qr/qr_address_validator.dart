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

import 'package:blockchain_utils/bip/address/algo_addr.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sealed_app/features/qr/qr_address_validator.dart';

/// Generate a real, checksum-valid Algorand address from raw pubkey bytes
/// so tests don't hard-code a string that could become stale.
String _addressFor(List<int> pubkey) => AlgoAddrEncoder().encodeKey(pubkey);

void main() {
  group('isValidAlgorandAddress', () {
    final validZero = _addressFor(List<int>.filled(32, 0));
    final validOnes = _addressFor(List<int>.filled(32, 1));

    test('accepts a checksum-valid 58-char address', () {
      expect(isValidAlgorandAddress(validZero), isTrue);
      expect(isValidAlgorandAddress(validOnes), isTrue);
      expect(validZero.length, 58);
    });

    test('rejects null', () {
      expect(isValidAlgorandAddress(null), isFalse);
    });

    test('rejects empty', () {
      expect(isValidAlgorandAddress(''), isFalse);
    });

    test('rejects too short', () {
      expect(isValidAlgorandAddress(validZero.substring(0, 57)), isFalse);
    });

    test('rejects too long', () {
      expect(isValidAlgorandAddress('${validZero}A'), isFalse);
    });

    test('rejects lowercase characters', () {
      expect(isValidAlgorandAddress(validZero.toLowerCase()), isFalse);
    });

    test('rejects digits outside base32 (0, 1, 8, 9)', () {
      // Replace the first character with a non-base32 digit; length stays 58.
      final bad0 = '0${validZero.substring(1)}';
      final bad1 = '1${validZero.substring(1)}';
      final bad8 = '8${validZero.substring(1)}';
      final bad9 = '9${validZero.substring(1)}';
      expect(isValidAlgorandAddress(bad0), isFalse);
      expect(isValidAlgorandAddress(bad1), isFalse);
      expect(isValidAlgorandAddress(bad8), isFalse);
      expect(isValidAlgorandAddress(bad9), isFalse);
    });

    test('rejects sealed:// alias URI strings', () {
      expect(
        isValidAlgorandAddress('sealed://alias?c=secret&w=$validZero'),
        isFalse,
      );
    });

    test('rejects 58 valid base32 chars with bad checksum', () {
      // Build a varied pubkey so first two chars differ; swapping them then
      // breaks the checksum without changing length or charset.
      final varied = _addressFor(
        List<int>.generate(32, (i) => (i * 17 + 3) & 0xff),
      );
      expect(varied.length, 58);
      expect(varied[0] != varied[1], isTrue);
      final swapped =
          varied.substring(1, 2) + varied.substring(0, 1) + varied.substring(2);
      expect(isValidAlgorandAddress(swapped), isFalse);
    });
  });
}

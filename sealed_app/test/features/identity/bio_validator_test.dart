// Bio validator — mirrors contract BIO_MAX=160 BYTES (not chars).

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/identity/bio_validator.dart';

void main() {
  group('validateBio', () {
    test('empty is valid (clears bio)', () {
      expect(validateBio('').isValid, isTrue);
    });

    test('plain ascii under cap is valid', () {
      expect(validateBio('I am a friendly person.').isValid, isTrue);
    });

    test('exactly 160 ascii bytes is valid', () {
      expect(validateBio('a' * 160).isValid, isTrue);
    });

    test('161 ascii bytes is tooLong', () {
      final v = validateBio('a' * 161);
      expect(v.isValid, isFalse);
      expect(v.code, BioErrorCode.tooLong);
    });

    test('cap counts UTF-8 BYTES — 41 emoji (164 bytes) is tooLong', () {
      // '👋' is 4 UTF-8 bytes: 40 fit (160B), 41 do not.
      expect(validateBio('👋' * 40).isValid, isTrue);
      final v = validateBio('👋' * 41);
      expect(v.isValid, isFalse);
      expect(v.code, BioErrorCode.tooLong);
    });

    test('newlines allowed', () {
      expect(validateBio('line one\nline two').isValid, isTrue);
    });

    test('other control chars rejected', () {
      for (final s in ['tab\there', 'cr\rhere', 'null\x00byte', 'del\x7f']) {
        final v = validateBio(s);
        expect(v.isValid, isFalse, reason: 'should reject: $s');
        expect(v.code, BioErrorCode.controlChars);
      }
    });

    test('bioByteLength counts encoded width', () {
      expect(bioByteLength('abc'), 3);
      expect(bioByteLength('👋'), 4);
      expect(bioByteLength('héllo'), 6);
    });
  });
}

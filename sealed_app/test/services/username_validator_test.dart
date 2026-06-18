// Tests for username_validator. Mirrors the on-chain rules in
// programs/sealed/src/contract.algo.ts (validateNameFormat).

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/identity/username_validator.dart';

void main() {
  group('validateUsername — happy', () {
    for (final name in [
      'alice',
      'bob_42',
      'a_b',
      'abc',
      'user_123',
      'z9_z9_z9_z9_z9_z9_z9', // 20 chars
      '0alice',
      '1abc',
      '9foo',
      '123', // all digits
      '1_2', // digit-first with underscore
    ]) {
      test('accepts "$name"', () {
        final r = validateUsername(name);
        expect(
          r.isValid,
          true,
          reason: 'expected $name valid; got code=${r.code}',
        );
        expect(isValidUsername(name), true);
      });
    }
    test('accepts max-length 20 chars', () {
      expect(validateUsername('a' * 20).isValid, true);
    });
  });

  group('length', () {
    test('rejects empty', () {
      expect(validateUsername('').code, UsernameErrorCode.empty);
    });
    test('rejects 2 chars', () {
      expect(validateUsername('ab').code, UsernameErrorCode.badLen);
    });
    test(
      'accepts 3 chars',
      () => expect(validateUsername('abc').isValid, true),
    );
    test('rejects 21 chars', () {
      expect(validateUsername('a' * 21).code, UsernameErrorCode.badLen);
    });
  });

  group('first byte', () {
    test('rejects leading underscore', () {
      expect(
        validateUsername('_alice').code,
        UsernameErrorCode.leadingUnderscore,
      );
    });
  });

  group('last byte', () {
    test('rejects trailing underscore', () {
      expect(
        validateUsername('alice_').code,
        UsernameErrorCode.trailingUnderscore,
      );
    });
    test('accepts trailing digit', () {
      expect(validateUsername('alice9').isValid, true);
    });
  });

  group('charset', () {
    for (final n in ['Alice', 'al ice', 'al-ice', 'al.ice', 'al@ice']) {
      test('rejects "$n"', () {
        expect(validateUsername(n).code, UsernameErrorCode.badChar);
      });
    }
  });

  group('non-ascii', () {
    for (final n in ['αlice', 'ali😀ce', 'aliéce']) {
      test('rejects "$n" as notAscii', () {
        expect(validateUsername(n).code, UsernameErrorCode.notAscii);
      });
    }
  });

  group('reserved', () {
    for (final n in [
      'admin',
      'sealed',
      'support',
      'system',
      'root',
      'null',
      'undefined',
    ]) {
      test('rejects reserved "$n"', () {
        expect(validateUsername(n).code, UsernameErrorCode.reserved);
      });
    }
    test('accepts non-reserved adjacent', () {
      expect(validateUsername('admins').isValid, true);
      expect(
        validateUsername('sealed_').code,
        UsernameErrorCode.trailingUnderscore,
      );
      expect(validateUsername('sealed1').isValid, true);
    });
  });

  group('precedence', () {
    test('non-ascii beats length', () {
      expect(
        validateUsername('αbcdefghijklmnopqrstu').code,
        UsernameErrorCode.notAscii,
      );
    });
    test('length beats leading-underscore', () {
      expect(validateUsername('_a').code, UsernameErrorCode.badLen);
    });
    test('leading-underscore beats charset', () {
      expect(
        validateUsername('_1abc').code,
        UsernameErrorCode.leadingUnderscore,
      );
    });
    test('digit-first still rejects trailing-underscore', () {
      expect(
        validateUsername('1abc_').code,
        UsernameErrorCode.trailingUnderscore,
      );
    });
    test('trailing-underscore beats charset', () {
      expect(
        validateUsername('aBcD_').code,
        UsernameErrorCode.trailingUnderscore,
      );
    });
  });
}

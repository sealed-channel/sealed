/// Username format validator.
///
/// Mirrors the on-chain rules in `programs/sealed/src/contract.algo.ts`
/// (`validateNameFormat`) and the TS client lib `programs/sealed/src/lib/
/// username.ts`. Keep in sync.
///
/// Rules:
///   - charset: [a-z0-9_]
///   - length 3..20
///   - first char: not '_' (leading digit allowed)
///   - last char: not '_'
///   - reject hard-coded reserved names (off-chain only)
library;

const int kUsernameMinLen = 3;
const int kUsernameMaxLen = 20;

const Set<String> kReservedUsernames = {
  'admin',
  'sealed',
  'support',
  'system',
  'root',
  'null',
  'undefined',
};

enum UsernameErrorCode {
  empty,
  notAscii,
  badLen,
  badChar,
  leadingUnderscore,
  trailingUnderscore,
  reserved,
}

class UsernameValidation {
  const UsernameValidation.ok() : isValid = true, code = null;
  const UsernameValidation.err(this.code) : isValid = false;

  final bool isValid;
  final UsernameErrorCode? code;
}

final RegExp _kCharset = RegExp(r'^[a-z0-9_]+$');

/// Validate a candidate username. Caller should lowercase + trim first.
/// Returns first failure; does not aggregate.
UsernameValidation validateUsername(String name) {
  if (name.isEmpty) {
    return const UsernameValidation.err(UsernameErrorCode.empty);
  }

  // Reject any non-ASCII early so charset gate stays byte-clean.
  for (int i = 0; i < name.length; i++) {
    if (name.codeUnitAt(i) > 0x7f) {
      return const UsernameValidation.err(UsernameErrorCode.notAscii);
    }
  }

  if (name.length < kUsernameMinLen || name.length > kUsernameMaxLen) {
    return const UsernameValidation.err(UsernameErrorCode.badLen);
  }

  if (name.codeUnitAt(0) == 0x5f) {
    return const UsernameValidation.err(UsernameErrorCode.leadingUnderscore);
  }

  if (name.codeUnitAt(name.length - 1) == 0x5f) {
    return const UsernameValidation.err(UsernameErrorCode.trailingUnderscore);
  }

  if (!_kCharset.hasMatch(name)) {
    return const UsernameValidation.err(UsernameErrorCode.badChar);
  }

  if (kReservedUsernames.contains(name)) {
    return const UsernameValidation.err(UsernameErrorCode.reserved);
  }

  return const UsernameValidation.ok();
}

bool isValidUsername(String name) => validateUsername(name).isValid;

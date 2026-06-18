/// Bio format validator.
///
/// Mirrors the on-chain rule in `programs/sealed/src/contract.algo.ts`
/// (`setBio` → `BIO_MAX = 160`) and the TS client lib
/// `programs/sealed/src/lib/bio.ts`. Keep in sync.
///
/// Rules:
///   - length ≤ 160 BYTES of UTF-8 (multibyte chars count as encoded width —
///     an emoji is 4 bytes, not 1 char)
///   - empty allowed (clears the bio on-chain)
///   - `\n` allowed (multiline bios); all other control characters rejected
///     (client-side policy only — the contract validates length, nothing else)
library;

import 'dart:convert';

const int kBioMaxBytes = 160;

enum BioErrorCode { tooLong, controlChars }

class BioValidation {
  const BioValidation.ok() : isValid = true, code = null;
  const BioValidation.err(this.code) : isValid = false;

  final bool isValid;
  final BioErrorCode? code;
}

/// UTF-8 byte length of [bio] — what the contract caps, NOT char count.
int bioByteLength(String bio) => utf8.encode(bio).length;

BioValidation validateBio(String bio) {
  // Empty is valid: clears the on-chain bio.
  if (bio.isEmpty) return const BioValidation.ok();

  for (final cu in bio.codeUnits) {
    final isControl = (cu < 0x20 && cu != 0x0a) || cu == 0x7f;
    if (isControl) return const BioValidation.err(BioErrorCode.controlChars);
  }

  if (bioByteLength(bio) > kBioMaxBytes) {
    return const BioValidation.err(BioErrorCode.tooLong);
  }
  return const BioValidation.ok();
}

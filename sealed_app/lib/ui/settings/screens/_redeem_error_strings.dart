/// User-visible error strings for the redeem flow (PLAN-snark-redeem-B T12).
///
/// Centralized so QA / product can grep one file when tone-tweaking. Keep
/// terse, no jargon, never include the redeem code / preimage / wallet
/// address / nullifier in any string (PII leak surface). Adding a new code:
///   1. Throw a [RedeemContractError] with that code from the chain client
///      mapper, OR add a [SnarkProverErrorKind] entry.
///   2. Add an entry below.
///   3. Cover it in `redeem_code_dialog_test.dart`.
library;

import 'package:sealed_app/infra/zk/snark_prover.dart';

/// Stable map of error-code → user-visible string. Code keys are:
///   • TEAL assert reasons surfaced by `sealedChainClient._mapContractError`
///     for the SNARK redeem path (T5).
///   • `SnarkProverErrorKind.name` for prover-side failures (T8).
const Map<String, String> redeemErrorMessages = <String, String>{
  // Contract (T5) — SNARK redeem path.
  'BAD_PROOF': 'Could not verify this code. Try again or contact support.',
  'BAD_ROOT': 'This code is from an old batch that has expired.',
  'DOUBLE_SPEND': 'This code has already been redeemed.',
  'BAD_RECIPIENT': 'Wallet address does not match the code.',
  'BAD_DENOM': 'Code value mismatch. Contact support.',

  // Prover (T8) — `SnarkProverErrorKind`.
  'unavailable':
      'Anonymous redeem unavailable on this device. '
      'Falling back to standard redeem.',
  'cancelled': 'Redemption cancelled.',
  'generic': 'Something went wrong building the proof. Try again.',
  'oom':
      'Not enough memory to build the proof. '
      'Close other apps and retry.',
  'badInput': 'Something went wrong building the proof. Try again.',
  'badZkey': 'Something went wrong building the proof. Try again.',
  'witness': 'Something went wrong building the proof. Try again.',
};

/// Helper: look up a contract code (e.g. `BAD_PROOF`) → user string. Falls
/// back to a generic message — never leaks the raw code.
String redeemMessageForCode(String code) {
  return redeemErrorMessages[code] ?? 'Redeem failed. Try again.';
}

/// Helper: map a [SnarkProverErrorKind] to its user-visible string.
String redeemMessageForProverKind(SnarkProverErrorKind kind) {
  return redeemErrorMessages[kind.name] ??
      'Something went wrong building the proof. Try again.';
}

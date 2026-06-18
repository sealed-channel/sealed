/// Phase-4 LocalNet integration tests for the hybrid first-message path.
///
/// Status: **skeleton** — bodies are `skip`-marked until a Dart-side LocalNet
/// bootstrap helper is wired (deploy contract, fund accounts, post
/// commitments, redeem credits). The corresponding TS-side scaffolding lives
/// at `programs/sealed/src/__tests__/integration/_deploy.ts` +
/// `programs/sealed/src/scripts/`. Port pattern when ready:
///
///   1. Probe `http://localhost:4001/v2/status` with the LocalNet dev token;
///      `skip` the group if unreachable.
///   2. Read the deployed app id from `programs/sealed/stale.json` or accept
///      via env var (`SEALED_APP_ID`).
///   3. Generate two fresh accounts (Alice + Bob), fund both via dispenser.
///   4. Post a redeemable commitment via admin, run `redeem` so each has 1+
///      credit.
///   5. Publish each side's enc/scan/PQ keys via `publishKeys`.
///   6. Drive the actual flow through the real `SealedChainClient` +
///      `MessageSender` + `MessageSync`.
///
/// Until the bootstrap exists, these `skip` flags keep the test list visible
/// without failing CI. The unit-level coverage in
/// [`codec_test.dart`], [`kem_handshake_send_test.dart`],
/// [`kem_handshake_receive_test.dart`], [`sender_test.dart`], and
/// [`sync_test.dart`] already exercises every byte-level invariant; this
/// file's job is to prove the real AVM `log` opcode accepts a 992B frame
/// (+32B framing = 1024B logged) and that Bob's sync reconstructs the
/// payload bit-identically.
library;

import 'package:flutter_test/flutter_test.dart';

const _localNetSkipReason =
    'LocalNet bootstrap helper not yet wired on the Dart side. '
    'See file header for the bootstrap checklist; TS-side scaffolding '
    'in programs/sealed/__tests__/integration/_deploy.ts covers the same '
    'on-chain path until then.';

void main() {
  group('hybrid first message (LocalNet)', () {
    test(
      'hybrid first message: 1 credit, 1 sendMessage, correct decrypt',
      () async {
        // Task 4.1 — Alice sends a short hybrid first message to Bob.
        // Assertions:
        //   - Exactly 1 on-chain `sendMessage` txn.
        //   - Alice's credit count drops by exactly 1.
        //   - Bob's sync picks up the message with matching content + timestamp.
        //   - Bob's contact.pqSharedSecret(alice) is populated.
        //   - Subsequent Alice→Bob send uses the legacy 1-call path.
        fail('not implemented — see file header bootstrap notes');
      },
      skip: _localNetSkipReason,
    );

    test(
      'hybrid fallback: long first message uses legacy 2-call',
      () async {
        // Task 4.2 — Alice sends a >280-char first message to Bob.
        // Assertions:
        //   - Exactly 2 on-chain `sendMessage` txns.
        //   - Alice's credit delta = 2.
        //   - Bob receives the full message correctly.
        fail('not implemented — see file header bootstrap notes');
      },
      skip: _localNetSkipReason,
    );

    test('hybrid idempotency: double sync stores once', () async {
      // Task 4.3 — Alice sends a hybrid first message.
      // Bob's sync runs twice in a row.
      // Assertions:
      //   - messageCache contains exactly 1 row for the txid.
      //   - Cached pqSharedSecret bytes identical across both syncs.
      fail('not implemented — see file header bootstrap notes');
    }, skip: _localNetSkipReason);

    test(
      'hybrid tamper: corrupted ciphertext rejected silently',
      () async {
        // Task 4.4 — Alice sends a hybrid first message. Test harness
        // replays the same on-chain blob with 1 byte flipped after the
        // AES-GCM tag offset.
        // Assertions:
        //   - Bob's sync skips the tampered frame (no exception bubbled).
        //   - Bob's messageCache is empty for that txid.
        //   - Bob's contact.pqSharedSecret(alice) remains null (no
        //     half-cached state from a tampered KEM half).
        fail('not implemented — see file header bootstrap notes');
      },
      skip: _localNetSkipReason,
    );
  });
}

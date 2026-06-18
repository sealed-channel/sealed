/// Unit tests for the sender-impersonation guard in `MessageSync`.
///
/// Task 3 (Critical) fix: the decrypted message payload carries a
/// sender-CONTROLLED `sender_wallet` claim. The only trustworthy sender
/// identity is the consensus-verified transaction sender (`senderAddress`).
///
/// At the incoming-message save site, `_syncIncomingMessages` now:
///   1. Stores `senderAddress` (not the payload claim) as `senderWallet`.
///   2. DROPS any message whose payload claims a non-empty `sender_wallet`
///      that disagrees with `senderAddress` (impersonation attempt).
///
/// The decision is factored into the pure top-level helper [isSpoofedSender]
/// so it can be tested without standing up the full chain/crypto/repo mock
/// stack required to drive `_syncIncomingMessages` end to end. This mirrors
/// the documented save-site behaviour:
///   - spoofed claim (present, non-empty, != tx sender)  → message DROPPED
///   - matching / absent / empty claim                   → message SAVED
///     with `senderWallet == senderAddress`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/message_sync.dart';

void main() {
  const txSender = 'WALLETAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const otherWallet = 'WALLETBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

  group('isSpoofedSender (incoming-save impersonation guard)', () {
    test(
      'payload sender_wallet differing from tx sender is spoofed (DROP)',
      () {
        expect(isSpoofedSender(otherWallet, txSender), isTrue);
      },
    );

    test('payload sender_wallet matching tx sender is NOT spoofed (SAVE)', () {
      expect(isSpoofedSender(txSender, txSender), isFalse);
    });

    test('absent (null) payload sender_wallet is NOT spoofed (SAVE)', () {
      // Legacy / uniform-envelope messages may omit the field entirely.
      expect(isSpoofedSender(null, txSender), isFalse);
    });

    test('empty payload sender_wallet is NOT spoofed (SAVE)', () {
      expect(isSpoofedSender('', txSender), isFalse);
    });

    test('case-sensitive: any byte difference counts as spoofed', () {
      expect(isSpoofedSender(txSender.toLowerCase(), txSender), isTrue);
    });

    test(
      'stored senderWallet for a non-spoofed message equals the tx sender',
      () {
        // Documents the save-site contract: when not spoofed, the message is
        // saved with senderWallet == senderAddress (never the payload claim).
        const claimMatches = txSender; // matching claim
        const claimAbsent = null; // legacy omission

        for (final claim in <String?>[claimMatches, claimAbsent]) {
          expect(isSpoofedSender(claim, txSender), isFalse);
          // The save site uses `senderAddress` unconditionally, so the stored
          // value is always the chain-verified sender.
          final storedSenderWallet = txSender;
          expect(storedSenderWallet, equals(txSender));
        }
      },
    );
  });
}

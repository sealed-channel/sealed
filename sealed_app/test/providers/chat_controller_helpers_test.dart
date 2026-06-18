import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/models/message.dart';
import 'package:sealed_app/providers/chat_controller.dart';

void main() {
  final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);

  DecryptedMessage dm(
    String id, {
    required String content,
    required bool out,
    int minute = 0,
  }) =>
      DecryptedMessage(
        id: id,
        senderWallet: out ? 'me' : 'them',
        recipientWallet: out ? 'them' : 'me',
        content: content,
        timestamp: base.add(Duration(minutes: minute)),
        isOutgoing: out,
        onChainPubkey: '',
      );

  group('formatWalletShort', () {
    test('short address unchanged', () {
      expect(formatWalletShort('ABC'), 'ABC');
    });
    test('long address elided', () {
      final w = 'A' * 58;
      expect(formatWalletShort(w), 'AAAAAA...AAAAAA');
    });
  });

  group('mapDecryptedToVms', () {
    test('maps fields and flags pending by id prefix', () {
      final vms = mapDecryptedToVms([
        dm('pending-1', content: 'hi', out: true),
        dm('x', content: 'yo', out: false),
      ]);
      expect(vms.length, 2);
      expect(vms[0].isPending, isTrue);
      expect(vms[0].isOutgoing, isTrue);
      expect(vms[1].isPending, isFalse);
      expect(vms[1].content, 'yo');
    });

    test('drops alias invite/accept envelopes', () {
      final vms = mapDecryptedToVms([
        dm('a', content: 'real', out: false),
        dm('b', content: 'sealed://alias?c=x&w=y', out: false),
        dm('c', content: 'sealed://alias-envelope?b=z', out: false),
      ]);
      expect(vms.map((v) => v.id), ['a']);
    });
  });

  group('mergeAndGroup', () {
    test('merges pending, sorts chronological, groups', () {
      final saved = mapDecryptedToVms([
        dm('a', content: 'one', out: true, minute: 0),
        dm('b', content: 'two', out: true, minute: 1),
      ]);
      final pending = mapDecryptedToVms([
        dm('pending-9', content: 'three', out: true, minute: 2),
      ]);
      final groups = mergeAndGroup(saved, pending);
      expect(groups.length, 3);
      // Chronological order preserved.
      expect(groups.map((g) => g.message.content), ['one', 'two', 'three']);
      // Same outgoing run within window → single status, on the last (pending →
      // suppressed), so zero "Sent" here because the last is pending.
      expect(groups.last.message.isPending, isTrue);
      expect(groups.last.showStatus, isFalse);
    });

    test('empty saved + empty pending → empty', () {
      expect(mergeAndGroup([], []), isEmpty);
    });
  });
}

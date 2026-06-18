import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/features/messaging/chat_message_vm.dart';
import 'package:sealed_app/features/messaging/message_grouping.dart';

void main() {
  final base = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);

  ChatMessageVM msg(
    String id, {
    required bool out,
    required int minute,
    bool pending = false,
    String content = 'hi',
  }) => ChatMessageVM(
    id: id,
    content: content,
    isOutgoing: out,
    timestamp: base.add(Duration(minutes: minute)),
    isPending: pending,
  );

  group('groupMessages', () {
    test('empty list → empty', () {
      expect(groupMessages([]), isEmpty);
    });

    test('single message → first, last, timestamp, status', () {
      final g = groupMessages([msg('a', out: true, minute: 0)]).single;
      expect(g.isFirstInGroup, isTrue);
      expect(g.isLastInGroup, isTrue);
      expect(g.showTimestamp, isTrue);
      expect(g.showStatus, isTrue); // outgoing, last of run, not pending
    });

    test('run of 3 same-sender within window → one timestamp, one status', () {
      final g = groupMessages([
        msg('a', out: true, minute: 0),
        msg('b', out: true, minute: 1),
        msg('c', out: true, minute: 2),
      ]);
      expect(g.map((e) => e.showTimestamp).toList(), [true, false, false]);
      expect(g.map((e) => e.isFirstInGroup).toList(), [true, false, false]);
      expect(g.map((e) => e.isLastInGroup).toList(), [false, false, true]);
      // Exactly one "Sent" — only on the last of the run.
      expect(g.where((e) => e.showStatus).length, 1);
      expect(g.last.showStatus, isTrue);
    });

    test('sender alternation → each is its own group', () {
      final g = groupMessages([
        msg('a', out: true, minute: 0),
        msg('b', out: false, minute: 1),
        msg('c', out: true, minute: 2),
      ]);
      expect(g.every((e) => e.isFirstInGroup && e.isLastInGroup), isTrue);
      // Status only on outgoing messages.
      expect(g.map((e) => e.showStatus).toList(), [true, false, true]);
    });

    test('>= 5 min gap breaks the group even for same sender', () {
      final g = groupMessages([
        msg('a', out: true, minute: 0),
        msg('b', out: true, minute: 5), // exactly window → new group
      ]);
      expect(g[0].isLastInGroup, isTrue);
      expect(g[1].isFirstInGroup, isTrue);
      expect(g.where((e) => e.showStatus).length, 2);
    });

    test('pending last message suppresses status', () {
      final g = groupMessages([
        msg('a', out: true, minute: 0),
        msg('b', out: true, minute: 1, pending: true),
      ]);
      expect(g.last.isLastInGroup, isTrue);
      expect(g.last.showStatus, isFalse); // pending → no "Sent"
    });
  });

  group('isAliasInviteEnvelope', () {
    test('detects invite + envelope prefixes', () {
      expect(isAliasInviteEnvelope('sealed://alias?c=abc&w=xyz'), isTrue);
      expect(isAliasInviteEnvelope('sealed://alias-envelope?d=abc'), isTrue);
    });

    test('plain message is not an envelope', () {
      expect(isAliasInviteEnvelope('hello world'), isFalse);
      expect(isAliasInviteEnvelope('sealed://other'), isFalse);
    });

    test('filtering a stream drops only envelopes', () {
      final raw = [
        msg('a', out: false, minute: 0, content: 'real msg'),
        msg('b', out: false, minute: 1, content: 'sealed://alias?c=x&w=y'),
        msg('c', out: true, minute: 2, content: 'sealed://alias-envelope?d=z'),
        msg('d', out: true, minute: 3, content: 'another real'),
      ];
      final filtered = raw
          .where((m) => !isAliasInviteEnvelope(m.content))
          .toList();
      expect(filtered.map((m) => m.id), ['a', 'd']);
    });
  });
}

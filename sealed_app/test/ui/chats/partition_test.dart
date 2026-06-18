import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/models/chat_preview.dart';
import 'package:sealed_app/models/contact.dart';
import 'package:sealed_app/ui/chats/partition.dart';

void main() {
  ChatPreview wallet(
    String w, {
    bool blocked = false,
    int messageCount = 2,
    String last = 'hello',
    int ts = 1000,
  }) => ChatPreview(
    contactWallet: w,
    messageCount: messageCount,
    lastMessageContent: last,
    lastMessageTimestamp: ts,
    isBlocked: blocked,
  );

  Uint8List _b(int v) => Uint8List.fromList(List.filled(32, v));

  ChatPreview alias(String id, {int ts = 2000}) => ChatPreview(
    aliasContact: AliasContact(
      contactId: id,
      createdAt: 1,
      aliasHandle: 'Ghost',
      inviteRef: 'ref_$id',
      isCreator: false,
      keys: ContactKeys(
        sharedSecret: _b(1),
        recipientTag: _b(2),
        msgKey: _b(3),
        peerX25519Pub: _b(4),
        peerX25519Scan: _b(5),
        myX25519Sk: _b(6),
        myX25519ScanSk: _b(7),
        tagSalt: _b(8),
      ),
    ),
    lastMessageTimestamp: ts,
  );

  group('partitionChats routing', () {
    test('hybrid wallet → chats', () {
      final p = partitionChats([wallet('AAA')]);
      expect(p.regularChats.map((e) => e.contactWallet), ['AAA']);
      expect(p.spamChats, isEmpty);
    });

    test('unblocked wallet → chats (spam = blocked only)', () {
      final p = partitionChats([wallet('CCC')]);
      expect(p.regularChats.map((e) => e.contactWallet), ['CCC']);
      expect(p.spamChats, isEmpty);
    });

    test('blocked wallet → spam', () {
      final p = partitionChats([wallet('BBB', blocked: true)]);
      expect(p.spamChats.map((e) => e.contactWallet), ['BBB']);
      expect(p.regularChats, isEmpty);
    });

    test('alias preview → aliasChats', () {
      final p = partitionChats([alias('c1')]);
      expect(p.aliasChats.length, 1);
      expect(p.regularChats, isEmpty);
      expect(p.spamChats, isEmpty);
    });
  });

  group('partitionChats invite-stub exclusion', () {
    test('single-message invite stub is dropped from rows', () {
      final p = partitionChats([
        wallet('S1', messageCount: 1, last: 'sealed://alias?c=x&w=y'),
        wallet('S2', messageCount: 1, last: 'sealed://alias-envelope?b=zzz'),
      ]);
      expect(p.regularChats, isEmpty);
      expect(p.spamChats, isEmpty);
    });

    test(
      'conversation with real DMs is kept even if last msg looks like a stub',
      () {
        final p = partitionChats([
          wallet('R1', messageCount: 3, last: 'sealed://alias-envelope?b=zzz'),
        ]);
        expect(p.regularChats.map((e) => e.contactWallet), ['R1']);
      },
    );
  });

  test('buckets sorted newest-first', () {
    final p = partitionChats([wallet('old', ts: 100), wallet('new', ts: 900)]);
    expect(p.regularChats.map((e) => e.contactWallet), ['new', 'old']);
  });
}

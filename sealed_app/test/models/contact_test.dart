/// T3 — Contact / AliasContact / ContactKeys round-trip tests.
///
/// Verifies:
///  - `ContactKeys.fromRow` / `toRow` round-trip preserves all 11 fields
///  - `Contact.fromRow` returns plain `Contact` when `is_alias=0`
///  - `Contact.fromRow` returns `AliasContact` when `is_alias=1`
///  - `toRow` round-trips both kinds without bit-level data loss
///  - `peerMlkemPub` / `myMlkemSk` / `pqSharedSecret` accept null
///  - `kind` defaults to `wallet`; alias subclass forces `kind=alias`
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/models/contact.dart';

Uint8List _b(int len, int seed) =>
    Uint8List.fromList(List.generate(len, (i) => (i + seed) & 0xff));

ContactKeys _keys({int seed = 0, bool pq = true, Uint8List? pqShared}) =>
    ContactKeys(
      sharedSecret: _b(32, seed + 1),
      recipientTag: _b(32, seed + 2),
      msgKey: _b(32, seed + 3),
      peerX25519Pub: _b(32, seed + 4),
      peerX25519Scan: _b(32, seed + 5),
      peerMlkemPub: pq ? _b(800, seed + 6) : null,
      myX25519Sk: _b(32, seed + 7),
      myX25519ScanSk: _b(32, seed + 8),
      myMlkemSk: pq ? _b(1632, seed + 9) : null,
      tagSalt: _b(16, seed + 10),
      pqSharedSecret: pqShared,
    );

void main() {
  group('ContactKeys', () {
    test('toRow + fromRow round-trip preserves all fields', () {
      final original = _keys(seed: 100, pqShared: _b(32, 111));
      final restored = ContactKeys.fromRow(original.toRow());
      expect(restored.sharedSecret, equals(original.sharedSecret));
      expect(restored.recipientTag, equals(original.recipientTag));
      expect(restored.msgKey, equals(original.msgKey));
      expect(restored.peerX25519Pub, equals(original.peerX25519Pub));
      expect(restored.peerX25519Scan, equals(original.peerX25519Scan));
      expect(restored.peerMlkemPub, equals(original.peerMlkemPub));
      expect(restored.myX25519Sk, equals(original.myX25519Sk));
      expect(restored.myX25519ScanSk, equals(original.myX25519ScanSk));
      expect(restored.myMlkemSk, equals(original.myMlkemSk));
      expect(restored.tagSalt, equals(original.tagSalt));
      expect(restored.pqSharedSecret, equals(original.pqSharedSecret));
    });

    test('classical-only (null PQ fields) round-trips', () {
      final classical = _keys(seed: 200, pq: false);
      final restored = ContactKeys.fromRow(classical.toRow());
      expect(restored.peerMlkemPub, isNull);
      expect(restored.myMlkemSk, isNull);
      expect(restored.pqSharedSecret, isNull);
    });

    test('copyWith updates only specified fields', () {
      final k = _keys(seed: 300);
      final updated = k.copyWith(pqSharedSecret: _b(32, 99));
      expect(updated.pqSharedSecret, equals(_b(32, 99)));
      expect(updated.peerX25519Pub, equals(k.peerX25519Pub));
      expect(updated.myMlkemSk, equals(k.myMlkemSk));
    });
  });

  group('Contact (wallet kind)', () {
    test('fromRow with is_alias=0 returns plain Contact', () {
      final row = <String, Object?>{
        'contact_id': 'walletA',
        'is_alias': 0,
        'wallet_address': 'ALICEWALLET',
        'alias_label': 'Alice',
        'alias_display': null,
        'invite_ref': null,
        'is_creator': null,
        'created_at': 12345,
        ..._keys(seed: 0).toRow(),
      };
      final c = Contact.fromRow(row);
      expect(c, isA<Contact>());
      expect(c, isNot(isA<AliasContact>()));
      expect(c.kind, ContactKind.wallet);
      expect(c.walletAddress, 'ALICEWALLET');
      expect(c.keys.peerMlkemPub, isNotNull);
    });

    test('toRow round-trip preserves identity + keys', () {
      final original = Contact(
        contactId: 'w1',
        walletAddress: 'WALLET',
        nickname: 'Bob',
        createdAt: 99,
        keys: _keys(seed: 400, pq: false),
      );
      final row = original.toRow();
      expect(row['is_alias'], 0);
      expect(row['wallet_address'], 'WALLET');
      expect(row['alias_label'], 'Bob');
      final restored = Contact.fromRow(row);
      expect(restored, isNot(isA<AliasContact>()));
      expect(restored.contactId, 'w1');
      expect(restored.nickname, 'Bob');
      expect(restored.keys.peerMlkemPub, isNull);
      expect(restored.keys.myMlkemSk, isNull);
      expect(
        restored.keys.peerX25519Scan,
        equals(original.keys.peerX25519Scan),
      );
    });

    test('default kind is wallet', () {
      final c = Contact(contactId: 'x', createdAt: 0, keys: _keys());
      expect(c.kind, ContactKind.wallet);
      expect(c.nickname, isNull);
    });

    test('null nickname round-trips through empty-string sentinel', () {
      final original = Contact(
        contactId: 'w2',
        walletAddress: 'W2',
        createdAt: 1,
        keys: _keys(seed: 1, pq: false),
      );
      final row = original.toRow();
      expect(row['alias_label'], '');
      final restored = Contact.fromRow(row);
      expect(restored.nickname, isNull);
    });
  });

  group('AliasContact', () {
    test('fromRow with is_alias=1 returns AliasContact', () {
      final row = <String, Object?>{
        'contact_id': 'aliasA',
        'is_alias': 1,
        'wallet_address': null,
        'alias_label': 'a',
        'alias_display': 'Stranger',
        'invite_ref': 'deadbeef',
        'is_creator': 1,
        'created_at': 555,
        ..._keys(seed: 500, pq: false).toRow(),
      };
      final c = Contact.fromRow(row);
      expect(c, isA<AliasContact>());
      final a = c as AliasContact;
      expect(a.kind, ContactKind.alias);
      expect(a.walletAddress, isNull);
      expect(a.aliasHandle, 'Stranger');
      expect(a.inviteRef, 'deadbeef');
      expect(a.isCreator, isTrue);
      expect(a.keys.peerMlkemPub, isNull);
      expect(a.nickname, 'a');
    });

    test('toRow writes is_alias=1 + alias-only columns', () {
      final a = AliasContact(
        contactId: 'a1',
        nickname: 'a',
        createdAt: 1,
        keys: _keys(seed: 600, pqShared: _b(32, 700)),
        aliasHandle: 'Anon42',
        inviteRef: 'cafe',
        isCreator: false,
      );
      final row = a.toRow();
      expect(row['is_alias'], 1);
      expect(row['wallet_address'], isNull);
      expect(row['alias_display'], 'Anon42');
      expect(row['invite_ref'], 'cafe');
      expect(row['is_creator'], 0);
      expect(row['pq_shared_secret'], equals(_b(32, 700)));
    });

    test('toRow + fromRow round-trip on AliasContact preserves all fields', () {
      final original = AliasContact(
        contactId: 'a2',
        nickname: 'a',
        createdAt: 2,
        keys: _keys(seed: 800, pqShared: _b(32, 41)),
        aliasHandle: 'Ghost',
        inviteRef: 'beef',
        isCreator: true,
      );
      final restored = Contact.fromRow(original.toRow()) as AliasContact;
      expect(restored.contactId, 'a2');
      expect(restored.aliasHandle, 'Ghost');
      expect(restored.inviteRef, 'beef');
      expect(restored.isCreator, isTrue);
      expect(restored.nickname, 'a');
      expect(restored.keys.peerMlkemPub, equals(original.keys.peerMlkemPub));
      expect(restored.keys.myMlkemSk, equals(original.keys.myMlkemSk));
      expect(restored.keys.pqSharedSecret, equals(_b(32, 41)));
      expect(
        restored.keys.peerX25519Scan,
        equals(original.keys.peerX25519Scan),
      );
      expect(
        restored.keys.myX25519ScanSk,
        equals(original.keys.myX25519ScanSk),
      );
    });

    test('null nickname on alias round-trips', () {
      final a = AliasContact(
        contactId: 'a4',
        createdAt: 7,
        keys: _keys(seed: 900),
        aliasHandle: 'NoNick',
        inviteRef: 'r',
        isCreator: true,
      );
      final row = a.toRow();
      expect(row['alias_label'], '');
      final restored = Contact.fromRow(row) as AliasContact;
      expect(restored.nickname, isNull);
      expect(restored.aliasHandle, 'NoNick');
    });

    test('kind is forced to alias regardless of usage', () {
      final a = AliasContact(
        contactId: 'a3',
        nickname: 'a',
        createdAt: 0,
        keys: _keys(),
        aliasHandle: 'x',
        inviteRef: 'y',
        isCreator: false,
      );
      expect(a.kind, ContactKind.alias);
      expect(a.walletAddress, isNull);
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/infra/local/repositories/local_user_repository.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_db.dart';

void main() {
  sqfliteFfiInit();

  late TestLocalDatabase testDb;
  late LocalUserRepository repo;

  setUp(() async {
    testDb = await TestLocalDatabase.open();
    repo = LocalUserRepositoryImpl(testDb);
  });

  tearDown(() async {
    await testDb.close();
  });

  UserProfile _makeProfile(String wallet, {String? username}) => UserProfile(
    walletAddress: wallet,
    username: username,
    encryptionPubkey: Uint8List(32),
    scanPubkey: Uint8List(32),
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  group('LocalUserRepository', () {
    // ── getLocalUser ──────────────────────────────────────────────────────────

    test('getLocalUser returns null when table empty', () async {
      final result = await repo.getLocalUser();
      expect(result, isNull);
    });

    test('getLocalUser returns saved profile (no wallet filter)', () async {
      final profile = _makeProfile('AAAA');
      await repo.saveLocalUser(profile);

      final result = await repo.getLocalUser();
      expect(result?.walletAddress, 'AAAA');
    });

    test('getLocalUser with walletAddress returns matching profile', () async {
      await repo.saveLocalUser(_makeProfile('AAAA'));
      await repo.saveLocalUser(_makeProfile('BBBB'));

      final result = await repo.getLocalUser(walletAddress: 'BBBB');
      expect(result?.walletAddress, 'BBBB');
    });

    test('getLocalUser with wrong wallet returns null', () async {
      await repo.saveLocalUser(_makeProfile('AAAA'));
      final result = await repo.getLocalUser(walletAddress: 'ZZZZ');
      expect(result, isNull);
    });

    // ── saveLocalUser ─────────────────────────────────────────────────────────

    test('saveLocalUser replaces on conflict', () async {
      await repo.saveLocalUser(_makeProfile('AAAA', username: 'alice'));
      await repo.saveLocalUser(_makeProfile('AAAA', username: 'alice2'));

      final result = await repo.getLocalUser(walletAddress: 'AAAA');
      expect(result?.username, 'alice2');
    });

    // ── deleteLocalUser ───────────────────────────────────────────────────────

    test('deleteLocalUser removes all rows', () async {
      await repo.saveLocalUser(_makeProfile('AAAA'));
      await repo.deleteLocalUser();

      final result = await repo.getLocalUser();
      expect(result, isNull);
    });

    test('deleteLocalUser on empty table does not throw', () async {
      await expectLater(repo.deleteLocalUser(), completes);
    });

    // ── updateLastLogin ───────────────────────────────────────────────────────

    test('updateLastLogin does not throw', () async {
      await repo.saveLocalUser(_makeProfile('AAAA'));
      await expectLater(repo.updateLastLogin('AAAA'), completes);
    });

    test('updateLastLogin on missing wallet does not throw', () async {
      await expectLater(repo.updateLastLogin('ZZZZ'), completes);
    });
  });
}

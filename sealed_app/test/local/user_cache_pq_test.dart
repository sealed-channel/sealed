import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/local/user_cache.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A [LocalDatabase] subclass that returns a fresh in-memory SQLite database
/// for testing purposes, bypassing the static file-backed singleton.
class _TestLocalDatabase extends LocalDatabase {
  final Database _db;
  _TestLocalDatabase(this._db);

  @override
  Future<Database> get database async => _db;
}

/// Create the minimal contacts_cache schema in an in-memory SQLite database.
Future<Database> _openTestDatabase() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 1),
  );
  await db.execute('''
    CREATE TABLE contacts_cache (
      wallet_address TEXT PRIMARY KEY,
      username TEXT,
      display_name TEXT,
      encryption_pubkey BLOB NOT NULL,
      scan_pubkey BLOB NOT NULL,
      created_at INTEGER NOT NULL,
      cached_at INTEGER DEFAULT (strftime('%s', 'now')),
      pq_public_key BLOB,
      pq_shared_secret BLOB
    )
  ''');
  return db;
}

/// Insert a minimal contact row so UPDATE queries have a row to update.
Future<void> _insertContact(Database db, String walletAddress) async {
  await db.insert('contacts_cache', {
    'wallet_address': walletAddress,
    'encryption_pubkey': Uint8List(32),
    'scan_pubkey': Uint8List(32),
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Database rawDb;
  late UserCache userCache;

  setUp(() async {
    rawDb = await _openTestDatabase();
    userCache = UserCache(_TestLocalDatabase(rawDb));
  });

  tearDown(() async {
    await rawDb.close();
  });

  group('UserCache PQ operations', () {
    const walletA = 'ALGORANDADDR1234567890ABCDEF1234567890ABCDEF12345678901';

    // =========================================================================
    // getContactPqPublicKey
    // =========================================================================
    group('getContactPqPublicKey', () {
      test('returns null when wallet address is unknown', () async {
        final result = await userCache.getContactPqPublicKey(walletA);
        expect(result, isNull);
      });

      test('returns null when key not yet set on known contact', () async {
        await _insertContact(rawDb, walletA);
        final result = await userCache.getContactPqPublicKey(walletA);
        expect(result, isNull);
      });

      test('returns saved 800-byte PQ public key', () async {
        await _insertContact(rawDb, walletA);
        final pubKey = Uint8List(800)..fillRange(0, 800, 0xAB);
        await userCache.savePqPublicKey(walletA, pubKey);
        final loaded = await userCache.getContactPqPublicKey(walletA);
        expect(loaded, isNotNull);
        expect(loaded, equals(pubKey));
      });
    });

    // =========================================================================
    // getContactPqSharedSecret
    // =========================================================================
    group('getContactPqSharedSecret', () {
      test('returns null when wallet address is unknown', () async {
        final result = await userCache.getContactPqSharedSecret(walletA);
        expect(result, isNull);
      });

      test('returns null when secret not yet set on known contact', () async {
        await _insertContact(rawDb, walletA);
        final result = await userCache.getContactPqSharedSecret(walletA);
        expect(result, isNull);
      });

      test('returns saved 32-byte PQ shared secret', () async {
        await _insertContact(rawDb, walletA);
        final secret = Uint8List(32)..fillRange(0, 32, 0xCC);
        await userCache.savePqSharedSecret(walletA, secret);
        final loaded = await userCache.getContactPqSharedSecret(walletA);
        expect(loaded, isNotNull);
        expect(loaded, equals(secret));
      });
    });

    // =========================================================================
    // savePqPublicKey / savePqSharedSecret — update behaviour
    // =========================================================================
    group('save overwrites previous value', () {
      test('savePqPublicKey second call overwrites first', () async {
        await _insertContact(rawDb, walletA);
        final pk1 = Uint8List(800)..fillRange(0, 800, 0x11);
        final pk2 = Uint8List(800)..fillRange(0, 800, 0x22);

        await userCache.savePqPublicKey(walletA, pk1);
        await userCache.savePqPublicKey(walletA, pk2);

        final loaded = await userCache.getContactPqPublicKey(walletA);
        expect(loaded, equals(pk2));
      });

      test('savePqSharedSecret second call overwrites first', () async {
        await _insertContact(rawDb, walletA);
        final s1 = Uint8List(32)..fillRange(0, 32, 0x01);
        final s2 = Uint8List(32)..fillRange(0, 32, 0x02);

        await userCache.savePqSharedSecret(walletA, s1);
        await userCache.savePqSharedSecret(walletA, s2);

        final loaded = await userCache.getContactPqSharedSecret(walletA);
        expect(loaded, equals(s2));
      });
    });

    // =========================================================================
    // Multiple contacts are isolated
    // =========================================================================
    group('isolation between contacts', () {
      const walletB = 'ALGORANDADDRBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB1';

      test('saving PQ key for one wallet does not affect another', () async {
        await _insertContact(rawDb, walletA);
        await _insertContact(rawDb, walletB);

        final pkA = Uint8List(800)..fillRange(0, 800, 0xAA);
        await userCache.savePqPublicKey(walletA, pkA);

        final loadedB = await userCache.getContactPqPublicKey(walletB);
        expect(loadedB, isNull);
      });
    });
  });
}

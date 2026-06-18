import 'package:sealed_app/infra/local/database.dart';
import 'package:sealed_app/core/log.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sqflite/sqflite.dart';

abstract class LocalUserRepository {
  /// Get the locally stored user profile (current logged-in user).
  /// If [walletAddress] is provided, only return a profile matching that wallet.
  Future<UserProfile?> getLocalUser({String? walletAddress});

  /// Save user profile locally (after registration or login).
  Future<void> saveLocalUser(UserProfile profile);

  /// Delete local user profile (logout).
  Future<void> deleteLocalUser();

  /// Update last login timestamp.
  Future<void> updateLastLogin(String walletAddress);
}

class LocalUserRepositoryImpl implements LocalUserRepository {
  LocalUserRepositoryImpl(this._db);
  final LocalDatabase _db;

  @override
  Future<UserProfile?> getLocalUser({String? walletAddress}) async {
    final Database database = await _db.database;
    final results = walletAddress != null
        ? await database.query(
            'user_profile',
            where: 'wallet_address = ?',
            whereArgs: [walletAddress],
            limit: 1,
          )
        : await database.query('user_profile', limit: 1);
    // T1 PROBE — username persistence diagnosis (remove in T8).
    // ignore: avoid_print
    Log.d(
      '[LocalUserRepo] getLocalUser wallet=$walletAddress hits=${results.length} '
      'username=${results.isNotEmpty ? results.first["username"] : null} '
      'alias=${results.isNotEmpty ? results.first["alias"] : null}',
    );
    if (results.isEmpty) return null;
    return UserProfile.fromMap(results.first);
  }

  @override
  Future<void> saveLocalUser(UserProfile profile) async {
    final Database database = await _db.database;
    final id = await database.insert(
      'user_profile',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // T1 PROBE — username persistence diagnosis (remove in T8).
    // ignore: avoid_print
    Log.d(
      '[LocalUserRepo] saveLocalUser wallet=${profile.walletAddress} '
      'username=${profile.username} alias=${profile.alias} rowid=$id',
    );
  }

  @override
  Future<void> deleteLocalUser() async {
    final Database database = await _db.database;
    await database.delete('user_profile');
  }

  @override
  Future<void> updateLastLogin(String walletAddress) async {
    final Database database = await _db.database;
    await database.update(
      'user_profile',
      {'last_login': DateTime.now().millisecondsSinceEpoch},
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
    );
  }
}

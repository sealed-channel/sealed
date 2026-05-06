// lib/data/local/user_cache.dart

import 'dart:typed_data';

import 'package:sealed_app/local/database.dart';
import 'package:sealed_app/models/user_profile.dart';
import 'package:sqflite/sqflite.dart';
import 'package:string_similarity/string_similarity.dart';

class UserCache {
  final LocalDatabase _db;

  UserCache(this._db);

  /// Get the locally cached user profile (current logged-in user)
  /// If [walletAddress] is provided, only return a profile matching that wallet.
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
    if (results.isEmpty) return null;
    return UserProfile.fromMap(results.first);
  }

  /// Save user profile locally (after registration or login)
  Future<void> saveLocalUser(UserProfile profile) async {
    final Database database = await _db.database;
    await database.insert(
      'user_profile',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static final _algorandAddressRe = RegExp(r'^[A-Z2-7]{58}$');

  Future<List<UserProfile>> searchUsers(
    String query, {
    double threshold = 0.3,
  }) async {
    final database = await _db.database;
    // Strip leading '@' so search works with or without it
    final cleanQuery = query.startsWith('@') ? query.substring(1) : query;

    // Fetch all contacts (for small datasets) or use loose LIKE
    final results = await database.query('contacts_cache');
    // Only include Algorand wallet addresses — filter out any Solana legacy data
    final contacts = results
        .map((e) => UserProfile.fromMap(e))
        .where((c) => _algorandAddressRe.hasMatch(c.walletAddress))
        .toList();

    // Score each contact by similarity to query
    final scored = contacts
        .map((contact) {
          final username = (contact.username ?? '').toLowerCase();
          final wallet = contact.walletAddress.toLowerCase();
          final q = cleanQuery.toLowerCase();

          // Best match between username and wallet
          final score = [
            username.similarityTo(q),
            wallet.similarityTo(q),
            username.contains(q) ? 1.0 : 0.0, // Boost exact substring
          ].reduce((a, b) => a > b ? a : b);

          return (contact: contact, score: score);
        })
        .where((e) => e.score >= threshold)
        .toList();

    // Sort by best match first
    scored.sort((a, b) => b.score.compareTo(a.score));

    return scored.map((e) => e.contact).toList();
  }

  /// Delete local user profile (logout)
  Future<void> deleteLocalUser() async {
    final Database database = await _db.database;
    await database.delete('user_profile');
  }

  /// Update last login timestamp
  Future<void> updateLastLogin(String walletAddress) async {
    final Database database = await _db.database;
    await database.update(
      'user_profile',
      {'last_login': DateTime.now().millisecondsSinceEpoch},
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
    );
  }

  /// Cache a contact's profile (users you've messaged)
  Future<void> cacheContact(UserProfile profile) async {
    final Database database = await _db.database;
    await database.insert(
      'contacts_cache',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get cached contact by wallet address
  Future<UserProfile?> getCachedContact(String walletAddress) async {
    final database = await _db.database;
    final results = await database.query(
      'contacts_cache',
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return UserProfile.fromMap(results.first);
  }

  /// Get cached contact by username
  Future<UserProfile?> getCachedContactByUsername(String username) async {
    final database = await _db.database;
    final results = await database.query(
      'contacts_cache',
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return UserProfile.fromMap(results.first);
  }

  /// Get all cached contacts
  Future<List<UserProfile>> getAllCachedContacts() async {
    final Database database = await _db.database;

    final results = await database.query('contacts_cache');
    return results.map((e) => UserProfile.fromMap(e)).toList();
  }

  /// Delete a cached contact
  Future<void> deleteCachedContact(String walletAddress) async {
    final Database database = await _db.database;
    await database.delete(
      'contacts_cache',
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
    );
  }

  /// Clear all cached contacts
  Future<void> clearContactsCache() async {
    final Database database = await _db.database;
    await database.delete('contacts_cache');
  }

  Future<Uint8List?> getContactPqPublicKey(String walletAddress) async {
    final database = await _db.database;
    final results = await database.query(
      'contacts_cache',
      columns: ['pq_public_key'],
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
      limit: 1,
    );
    if (results.isEmpty) return null;
    final raw = results.first['pq_public_key'];
    if (raw == null) return null;
    return raw as Uint8List;
  }

  Future<Uint8List?> getContactPqSharedSecret(String walletAddress) async {
    final database = await _db.database;
    final results = await database.query(
      'contacts_cache',
      columns: ['pq_shared_secret'],
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
      limit: 1,
    );
    if (results.isEmpty) return null;
    final raw = results.first['pq_shared_secret'];
    if (raw == null) return null;
    return raw as Uint8List;
  }

  Future<void> savePqSharedSecret(
    String walletAddress,
    Uint8List secret,
  ) async {
    final database = await _db.database;
    await database.update(
      'contacts_cache',
      {'pq_shared_secret': secret},
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
    );
  }

  Future<void> savePqPublicKey(String walletAddress, Uint8List pubkey) async {
    final database = await _db.database;
    await database.update(
      'contacts_cache',
      {'pq_public_key': pubkey},
      where: 'wallet_address = ?',
      whereArgs: [walletAddress],
    );
  }
}

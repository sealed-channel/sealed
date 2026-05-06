/// WipeService — the panic switch.
///
/// Reuses the existing destructive ordering from [performLogout] (caches →
/// alias keys → user → wallet) and additionally:
///   - flutterSecureStorage.deleteAll() — wipes wallet seed, all DEK wraps,
///     PIN salts, biometric KEK, termination marker.
///   - Deletes the encrypted DB file from disk.
///   - Clears SharedPreferences.
///
/// Two entry points:
///   - [WipeService.wipeAll] — for the Settings "Erase this device" button.
///   - [WipeService.silentWipe] — for the duress branch in LockScreen, which
///     must never throw and must complete even if intermediate steps fail.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'logout_service.dart';

class WipeService {
  final ProviderContainer _container;
  final FlutterSecureStorage _storage;

  WipeService(this._container, {FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Full wipe — for "Erase this device" or termination code.
  /// Best-effort: each step is wrapped so one failure does not block the rest.
  Future<void> wipeAll() async {
    print('💣 WipeService: starting full wipe...');

    // Step 1: standard logout — clears caches, keys, user, deletes wallet.
    try {
      await performLogout(_container);
    } catch (e) {
      print('⚠️ WipeService: performLogout failed: $e');
    }

    // Step 2: nuke flutter_secure_storage entirely (wallet seed, DEK wraps,
    // PIN salts, biometric KEK, termination marker, push tokens).
    try {
      await _storage.deleteAll();
    } catch (e) {
      print('⚠️ WipeService: secureStorage.deleteAll failed: $e');
    }

    // Step 3: delete the encrypted SQLite database file from disk.
    try {
      await _deleteDatabaseFile();
    } catch (e) {
      print('⚠️ WipeService: DB file delete failed: $e');
    }

    // Step 4: clear SharedPreferences (sync-layer pref, push opt-in, etc.).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (e) {
      print('⚠️ WipeService: prefs.clear failed: $e');
    }

    print('💣 WipeService: wipe complete.');
  }

  /// Same as [wipeAll], but never throws — duress safety. Used from the
  /// LockScreen so the user sees only "Incorrect PIN" regardless of state.
  Future<void> silentWipe() async {
    try {
      await wipeAll();
    } catch (_) {
      // Swallow — caller must not signal success/failure to attacker.
    }
  }

  Future<void> _deleteDatabaseFile() async {
    // sealed_messages.db lives in the sqflite default databases dir.
    final dbDir = await getDatabasesPath();
    final file = File(p.join(dbDir, 'sealed_messages.db'));
    if (await file.exists()) {
      await file.delete();
    }
    // Also clean up any stale migration scratch file.
    final scratch = File(p.join(dbDir, 'sealed_messages.enc.db'));
    if (await scratch.exists()) {
      await scratch.delete();
    }
    // And any documents-dir copy if path_provider was used.
    try {
      final docs = await getApplicationDocumentsDirectory();
      final altFile = File(p.join(docs.path, 'sealed_messages.db'));
      if (await altFile.exists()) {
        await altFile.delete();
      }
    } catch (_) {
      /* not all platforms expose docs dir */
    }
  }
}

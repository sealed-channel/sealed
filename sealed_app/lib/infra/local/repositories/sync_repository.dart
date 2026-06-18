import 'package:sealed_app/infra/local/database.dart';

// Custom Exceptions
class SyncException implements Exception {
  final String message;
  final String? code;
  final StackTrace? stackTrace;

  SyncException(this.message, {this.code, this.stackTrace});

  @override
  String toString() =>
      'SyncException: $message${code != null ? ' ($code)' : ''}';
}

class SyncQueryException extends SyncException {
  SyncQueryException(super.message, [StackTrace? stackTrace])
    : super(code: 'QUERY_ERROR', stackTrace: stackTrace);
}

class SyncUpdateException extends SyncException {
  SyncUpdateException(super.message, [StackTrace? stackTrace])
    : super(code: 'UPDATE_ERROR', stackTrace: stackTrace);
}

class SyncRepository {
  final LocalDatabase _database;
  SyncRepository(this._database);

  Future<DateTime> get lastSyncTime async {
    try {
      final db = await _database.database;
      final result = await db.query(
        'sync_state',
        columns: ['last_sync_timestamp'],
        where: 'key = ?',
        whereArgs: ['global'],
        limit: 1,
      );
      if (result.isNotEmpty) {
        final timestamp = result.first['last_sync_timestamp'] as int;
        return DateTime.fromMillisecondsSinceEpoch(timestamp);
      } else {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    } on DatabaseException {
      rethrow;
    } catch (e, stackTrace) {
      throw SyncQueryException('Failed to get last sync time: $e', stackTrace);
    }
  }

  Future<void> updateLastSyncTime(DateTime time) async {
    try {
      if (time.millisecondsSinceEpoch < 0) {
        throw SyncException(
          'timestamp cannot be negative',
          code: 'VALIDATION_ERROR',
        );
      }

      final db = await _database.database;
      final rowsAffected = await db.update(
        'sync_state',
        {'last_sync_timestamp': time.millisecondsSinceEpoch},
        where: 'key = ?',
        whereArgs: ['global'],
      );

      if (rowsAffected == 0) {
        throw SyncException('sync_state row not found', code: 'NOT_FOUND');
      }
    } on SyncException {
      rethrow;
    } on DatabaseException {
      rethrow;
    } catch (e, stackTrace) {
      throw SyncUpdateException(
        'Failed to update last sync time: $e',
        stackTrace,
      );
    }
  }

  Future<void> reset() async {
    try {
      final db = await _database.database;
      final rowsAffected = await db.update(
        'sync_state',
        {'last_sync_timestamp': 0, 'last_processed_slot': 0},
        where: 'key = ?',
        whereArgs: ['global'],
      );

      if (rowsAffected == 0) {
        throw SyncException('sync_state row not found', code: 'NOT_FOUND');
      }
    } on SyncException {
      rethrow;
    } on DatabaseException {
      rethrow;
    } catch (e, stackTrace) {
      throw SyncUpdateException('Failed to reset sync state: $e', stackTrace);
    }
  }
}

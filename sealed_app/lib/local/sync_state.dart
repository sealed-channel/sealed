import 'package:sealed_app/local/database.dart';

// Custom Exceptions
class SyncStateException implements Exception {
  final String message;
  final String? code;
  final StackTrace? stackTrace;

  SyncStateException(this.message, {this.code, this.stackTrace});

  @override
  String toString() =>
      'SyncStateException: $message${code != null ? ' ($code)' : ''}';
}

class SyncStateQueryException extends SyncStateException {
  SyncStateQueryException(super.message, [StackTrace? stackTrace])
    : super(code: 'QUERY_ERROR', stackTrace: stackTrace);
}

class SyncStateUpdateException extends SyncStateException {
  SyncStateUpdateException(super.message, [StackTrace? stackTrace])
    : super(code: 'UPDATE_ERROR', stackTrace: stackTrace);
}

class SyncState {
  final LocalDatabase _database;
  SyncState(this._database);

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
      throw SyncStateQueryException(
        'Failed to get last sync time: $e',
        stackTrace,
      );
    }
  }

  Future<void> updateLastSyncTime(DateTime time) async {
    try {
      if (time.millisecondsSinceEpoch < 0) {
        throw SyncStateException(
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
        throw SyncStateException('sync_state row not found', code: 'NOT_FOUND');
      }
    } on SyncStateException {
      rethrow;
    } on DatabaseException {
      rethrow;
    } catch (e, stackTrace) {
      throw SyncStateUpdateException(
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
        throw SyncStateException('sync_state row not found', code: 'NOT_FOUND');
      }
    } on SyncStateException {
      rethrow;
    } on DatabaseException {
      rethrow;
    } catch (e, stackTrace) {
      throw SyncStateUpdateException(
        'Failed to reset sync state: $e',
        stackTrace,
      );
    }
  }
}

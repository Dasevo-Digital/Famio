import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import 'encrypted_db.dart';

/// A record in the local store plus whether it still has to be pushed.
class LocalRecord {
  const LocalRecord(this.record, {required this.dirty});

  final SyncRecord record;
  final bool dirty;
}

/// On-device SQLite copy of all records, plus small key/value metadata.
///
/// All records are also kept in memory: family data is small, and it makes
/// reads synchronous for the UI.
class LocalStore {
  LocalStore._(this._db) {
    for (final row in _db.select('SELECT * FROM records')) {
      final record = SyncRecord(
        collection: row['collection'] as String,
        id: row['id'] as String,
        data: (jsonDecode(row['data'] as String) as Map).cast(),
        deleted: row['deleted'] == 1,
        updatedAt: row['updated_at'] as int,
        updatedBy: row['updated_by'] as String?,
        rev: row['rev'] as int,
      );
      _cache.putIfAbsent(record.collection, () => {})[record.id] = LocalRecord(
        record,
        dirty: row['dirty'] == 1,
      );
    }
  }

  /// Opens the store at [path], encrypted with [hexKey]; pass `:memory:`
  /// for tests.
  factory LocalStore.open(String path, {String? hexKey}) {
    final db = openDeviceDatabase(path, hexKey: hexKey);
    db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        collection TEXT NOT NULL,
        id TEXT NOT NULL,
        data TEXT NOT NULL,
        deleted INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        updated_by TEXT,
        rev INTEGER NOT NULL,
        dirty INTEGER NOT NULL,
        PRIMARY KEY (collection, id)
      );
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    ''');
    return LocalStore._(db);
  }

  final Database _db;
  final _cache = <String, Map<String, LocalRecord>>{};

  LocalRecord? get(String collection, String id) => _cache[collection]?[id];

  Iterable<LocalRecord> all(String collection) =>
      _cache[collection]?.values ?? const [];

  Iterable<LocalRecord> get dirty =>
      _cache.values.expand((c) => c.values).where((r) => r.dirty);

  void put(SyncRecord record, {required bool dirty}) {
    _db.execute(
      'INSERT OR REPLACE INTO records (collection, id, data, deleted,'
      ' updated_at, updated_by, rev, dirty) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        record.collection,
        record.id,
        jsonEncode(record.data),
        record.deleted ? 1 : 0,
        record.updatedAt,
        record.updatedBy,
        record.rev,
        dirty ? 1 : 0,
      ],
    );
    _cache.putIfAbsent(record.collection, () => {})[record.id] = LocalRecord(
      record,
      dirty: dirty,
    );
  }

  void markClean(String collection, String id) {
    final local = get(collection, id);
    if (local == null || !local.dirty) return;
    _db.execute(
      'UPDATE records SET dirty = 0 WHERE collection = ? AND id = ?',
      [collection, id],
    );
    _cache[collection]![id] = LocalRecord(local.record, dirty: false);
  }

  /// Runs [action] in one SQLite transaction.
  T transaction<T>(T Function() action) {
    _db.execute('BEGIN');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? getMeta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String?;
  }

  void setMeta(String key, String? value) {
    _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [
      key,
      value,
    ]);
  }

  void close() => _db.close();
}

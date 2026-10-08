import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../encrypted_db.dart';
import 'storage.dart';

RecordBackend openRecordBackend(String path, {String? hexKey}) =>
    _SqliteRecords(openDeviceDatabase(path, hexKey: hexKey));

BlobBackend openBlobBackend(String path, {String? hexKey}) =>
    _SqliteBlobs(openDeviceDatabase(path, hexKey: hexKey));

/// Writes a plain copy of a file for another app (PDF viewer …); returns
/// its path.
Future<String> writeTempFile(String dir, String name, List<int> data) async {
  Directory(dir).createSync(recursive: true);
  final file = File('$dir/$name');
  await file.writeAsBytes(data, flush: true);
  return file.path;
}

void clearTempFiles(String dir) {
  final directory = Directory(dir);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
}

class _SqliteRecords implements RecordBackend {
  _SqliteRecords(this._db) {
    _db.execute('''
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
  }

  final Database _db;

  @override
  Iterable<(SyncRecord, bool)> load() sync* {
    for (final row in _db.select('SELECT * FROM records')) {
      yield (
        SyncRecord(
          collection: row['collection'] as String,
          id: row['id'] as String,
          data: (jsonDecode(row['data'] as String) as Map).cast(),
          deleted: row['deleted'] == 1,
          updatedAt: row['updated_at'] as int,
          updatedBy: row['updated_by'] as String?,
          rev: row['rev'] as int,
        ),
        row['dirty'] == 1,
      );
    }
  }

  @override
  void put(SyncRecord record, {required bool dirty}) => _db.execute(
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

  @override
  void markClean(String collection, String id) => _db.execute(
    'UPDATE records SET dirty = 0 WHERE collection = ? AND id = ?',
    [collection, id],
  );

  @override
  void remove(String collection, String id) => _db.execute(
    'DELETE FROM records WHERE collection = ? AND id = ?',
    [collection, id],
  );

  @override
  void removeCleanDeleted() =>
      _db.execute('DELETE FROM records WHERE deleted = 1 AND dirty = 0');

  @override
  void begin() => _db.execute('BEGIN');

  @override
  void commit() => _db.execute('COMMIT');

  @override
  void rollback() => _db.execute('ROLLBACK');

  @override
  String? getMeta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String?;
  }

  @override
  void setMeta(String key, String? value) => _db.execute(
    'INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)',
    [key, value],
  );

  @override
  void close() => _db.close();
}

class _SqliteBlobs implements BlobBackend {
  _SqliteBlobs(this._db) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute(
      'CREATE TABLE IF NOT EXISTS blobs (key TEXT NOT NULL, seq INTEGER NOT'
      ' NULL, data BLOB NOT NULL, PRIMARY KEY (key, seq))',
    );
    // Size and last use per file, for trimming the least recently used.
    _db.execute(
      'CREATE TABLE IF NOT EXISTS entries (key TEXT PRIMARY KEY, size INTEGER'
      ' NOT NULL, used INTEGER NOT NULL)',
    );
    // Caches from before 1.0.10 have no entries yet: count as never used.
    if (_db.select('SELECT 1 FROM entries LIMIT 1').isEmpty) {
      _db.execute(
        'INSERT INTO entries (key, size, used) SELECT key, SUM(length(data)),'
        ' 0 FROM blobs GROUP BY key',
      );
    }
  }

  final Database _db;

  /// Strictly increasing, so files touched in the same millisecond still
  /// have an order.
  var _clock = 0;

  int _tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _clock = now > _clock ? now : _clock + 1;
  }

  static const _chunk = 1024 * 1024;

  @override
  List<int>? read(String key) {
    final rows = _db.select(
      'SELECT data FROM blobs WHERE key = ? ORDER BY seq',
      [key],
    );
    if (rows.isEmpty) return null;
    _db.execute('UPDATE entries SET used = ? WHERE key = ?', [_tick(), key]);
    final out = BytesBuilder(copy: false);
    for (final r in rows) {
      out.add(r.columnAt(0) as List<int>);
    }
    return out.takeBytes();
  }

  @override
  void write(String key, List<int> data) {
    _db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM blobs WHERE key = ?', [key]);
      for (var o = 0, seq = 0; o < data.length || seq == 0; o += _chunk) {
        final end = o + _chunk < data.length ? o + _chunk : data.length;
        _db.execute('INSERT INTO blobs (key, seq, data) VALUES (?, ?, ?)', [
          key,
          seq++,
          data.sublist(o, end),
        ]);
      }
      _db.execute(
        'INSERT OR REPLACE INTO entries (key, size, used) VALUES (?, ?, ?)',
        [key, data.length, _tick()],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  int get size =>
      _db.select('SELECT COALESCE(SUM(size), 0) FROM entries').first.columnAt(0)
          as int;

  @override
  void trim(int maxBytes) {
    var total = size;
    if (total <= maxBytes) return;
    final oldest = _db.select('SELECT key, size FROM entries ORDER BY used');
    _db.execute('BEGIN');
    try {
      for (final r in oldest) {
        if (total <= maxBytes) break;
        final key = r.columnAt(0) as String;
        _db.execute('DELETE FROM blobs WHERE key = ?', [key]);
        _db.execute('DELETE FROM entries WHERE key = ?', [key]);
        total -= r.columnAt(1) as int;
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  void clear() {
    _db.execute('DELETE FROM blobs');
    _db.execute('DELETE FROM entries');
    // Gives the space back to the device.
    _db.execute('VACUUM');
  }

  @override
  void close() => _db.close();
}

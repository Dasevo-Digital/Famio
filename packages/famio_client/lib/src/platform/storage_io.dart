import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../encrypted_db.dart';
import '../snapshot_codec.dart';
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

Future<String> writeTempStream(
  String dir,
  String name,
  Stream<List<int>> data,
  int expectedBytes,
) async {
  await Directory(dir).create(recursive: true);
  final file = File('$dir/$name');
  await file.create(exclusive: true);
  final output = await file.open(mode: FileMode.writeOnly);
  var complete = false, count = 0;
  try {
    await for (final chunk in data) {
      if (chunk.length > expectedBytes - count) {
        throw const FormatException('File length mismatch');
      }
      await output.writeFrom(chunk);
      count += chunk.length;
    }
    if (count != expectedBytes) {
      throw const FormatException('File length mismatch');
    }
    await output.flush();
    complete = true;
    return file.path;
  } finally {
    await output.close();
    if (!complete && await file.exists()) await file.delete();
  }
}

/// Only the browser restores a copy before opening (storage_web.dart).
void restoreCopy(String path, StoreSnapshot snapshot) {}

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
  void keepCopy(bool keep) {}

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
    _db.execute("DELETE FROM blobs WHERE key LIKE '%:pending:%'");
    if (_db.select('SELECT 1 FROM entries LIMIT 1').isEmpty) {
      _db.execute(
        'INSERT INTO entries (key, size, used) SELECT key, SUM(length(data)),'
        ' 0 FROM blobs GROUP BY key',
      );
    }
    _db.execute('DELETE FROM blobs WHERE key NOT IN (SELECT key FROM entries)');
  }

  final Database _db;
  var _closed = false;
  var _generation = 0;
  final _readers = <String, int>{};

  void _check(int generation) {
    if (_closed || generation != _generation) {
      throw StateError('Cache no longer current');
    }
  }

  /// Check block continuity and length before returning an offline copy.
  /// Broken entries are misses, so a download can repair them.
  int? _entrySize(String key) {
    final row = _db
        .select(
          '''
      SELECT e.size, COUNT(b.seq) AS blocks, MIN(b.seq) AS first,
             MAX(b.seq) AS last, COALESCE(SUM(length(b.data)), 0) AS actual
      FROM entries e LEFT JOIN blobs b ON b.key = e.key
      WHERE e.key = ? GROUP BY e.key
    ''',
          [key],
        )
        .firstOrNull;
    if (row == null) return null;
    final blocks = row['blocks'] as int;
    if (blocks > 0 &&
        row['first'] == 0 &&
        row['last'] == blocks - 1 &&
        row['actual'] == row['size']) {
      return row['actual'] as int;
    }
    _db.execute('DELETE FROM blobs WHERE key = ?', [key]);
    _db.execute('DELETE FROM entries WHERE key = ?', [key]);
    return null;
  }

  /// Strictly increasing, so files touched in the same millisecond still
  /// have an order.
  var _clock = 0;

  int _tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _clock = now > _clock ? now : _clock + 1;
  }

  static const _chunk = 1024 * 1024;

  @override
  ({int size, Stream<List<int>> stream})? readStream(String key) {
    final generation = _generation;
    _check(generation);
    final size = _entrySize(key);
    if (size == null) return null;
    _db.execute('UPDATE entries SET used = ? WHERE key = ?', [_tick(), key]);
    final stream = () async* {
      _readers[key] = (_readers[key] ?? 0) + 1;
      try {
        for (var seq = 0; ; seq++) {
          _check(generation);
          final row = _db.select(
            'SELECT data FROM blobs WHERE key = ? AND seq = ?',
            [key, seq],
          ).firstOrNull;
          if (row == null) break;
          yield row['data'] as List<int>;
        }
      } finally {
        final remaining = _readers[key]! - 1;
        if (remaining == 0) {
          _readers.remove(key);
        } else {
          _readers[key] = remaining;
        }
      }
    }();
    return (size: size, stream: stream);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> input, {
    required int expectedBytes,
    TransferCancellation? cancellation,
  }) async {
    final generation = _generation;
    _check(generation);
    void active() {
      _check(generation);
      if (cancellation?.cancelled ?? false) {
        throw StateError('Cache copy cancelled');
      }
    }

    final staging = '$key:pending:${newId()}';
    var count = 0, seq = 0;
    try {
      await for (final chunk in input) {
        active();
        if (chunk.length > expectedBytes - count) {
          throw const FormatException('File length mismatch');
        }
        for (var offset = 0; offset < chunk.length; offset += _chunk) {
          final end = offset + _chunk < chunk.length
              ? offset + _chunk
              : chunk.length;
          _db.execute('INSERT INTO blobs (key, seq, data) VALUES (?, ?, ?)', [
            staging,
            seq++,
            chunk.sublist(offset, end),
          ]);
        }
        count += chunk.length;
      }
      active();
      if (count != expectedBytes) {
        throw const FormatException('File length mismatch');
      }
      if (seq == 0) {
        _db.execute('INSERT INTO blobs (key, seq, data) VALUES (?, 0, ?)', [
          staging,
          Uint8List(0),
        ]);
      }
      _db.execute('BEGIN');
      try {
        _db.execute('DELETE FROM blobs WHERE key = ?', [key]);
        _db.execute('UPDATE blobs SET key = ? WHERE key = ?', [key, staging]);
        _db.execute(
          'INSERT OR REPLACE INTO entries (key, size, used) VALUES (?, ?, ?)',
          [key, count, _tick()],
        );
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      if (!_closed) _db.execute('DELETE FROM blobs WHERE key = ?', [staging]);
    }
  }

  @override
  List<int>? read(String key, {int? maxBytes}) {
    _check(_generation);
    final size = _entrySize(key);
    if (size == null) return null;
    if (maxBytes != null && size > maxBytes) throw TransferTooLarge();
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
    _check(_generation);
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
        if (_readers.containsKey(key)) continue;
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
    _generation++;
    _db.execute('DELETE FROM blobs');
    _db.execute('DELETE FROM entries');
    // Gives the space back to the device.
    _db.execute('VACUUM');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _db.close();
  }
}

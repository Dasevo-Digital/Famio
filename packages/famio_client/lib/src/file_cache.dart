import 'dart:io';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import 'api_client.dart';
import 'encrypted_db.dart';

/// Keeps downloaded files on the device, so photos and documents opened once
/// are available offline. Files never change (new upload = new id), so a
/// cached copy is always valid.
///
/// The cache is an encrypted database: documents and photos are never
/// stored in plain text, except for a short-lived copy in [tempDir] when a
/// file is handed to another app (PDF viewer …); [clearTemp] removes those.
class FileCache {
  FileCache._(this._db, this.api, this.tempDir) {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute(
      'CREATE TABLE IF NOT EXISTS blobs (key TEXT NOT NULL, seq INTEGER NOT'
      ' NULL, data BLOB NOT NULL, PRIMARY KEY (key, seq))',
    );
  }

  /// Opens the cache database at [path] (`:memory:` for tests).
  factory FileCache.open(
    String path,
    FamioApiClient api, {
    String? hexKey,
    required Directory tempDir,
  }) => FileCache._(openDeviceDatabase(path, hexKey: hexKey), api, tempDir);

  final Database _db;
  final FamioApiClient api;

  /// Where decrypted copies for other apps are written.
  final Directory tempDir;
  final _pending = <String, Future<Uint8List>>{};

  /// Recently shown previews, most recent last. Handing out the same bytes
  /// again spares the database read and lets Flutter's image cache reuse
  /// the decoded picture instead of decoding it on every rebuild.
  final _recent = <String, Uint8List>{};
  var _recentBytes = 0;

  /// Upper bound for [_recent].
  static const recentLimit = 16 * 1024 * 1024;

  static const _chunk = 1024 * 1024;

  /// The contents of [ref] (or its [thumb] preview), downloading them once.
  Future<Uint8List> bytes(FileRef ref, {int? thumb}) {
    final key = thumb == null ? ref.id : '${ref.id}_t$thumb';
    if (_recent.remove(key) case final data?) {
      _recent[key] = data;
      return Future.value(data);
    }
    final cached = _read(key);
    if (cached != null) return Future.value(_remember(key, cached, thumb));
    return _pending[key] ??= () async {
      try {
        final data = Uint8List.fromList(
          await api.downloadFile(ref.id, thumb: thumb),
        );
        _write(key, data);
        return _remember(key, data, thumb);
      } finally {
        _pending.remove(key);
      }
    }();
  }

  /// Keeps previews (not whole documents) in [_recent].
  Uint8List _remember(String key, Uint8List data, int? thumb) {
    if (thumb == null || data.length > recentLimit ~/ 8) return data;
    _recent[key] = data;
    _recentBytes += data.length;
    while (_recentBytes > recentLimit) {
      final oldest = _recent.keys.first;
      _recentBytes -= _recent.remove(oldest)!.length;
    }
    return data;
  }

  /// A plain copy of [ref] for opening it with another app.
  Future<File> openable(FileRef ref) async {
    final data = await bytes(ref);
    tempDir.createSync(recursive: true);
    final file = File('${tempDir.path}/${ref.id}_${_safe(ref.name)}');
    await file.writeAsBytes(data, flush: true);
    return file;
  }

  /// Deletes plain copies made by [openable].
  void clearTemp() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  /// Puts freshly uploaded bytes into the cache, so the uploader never
  /// downloads their own file again.
  void put(FileRef ref, List<int> data) => _write(ref.id, data);

  void close() => _db.close();

  Uint8List? _read(String key) {
    final rows = _db.select(
      'SELECT data FROM blobs WHERE key = ? ORDER BY seq',
      [key],
    );
    if (rows.isEmpty) return null;
    final out = BytesBuilder(copy: false);
    for (final r in rows) {
      out.add(r.columnAt(0) as List<int>);
    }
    return out.takeBytes();
  }

  void _write(String key, List<int> data) {
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
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static String _safe(String name) => name.replaceAll(RegExp(r'[^\w.\-]'), '_');
}

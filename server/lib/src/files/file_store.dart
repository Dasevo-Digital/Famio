import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../api_exception.dart';
import '../record_store.dart';

class StoredFile {
  const StoredFile({
    required this.id,
    required this.owner,
    required this.name,
    required this.mime,
    required this.size,
  });

  final String id;
  final String owner;
  final String name;
  final String mime;
  final int size;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'size': size,
  };
}

/// Uploaded files (chat photos, documents, child photos).
///
/// Contents live in 1 MiB blocks in a separate database ([blobs]), which is
/// encrypted like the main database – so files are protected at rest by the
/// same key, with native (not Dart) cryptography.
///
/// A member may download a file they uploaded, or one that a record visible
/// to them references – so a document's visibility also protects its file.
class FileStore {
  FileStore(
    this._db, {
    required this.blobs,
    required String dataDir,
    required this.records,
    int Function()? maxBytes,
  }) : _maxBytes = maxBytes ?? (() => 100 * 1024 * 1024) {
    blobs.execute('PRAGMA journal_mode = WAL');
    blobs.execute(
      'CREATE TABLE IF NOT EXISTS blobs (id TEXT NOT NULL, kind TEXT NOT NULL,'
      ' seq INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY (id, kind, seq))',
    );
    _importPlainFiles(dataDir);
  }

  final Database _db;

  /// Block storage for contents and previews.
  final Database blobs;
  final RecordStore records;
  final int Function() _maxBytes;

  /// Current upload limit (admins can change it at runtime).
  int get maxBytes => _maxBytes();

  static const _chunk = 1024 * 1024;
  static const _original = 'f';

  /// Number and total size of stored uploads.
  (int count, int bytes) usage() {
    final row = _db
        .select('SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM files')
        .first;
    return (row['n'] as int, row['b'] as int);
  }

  /// Uploads not referenced by any record are deleted after this time.
  static const orphanGrace = Duration(hours: 24);
  static const thumbSizes = {160, 480, 1280};

  /// Larger images get no preview (~240 MB RAM while decoding; phone
  /// photos are 12–50 MP).
  static const maxThumbPixels = 60 * 1000 * 1000;

  Future<StoredFile> save({
    required String owner,
    required String name,
    required String mime,
    required Stream<List<int>> body,
  }) async {
    final id = newId();
    var size = 0;
    var seq = 0;
    final buffer = BytesBuilder(copy: false);
    void flush() {
      if (buffer.isEmpty) return;
      _putBlock(id, _original, seq++, buffer.takeBytes());
    }

    try {
      await for (final chunk in body) {
        size += chunk.length;
        if (size > maxBytes) {
          throw ApiException(
            413,
            'too_large',
            'Datei ist größer als ${maxBytes ~/ (1024 * 1024)} MB',
          );
        }
        buffer.add(chunk);
        if (buffer.length >= _chunk) flush();
      }
      flush();
    } catch (_) {
      _deleteBlocks(id);
      rethrow;
    }
    if (size == 0) {
      throw ApiException.badRequest('empty', 'Leere Datei');
    }
    final safeName = _safeName(name);
    _db.execute(
      'INSERT INTO files (id, owner, name, mime, size, created_at)'
      ' VALUES (?, ?, ?, ?, ?, ?)',
      [id, owner, safeName, mime, size, DateTime.now().millisecondsSinceEpoch],
    );
    return StoredFile(
      id: id,
      owner: owner,
      name: safeName,
      mime: mime,
      size: size,
    );
  }

  StoredFile? get(String id) {
    final rows = _db.select('SELECT * FROM files WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return StoredFile(
      id: r['id'] as String,
      owner: r['owner'] as String,
      name: r['name'] as String,
      mime: r['mime'] as String,
      size: r['size'] as int,
    );
  }

  bool mayRead(StoredFile file, String memberId) =>
      file.owner == memberId || records.referencedFor(file.id, memberId);

  /// The file's contents, block by block.
  Stream<List<int>> read(StoredFile file) => _readBlocks(file.id, _original);

  Stream<List<int>> _readBlocks(String id, String kind) async* {
    for (var seq = 0; ; seq++) {
      final rows = blobs.select(
        'SELECT data FROM blobs WHERE id = ? AND kind = ? AND seq = ?',
        [id, kind, seq],
      );
      if (rows.isEmpty) return;
      yield rows.first.columnAt(0) as List<int>;
    }
  }

  Uint8List? _readAll(String id, String kind) {
    final rows = blobs.select(
      'SELECT data FROM blobs WHERE id = ? AND kind = ? ORDER BY seq',
      [id, kind],
    );
    if (rows.isEmpty) return null;
    final out = BytesBuilder(copy: false);
    for (final r in rows) {
      out.add(r.columnAt(0) as List<int>);
    }
    return out.takeBytes();
  }

  /// A JPEG no wider/higher than [size] (one of [thumbSizes]), cached.
  Future<Uint8List?> thumbnail(StoredFile file, int size) async {
    if (!file.mime.startsWith('image/') || !thumbSizes.contains(size)) {
      return null;
    }
    final kind = 't$size';
    final cached = _readAll(file.id, kind);
    if (cached != null) return cached;
    final bytes = _readAll(file.id, _original);
    if (bytes == null) return null;
    // Decoding large photos is CPU heavy; keep the server responsive.
    Uint8List? render() {
      // Read the size from the header first: a tiny file can claim a huge
      // image ("decompression bomb") and exhaust the server's memory.
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null || info.width * info.height > maxThumbPixels) {
        return null;
      }
      final decoded = decoder!.decode(bytes);
      if (decoded == null) return null;
      final image = img.bakeOrientation(decoded);
      final landscape = image.width >= image.height;
      final resized = landscape
          ? (image.width > size ? img.copyResize(image, width: size) : image)
          : (image.height > size ? img.copyResize(image, height: size) : image);
      return img.encodeJpg(resized, quality: 82);
    }

    Uint8List? jpeg;
    try {
      jpeg = await Isolate.run(render);
    } catch (_) {
      jpeg = null; // Unsupported or broken image.
    }
    if (jpeg != null) _putBlock(file.id, kind, 0, jpeg);
    return jpeg;
  }

  /// Deletes uploads no live record references any more.
  int collectGarbage() {
    final cutoff = DateTime.now().subtract(orphanGrace).millisecondsSinceEpoch;
    var removed = 0;
    for (final row in _db.select('SELECT id FROM files WHERE created_at < ?', [
      cutoff,
    ])) {
      final id = row['id'] as String;
      if (records.referenced(id)) continue;
      _db.execute('DELETE FROM files WHERE id = ?', [id]);
      _deleteBlocks(id);
      removed++;
    }
    return removed;
  }

  void _putBlock(
    String id,
    String kind,
    int seq,
    List<int> data,
  ) => blobs.execute(
    'INSERT OR REPLACE INTO blobs (id, kind, seq, data) VALUES (?, ?, ?, ?)',
    [id, kind, seq, data],
  );

  void _deleteBlocks(String id) =>
      blobs.execute('DELETE FROM blobs WHERE id = ?', [id]);

  /// Moves files stored as plain files by older versions (`files/`,
  /// `thumbs/`) into the encrypted block storage and deletes them.
  void _importPlainFiles(String dataDir) {
    final plain = Directory(p.join(dataDir, 'files'));
    if (plain.existsSync()) {
      for (final entry in plain.listSync().whereType<File>()) {
        final id = p.basename(entry.path);
        final bytes = entry.readAsBytesSync();
        blobs.execute('BEGIN');
        try {
          _deleteBlocks(id);
          for (var o = 0, seq = 0; o < bytes.length; o += _chunk, seq++) {
            final end = o + _chunk < bytes.length ? o + _chunk : bytes.length;
            _putBlock(id, _original, seq, Uint8List.sublistView(bytes, o, end));
          }
          blobs.execute('COMMIT');
        } catch (_) {
          blobs.execute('ROLLBACK');
          rethrow;
        }
        entry.deleteSync();
      }
      plain.deleteSync(recursive: true);
    }
    final thumbs = Directory(p.join(dataDir, 'thumbs'));
    if (thumbs.existsSync()) thumbs.deleteSync(recursive: true);
  }

  static String _safeName(String name) {
    final base = p.basename(name.replaceAll(r'\', '/')).trim();
    final cleaned = base.replaceAll(RegExp(r'[\x00-\x1f"]'), '');
    if (cleaned.isEmpty) return 'datei';
    return cleaned.length > 200
        ? cleaned.substring(cleaned.length - 200)
        : cleaned;
  }
}

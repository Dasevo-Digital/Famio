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
import '../i18n.dart';

const _maxThumbPixels = 30 * 1000 * 1000;

/// Deliberately top-level: [Isolate.run] must not capture [FileStore], whose
/// thumbnail queue holds an unsendable Future.
Uint8List? _renderThumbnail((Uint8List bytes, int size) input) {
  final (bytes, size) = input;
  // Read the size from the header first: a tiny file can claim a huge image
  // ("decompression bomb") and exhaust the server's memory.
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > _maxThumbPixels) return null;
  final decoded = decoder!.decode(bytes);
  if (decoded == null) return null;
  final image = img.bakeOrientation(decoded);
  final landscape = image.width >= image.height;
  final resized = landscape
      ? (image.width > size ? img.copyResize(image, width: size) : image)
      : (image.height > size ? img.copyResize(image, height: size) : image);
  return img.encodeJpg(resized, quality: 82);
}

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
    int Function()? maxTotalBytes,
  }) : _maxBytes = maxBytes ?? (() => 100 * 1024 * 1024),
       _maxTotalBytes = maxTotalBytes ?? (() => 5 * 1024 * 1024 * 1024) {
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
  final int Function() _maxTotalBytes;

  /// Current upload limit (admins can change it at runtime).
  int get maxBytes => _maxBytes();
  int get maxTotalBytes => _maxTotalBytes();

  static const _chunk = 1024 * 1024;
  static const originalKind = 'f';

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

  /// Larger images get no preview (~120 MB RAM while decoding; current phone
  /// photos are normally 12–24 MP). Decodes are serialised below, so several
  /// simultaneous thumbnail requests cannot multiply that peak.
  static const maxThumbPixels = _maxThumbPixels;

  /// Isolates prevent decoding from blocking the event loop, but each decoder
  /// needs a large RGBA buffer. A one-at-a-time queue bounds the process RSS.
  Future<void> _thumbnailTail = Future.value();

  Future<T> _serializeThumbnail<T>(Future<T> Function() task) {
    final previous = _thumbnailTail;
    final completed = Completer<void>();
    _thumbnailTail = completed.future;
    return previous
        .then((_) => task())
        .whenComplete(() => completed.complete());
  }

  Future<StoredFile> save({
    required String owner,
    required String name,
    required String mime,
    required Stream<List<int>> body,
  }) async {
    final id = newId();
    final existingBytes = usage().$2;
    var size = 0;
    var seq = 0;
    final buffer = BytesBuilder(copy: false);
    void flush() {
      if (buffer.isEmpty) return;
      _putBlock(id, originalKind, seq++, buffer.takeBytes());
    }

    try {
      await for (final chunk in body) {
        size += chunk.length;
        if (size > maxBytes) {
          throw ApiException(
            413,
            'too_large',
            t('Datei ist größer als {mb} MB', {
              'mb': maxBytes ~/ (1024 * 1024),
            }),
          );
        }
        if (existingBytes + size > maxTotalBytes) {
          throw ApiException(
            413,
            'storage_quota_exceeded',
            t('Der Speicherplatz der Familie ist ausgeschöpft.'),
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
      throw ApiException.badRequest('empty', t('Leere Datei'));
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

  /// Every stored file, oldest first (e.g. for an export).
  List<StoredFile> all() => [
    for (final r in _db.select('SELECT * FROM files ORDER BY rowid'))
      StoredFile(
        id: r['id'] as String,
        owner: r['owner'] as String,
        name: r['name'] as String,
        mime: r['mime'] as String,
        size: r['size'] as int,
      ),
  ];

  bool mayRead(StoredFile file, String memberId) =>
      file.owner == memberId || records.referencedFor(file.id, memberId);

  /// The file's contents, block by block.
  Stream<List<int>> read(StoredFile file) => _readBlocks(file.id, originalKind);

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
    return _serializeThumbnail(() async {
      // Check after entering the queue too: a preceding request may have
      // produced the same preview while this one was waiting.
      final cached = _readAll(file.id, kind);
      if (cached != null) return cached;
      final bytes = _readAll(file.id, originalKind);
      if (bytes == null) return null;
      Uint8List? jpeg;
      try {
        jpeg = await _decodeThumbnail(bytes, size);
      } catch (_) {
        jpeg = null; // Unsupported or broken image.
      }
      if (jpeg != null) _putBlock(file.id, kind, 0, jpeg);
      return jpeg;
    });
  }

  static Future<Uint8List?> _decodeThumbnail(Uint8List bytes, int size) =>
      Isolate.run(() => _renderThumbnail((bytes, size)));

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

  /// Deletes every upload and gives the space back. Returns their number.
  int deleteAll() {
    final (count, _) = usage();
    _db.execute('DELETE FROM files');
    blobs.execute('DELETE FROM blobs');
    blobs.execute('VACUUM');
    return count;
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
            _putBlock(
              id,
              originalKind,
              seq,
              Uint8List.sublistView(bytes, o, end),
            );
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

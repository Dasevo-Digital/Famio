import 'dart:typed_data';

import 'package:famio_shared/famio_shared.dart';

import 'api_client.dart';
import 'platform/platform.dart';

/// Keeps downloaded files on the device, so photos and documents opened once
/// are available offline. Files never change (new upload = new id), so a
/// cached copy is always valid.
///
/// The cache is an encrypted database: documents and photos are never
/// stored in plain text, except for a short-lived copy in [tempDir] when a
/// file is handed to another app (PDF viewer …); [clearTemp] removes those.
class FileCache {
  FileCache._(this._blobs, this.api, this.tempDir);

  /// Opens the cache database at [path] (`:memory:` for tests; in the
  /// browser the cache stays in memory).
  factory FileCache.open(
    String path,
    FamioApiClient api, {
    String? hexKey,
    required String tempDir,
  }) => FileCache._(openBlobBackend(path, hexKey: hexKey), api, tempDir);

  final BlobBackend _blobs;
  final FamioApiClient api;

  /// Folder where decrypted copies for other apps are written.
  final String tempDir;
  final _pending = <String, Future<Uint8List>>{};

  /// Recently shown previews, most recent last. Handing out the same bytes
  /// again spares the database read and lets Flutter's image cache reuse
  /// the decoded picture instead of decoding it on every rebuild.
  final _recent = <String, Uint8List>{};
  var _recentBytes = 0;

  /// Upper bound for [_recent].
  static const recentLimit = 16 * 1024 * 1024;

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

  /// A plain copy of [ref] for opening it with another app; returns its
  /// path (not in the browser).
  Future<String> openable(FileRef ref) async =>
      writeTempFile(tempDir, '${ref.id}_${_safe(ref.name)}', await bytes(ref));

  /// Deletes plain copies made by [openable].
  void clearTemp() => clearTempFiles(tempDir);

  /// Puts freshly uploaded bytes into the cache, so the uploader never
  /// downloads their own file again.
  void put(FileRef ref, List<int> data) => _write(ref.id, data);

  void close() => _blobs.close();

  Uint8List? _read(String key) => switch (_blobs.read(key)) {
    null => null,
    final Uint8List data => data,
    final data => Uint8List.fromList(data),
  };

  void _write(String key, List<int> data) => _blobs.write(key, data);

  static String _safe(String name) => name.replaceAll(RegExp(r'[^\w.\-]'), '_');
}

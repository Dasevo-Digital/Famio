import 'package:famio_shared/famio_shared.dart';

import 'storage.dart';

// The web app keeps nothing in the browser: records and files live in
// memory for the visit and are loaded from the server again next time.

RecordBackend openRecordBackend(String path, {String? hexKey}) =>
    _MemoryRecords();

BlobBackend openBlobBackend(String path, {String? hexKey}) => _MemoryBlobs();

Future<String> writeTempFile(String dir, String name, List<int> data) =>
    throw UnsupportedError('No files in the browser – download instead.');

void clearTempFiles(String dir) {}

class _MemoryRecords implements RecordBackend {
  final _meta = <String, String?>{};

  @override
  Iterable<(SyncRecord, bool)> load() => const [];

  @override
  void put(SyncRecord record, {required bool dirty}) {}

  @override
  void markClean(String collection, String id) {}

  @override
  void begin() {}

  @override
  void commit() {}

  @override
  void rollback() {}

  @override
  String? getMeta(String key) => _meta[key];

  @override
  void setMeta(String key, String? value) => _meta[key] = value;

  @override
  void close() {}
}

/// Only previews and recently opened files, at most [limit] bytes.
class _MemoryBlobs implements BlobBackend {
  static const limit = 64 * 1024 * 1024;

  final _blobs = <String, List<int>>{};
  var _bytes = 0;

  @override
  List<int>? read(String key) => _blobs[key];

  @override
  void write(String key, List<int> data) {
    _bytes -= _blobs.remove(key)?.length ?? 0;
    if (data.length > limit ~/ 4) return;
    _blobs[key] = data;
    _bytes += data.length;
    while (_bytes > limit) {
      _bytes -= _blobs.remove(_blobs.keys.first)!.length;
    }
  }

  @override
  void close() => _blobs.clear();
}

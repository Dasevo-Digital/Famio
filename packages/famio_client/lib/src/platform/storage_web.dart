import '../snapshot_codec.dart';
import 'browser_copy.dart';
import 'storage.dart';
import 'memory_records.dart';

// By default the web app keeps nothing in the browser: records and files
// live in memory for the visit and are loaded from the server again next
// time. A member who asks for it keeps an encrypted copy of the records
// (browser_copy_web.dart); files are never kept.

/// Copies read before their store opens ([restoreCopy]).
final _restored = <String, StoreSnapshot>{};

/// The next [openRecordBackend] of [path] starts with [snapshot].
void restoreCopy(String path, StoreSnapshot snapshot) =>
    _restored[path] = snapshot;

RecordBackend openRecordBackend(String path, {String? hexKey}) =>
    MemoryRecordBackend(
      path,
      _restored.remove(path),
      writeCopy: (name, snapshot) =>
          writeBrowserCopy(name, encodeSnapshot(snapshot)),
      deleteCopy: deleteBrowserCopy,
    );

BlobBackend openBlobBackend(String path, {String? hexKey}) => _MemoryBlobs();

Future<String> writeTempFile(String dir, String name, List<int> data) =>
    throw UnsupportedError('No files in the browser – download instead.');

void clearTempFiles(String dir) {}

/// Only previews and recently opened files, at most [limit] bytes.
class _MemoryBlobs implements BlobBackend {
  static const limit = 64 * 1024 * 1024;

  final _blobs = <String, List<int>>{};
  var _bytes = 0;

  @override
  List<int>? read(String key) {
    // Most recently used last.
    final data = _blobs.remove(key);
    if (data != null) _blobs[key] = data;
    return data;
  }

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
  int get size => _bytes;

  @override
  void trim(int maxBytes) {
    while (_bytes > maxBytes && _blobs.isNotEmpty) {
      _bytes -= _blobs.remove(_blobs.keys.first)!.length;
    }
  }

  @override
  void clear() {
    _blobs.clear();
    _bytes = 0;
  }

  @override
  void close() => _blobs.clear();
}

import 'dart:async';

import 'package:famio_shared/famio_shared.dart';

import '../snapshot_codec.dart';
import 'browser_copy.dart';
import 'storage.dart';

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
    _MemoryRecords(path, _restored.remove(path));

BlobBackend openBlobBackend(String path, {String? hexKey}) => _MemoryBlobs();

Future<String> writeTempFile(String dir, String name, List<int> data) =>
    throw UnsupportedError('No files in the browser – download instead.');

void clearTempFiles(String dir) {}

class _MemoryRecords implements RecordBackend {
  _MemoryRecords(this._name, StoreSnapshot? restored) {
    if (restored == null) return;
    for (final (record, dirty) in restored.records) {
      _records[(record.collection, record.id)] = (record, dirty);
    }
    _meta.addAll(restored.meta);
  }

  final String _name;
  final _records = <(String, String), (SyncRecord, bool)>{};
  final _meta = <String, String>{};
  var _keep = false;
  Timer? _save;

  @override
  Iterable<(SyncRecord, bool)> load() => _records.values.toList();

  @override
  void put(SyncRecord record, {required bool dirty}) {
    _records[(record.collection, record.id)] = (record, dirty);
    _changed();
  }

  @override
  void markClean(String collection, String id) {
    final entry = _records[(collection, id)];
    if (entry == null) return;
    _records[(collection, id)] = (entry.$1, false);
    _changed();
  }

  @override
  void remove(String collection, String id) {
    _records.remove((collection, id));
    _changed();
  }

  @override
  void removeCleanDeleted() =>
      _records.removeWhere((_, e) => e.$1.deleted && !e.$2);

  @override
  void begin() {}

  @override
  void commit() {}

  @override
  void rollback() {}

  @override
  String? getMeta(String key) => _meta[key];

  @override
  void setMeta(String key, String? value) {
    if (value == null) {
      _meta.remove(key);
    } else {
      _meta[key] = value;
    }
    _changed();
  }

  @override
  void keepCopy(bool keep) {
    _keep = keep;
    _save?.cancel();
    if (keep) {
      unawaited(_write());
    } else {
      unawaited(deleteBrowserCopy(_name).catchError((Object _) {}));
    }
  }

  /// Writes the copy a moment after the last change (a sync brings many).
  void _changed() {
    if (!_keep) return;
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), _write);
  }

  Future<void> _write() async {
    try {
      await writeBrowserCopy(
        _name,
        encodeSnapshot((records: _records.values.toList(), meta: _meta)),
      );
    } on Object {
      // Private window or full storage: the copy waits for the next change.
    }
  }

  @override
  void close() {
    _save?.cancel();
    if (_keep) unawaited(_write());
  }
}

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

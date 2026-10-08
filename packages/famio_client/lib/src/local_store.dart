import 'package:famio_shared/famio_shared.dart';
import 'platform/platform.dart';

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
  LocalStore._(this._backend) {
    // Deletions the server knows need no copy (kept by apps before 1.0.10).
    _backend.removeCleanDeleted();
    for (final (record, dirty) in _backend.load()) {
      _cache.putIfAbsent(record.collection, () => {})[record.id] = LocalRecord(
        record,
        dirty: dirty,
      );
    }
  }

  /// Opens the store at [path], encrypted with [hexKey]; pass `:memory:`
  /// for tests. In the browser everything stays in memory.
  factory LocalStore.open(String path, {String? hexKey}) =>
      LocalStore._(openRecordBackend(path, hexKey: hexKey));

  final RecordBackend _backend;
  final _cache = <String, Map<String, LocalRecord>>{};

  LocalRecord? get(String collection, String id) => _cache[collection]?[id];

  Iterable<LocalRecord> all(String collection) =>
      _cache[collection]?.values ?? const [];

  Iterable<LocalRecord> get dirty =>
      _cache.values.expand((c) => c.values).where((r) => r.dirty);

  void put(SyncRecord record, {required bool dirty}) {
    _backend.put(record, dirty: dirty);
    _cache.putIfAbsent(record.collection, () => {})[record.id] = LocalRecord(
      record,
      dirty: dirty,
    );
  }

  void markClean(String collection, String id) {
    final local = get(collection, id);
    if (local == null || !local.dirty) return;
    if (local.record.deleted) {
      // The server has the deletion; the device needs no copy.
      remove(collection, id);
      return;
    }
    _backend.markClean(collection, id);
    _cache[collection]![id] = LocalRecord(local.record, dirty: false);
  }

  void remove(String collection, String id) {
    _backend.remove(collection, id);
    _cache[collection]?.remove(id);
  }

  /// Keys of all records, for finding the ones a full download lacks.
  Iterable<(String, String)> get keys => [
    for (final c in _cache.entries)
      for (final id in c.value.keys) (c.key, id),
  ];

  /// Runs [action] in one SQLite transaction.
  T transaction<T>(T Function() action) {
    _backend.begin();
    try {
      final result = action();
      _backend.commit();
      return result;
    } catch (_) {
      _backend.rollback();
      rethrow;
    }
  }

  String? getMeta(String key) => _backend.getMeta(key);

  void setMeta(String key, String? value) => _backend.setMeta(key, value);

  void close() => _backend.close();
}

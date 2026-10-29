import 'package:famio_shared/famio_shared.dart';

import 'platform/browser_copy.dart' as browser;
import 'platform/platform.dart';
import 'snapshot_codec.dart';

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

  /// Uses an adapter with the same transaction contract on every platform.
  factory LocalStore.fromBackend(RecordBackend backend) =>
      LocalStore._(backend);

  /// Opens the store at [path], encrypted with [hexKey]; pass `:memory:`
  /// for tests. In the browser everything stays in memory.
  factory LocalStore.open(String path, {String? hexKey}) =>
      LocalStore._(openRecordBackend(path, hexKey: hexKey));

  /// Opens the store at [path]; in the browser starting from the copy kept
  /// there ([keepInBrowser]), so the web app shows the family's data at
  /// once, also offline, and only fetches what changed. Elsewhere the same
  /// as [LocalStore.open].
  static Future<LocalStore> openWithBrowserCopy(
    String path, {
    String? hexKey,
  }) async {
    final bytes = await browser.readBrowserCopy(path);
    final snapshot = bytes == null ? null : decodeSnapshot(bytes);
    if (snapshot != null) restoreCopy(path, snapshot);
    return LocalStore.open(path, hexKey: hexKey);
  }

  /// Browser: deletes the copy of [path] and its key (signing out, or the
  /// member no longer wants it).
  static Future<void> deleteBrowserCopy(String path) =>
      browser.deleteBrowserCopy(path);

  /// Browser: keeps an encrypted copy of the records from now on (true), or
  /// deletes it (false). No effect in the apps, which keep their database.
  void keepInBrowser(bool keep) => _backend.keepCopy(keep);

  final RecordBackend _backend;
  final _cache = <String, Map<String, LocalRecord>>{};
  Map<(String, String), LocalRecord?>? _undo;

  void _remember(String collection, String id) =>
      _undo?.putIfAbsent((collection, id), () => get(collection, id));

  LocalRecord? get(String collection, String id) => _cache[collection]?[id];

  Iterable<LocalRecord> all(String collection) =>
      _cache[collection]?.values ?? const [];

  Iterable<LocalRecord> get dirty =>
      _cache.values.expand((c) => c.values).where((r) => r.dirty);

  void put(SyncRecord record, {required bool dirty}) {
    _remember(record.collection, record.id);
    _backend.put(record, dirty: dirty);
    _cache.putIfAbsent(record.collection, () => {})[record.id] = LocalRecord(
      record,
      dirty: dirty,
    );
  }

  void markClean(String collection, String id) {
    final local = get(collection, id);
    if (local == null || !local.dirty) return;
    _remember(collection, id);
    if (local.record.deleted) {
      // The server has the deletion; the device needs no copy.
      remove(collection, id);
      return;
    }
    _backend.markClean(collection, id);
    _cache[collection]![id] = LocalRecord(local.record, dirty: false);
  }

  void remove(String collection, String id) {
    _remember(collection, id);
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
    if (_undo != null) throw StateError('Nested transaction');
    _backend.begin();
    final undo = _undo = <(String, String), LocalRecord?>{};
    try {
      final result = action();
      _backend.commit();
      return result;
    } catch (_) {
      try {
        _backend.rollback();
      } finally {
        for (final entry in undo.entries) {
          final (collection, id) = entry.key;
          final previous = entry.value;
          if (previous == null) {
            _cache[collection]?.remove(id);
          } else {
            _cache.putIfAbsent(collection, () => {})[id] = previous;
          }
        }
      }
      rethrow;
    } finally {
      _undo = null;
    }
  }

  String? getMeta(String key) => _backend.getMeta(key);

  void setMeta(String key, String? value) => _backend.setMeta(key, value);

  void close() => _backend.close();
}

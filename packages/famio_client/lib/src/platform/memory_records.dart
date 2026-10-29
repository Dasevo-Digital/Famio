import 'dart:async';
import 'package:famio_shared/famio_shared.dart';
import '../snapshot_codec.dart';
import 'storage.dart';

class MemoryRecordBackend implements RecordBackend {
  MemoryRecordBackend(
    this._name,
    StoreSnapshot? restored, {
    required this.writeCopy,
    required this.deleteCopy,
  }) {
    if (restored == null) return;
    for (final (record, dirty) in restored.records) {
      _records[(record.collection, record.id)] = (record, dirty);
    }
    _meta.addAll(restored.meta);
  }

  final String _name;
  final Future<void> Function(String name, StoreSnapshot snapshot) writeCopy;
  final Future<void> Function(String name) deleteCopy;
  Map<(String, String), (SyncRecord, bool)?>? _undoRecords;
  Map<String, String?>? _undoMeta;
  bool _transactionChanged = false;

  void _remember(String collection, String id) => _undoRecords?.putIfAbsent((
    collection,
    id,
  ), () => _records[(collection, id)]);
  final _records = <(String, String), (SyncRecord, bool)>{};
  final _meta = <String, String>{};
  var _keep = false;
  Timer? _save;

  @override
  Iterable<(SyncRecord, bool)> load() => _records.values.toList();

  @override
  void put(SyncRecord record, {required bool dirty}) {
    _remember(record.collection, record.id);
    _records[(record.collection, record.id)] = (record, dirty);
    _changed();
  }

  @override
  void markClean(String collection, String id) {
    final entry = _records[(collection, id)];
    if (entry == null) return;
    _remember(collection, id);
    _records[(collection, id)] = (entry.$1, false);
    _changed();
  }

  @override
  void remove(String collection, String id) {
    _remember(collection, id);
    _records.remove((collection, id));
    _changed();
  }

  @override
  void removeCleanDeleted() =>
      _records.removeWhere((_, e) => e.$1.deleted && !e.$2);

  @override
  void begin() {
    if (_undoRecords != null) throw StateError('Nested transaction');
    _undoRecords = {};
    _undoMeta = {};
    _transactionChanged = false;
  }

  @override
  void commit() {
    final changed = _transactionChanged;
    _undoRecords = null;
    _undoMeta = null;
    _transactionChanged = false;
    if (changed) _changed();
  }

  @override
  void rollback() {
    for (final e in _undoRecords!.entries) {
      if (e.value == null) {
        _records.remove(e.key);
      } else {
        _records[e.key] = e.value!;
      }
    }
    for (final e in _undoMeta!.entries) {
      if (e.value == null) {
        _meta.remove(e.key);
      } else {
        _meta[e.key] = e.value!;
      }
    }
    _undoRecords = null;
    _undoMeta = null;
    _transactionChanged = false;
  }

  @override
  String? getMeta(String key) => _meta[key];

  @override
  void setMeta(String key, String? value) {
    _undoMeta?.putIfAbsent(key, () => _meta[key]);
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
      unawaited(deleteCopy(_name).catchError((Object _) {}));
    }
  }

  /// Writes the copy a moment after the last change (a sync brings many).
  void _changed() {
    if (_undoRecords != null) {
      _transactionChanged = true;
      return;
    }
    if (!_keep) return;
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), _write);
  }

  Future<void> _write() async {
    try {
      await writeCopy(_name, (
        records: _records.values.toList(),
        meta: Map.of(_meta),
      ));
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

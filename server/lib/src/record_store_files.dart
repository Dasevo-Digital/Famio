part of 'record_store.dart';

extension RecordFiles on RecordStore {
  void _indexFileRecord(SyncRecord record) {
    final key = (record.collection, record.id);
    for (final file in _filesByRecord.remove(key) ?? const <String>{}) {
      final references = _recordsByFile[file]!;
      references.remove(key);
      if (references.isEmpty) _recordsByFile.remove(file);
    }
    _damagedFileRecords.remove(key);
    if (record.deleted) return;
    if (!recordDataIsValid(record)) {
      _damagedFileRecords[key] = jsonEncode(record.data);
      return;
    }
    final files = recordFileIds(record).toSet();
    if (files.isNotEmpty) _filesByRecord[key] = files;
    for (final file in files) {
      _recordsByFile.putIfAbsent(file, () => {}).add(key);
    }
  }

  void _indexFileTrash() {
    _trashByFile.clear();
    _damagedFileTrash.clear();
    for (final row in _db.select('SELECT * FROM trash WHERE expires_at > ?', [
      DateTime.now().millisecondsSinceEpoch,
    ])) {
      final entry = _trashEntry(row);
      if (!recordDataIsValid(entry.record)) {
        _damagedFileTrash[entry.id] = row['snapshot'] as String;
        continue;
      }
      for (final file in recordFileIds(entry.record)) {
        _trashByFile.putIfAbsent(file, () => {}).add(entry.id);
      }
    }
  }

  /// Forgets the index. A rolled-back transaction can have indexed rows that
  /// never got committed, and the next commit reuses their revisions, so a
  /// revision comparison alone would not notice.
  void _resetFileReferences() {
    _fileIndexEpoch++;
    _fileIndexRev = -1;
    _filesByRecord.clear();
    _recordsByFile.clear();
    _damagedFileRecords.clear();
    _trashByFile.clear();
    _damagedFileTrash.clear();
  }

  void _refreshFileReferences() {
    final through = currentRev;
    if (_fileIndexRev == through) return;
    if (_fileIndexRev > through) _resetFileReferences();
    for (final row in _db.select(
      'SELECT * FROM records WHERE rev > ? AND rev <= ? ORDER BY rev',
      [_fileIndexRev, through],
    )) {
      _indexFileRecord(RecordStore._record(row));
    }
    _indexFileTrash();
    _fileIndexRev = through;
  }

  /// Maintenance yields between batches. Subsequent checks apply any writes
  /// that arrived during those yields before deciding whether to delete a file.
  Future<void> prepareFileReferences() async {
    final through = currentRev;
    final epoch = _fileIndexEpoch;
    var cursor = _fileIndexRev;
    while (cursor < through) {
      // A reset while this yielded leaves the rows before the cursor out of
      // the index; the next check rebuilds it from scratch instead.
      if (_fileIndexEpoch != epoch || _fileIndexRev > through) return;
      final rows = _db.select(
        'SELECT * FROM records WHERE rev > ? AND rev <= ? ORDER BY rev LIMIT 100',
        [cursor, through],
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        final record = RecordStore._record(row);
        _indexFileRecord(record);
        cursor = record.rev;
      }
      await Future<void>.delayed(Duration.zero);
    }
    // Another request can have refreshed the index while maintenance yielded.
    // Never move its revision backwards.
    if (_fileIndexEpoch == epoch && _fileIndexRev <= through) {
      _indexFileTrash();
      _fileIndexRev = through;
    }
  }

  bool _indexedTrashReference(String file, {String? memberId}) {
    final candidates = <String>{
      ...?_trashByFile[file],
      if (memberId == null)
        ..._damagedFileTrash.entries
            .where((e) => e.value.contains(file))
            .map((e) => e.key),
    };
    for (final id in candidates) {
      final row = _db.select(
        'SELECT * FROM trash WHERE id = ? AND expires_at > ?',
        [id, DateTime.now().millisecondsSinceEpoch],
      ).firstOrNull;
      if (row == null) continue;
      if (memberId == null) return true;
      if (_trashVisible(_trashEntry(row), memberId)) return true;
    }
    return false;
  }
}

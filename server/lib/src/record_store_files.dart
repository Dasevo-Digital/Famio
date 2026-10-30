part of 'record_store.dart';

extension RecordFiles on RecordStore {
  SyncRecord _canonicalFiles(SyncRecord record) {
    final resolve = canonicalFile;
    if (resolve == null) return record;
    try {
      return mapRecordFiles(record, resolve);
    } on FormatException {
      return record; // Damaged records retain their existing quarantine.
    } on TypeError {
      return record;
    }
  }

  /// Once after upgrading, repair legacy metadata without changing authors
  /// or edit times. Batches bound memory; new revisions reach existing clients.
  int repairFileMetadata() {
    const key = 'canonicalFileMetadata1';
    if (canonicalFile == null ||
        _db.select('SELECT 1 FROM settings WHERE key = ?', [key]).isNotEmpty) {
      return 0;
    }
    var repaired = 0, cursor = 0;
    SyncRecord? readable(Row row, {bool trash = false}) {
      try {
        return trash ? _trashEntry(row).record : RecordStore._record(row);
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      }
    }

    // Replacements get new rowids, so fix the scan's original upper bound.
    final last =
        _db
                .select('SELECT COALESCE(MAX(rowid), 0) FROM records')
                .first
                .columnAt(0)
            as int;
    while (cursor < last) {
      final rows = _db.select(
        'SELECT rowid AS scan_id, * FROM records WHERE rowid > ? AND rowid <= ? ORDER BY rowid LIMIT 100',
        [cursor, last],
      );
      if (rows.isEmpty) break;
      _transaction(() {
        for (final row in rows) {
          cursor = row['scan_id'] as int;
          final old = readable(row);
          if (old == null) continue;
          final next = _canonicalFiles(old);
          if (identical(old, next)) continue;
          _keepAssignmentReplies(old, next);
          _put(next, previous: old);
          repaired++;
        }
      });
    }
    cursor = 0;
    while (true) {
      final rows = _db.select(
        'SELECT rowid AS scan_id, * FROM trash WHERE rowid > ? ORDER BY rowid LIMIT 100',
        [cursor],
      );
      if (rows.isEmpty) break;
      _transaction(() {
        for (final row in rows) {
          cursor = row['scan_id'] as int;
          final old = readable(row, trash: true);
          if (old == null) continue;
          final next = _canonicalFiles(old);
          if (identical(old, next)) continue;
          _db.execute('UPDATE trash SET snapshot = ? WHERE rowid = ?', [
            jsonEncode(next.toJson()),
            cursor,
          ]);
          repaired++;
        }
      });
    }
    _db.execute('INSERT INTO settings (key, value) VALUES (?, ?)', [key, '1']);
    return repaired;
  }

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

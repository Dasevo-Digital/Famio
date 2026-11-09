part of 'record_store.dart';

const trashRetention = Duration(days: 30);
const _trashCollections = {
  Collections.tasks,
  Collections.notes,
  Collections.events,
  Collections.documents,
};

extension RecordTrash on RecordStore {
  void _rememberDeletion(SyncRecord r, SyncRecord? before, int rev) {
    if (!_trashCollections.contains(r.collection)) return;
    if (!r.deleted) {
      _db.execute('DELETE FROM trash WHERE collection = ? AND record_id = ?', [
        r.collection,
        r.id,
      ]);
      return;
    }
    if (before == null) return;
    if (before.deleted) {
      // A later deletion from another device retains the original expiry.
      _db.execute(
        'UPDATE trash SET deleted_rev = ? WHERE collection = ? AND record_id = ? AND deleted_rev = ?',
        [rev, r.collection, r.id, before.rev],
      );
      return;
    }
    final now = DateTime.now();
    _db.execute(
      'INSERT INTO trash '
      '(id, collection, record_id, snapshot, deleted_rev, deleted_at, deleted_by, expires_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        newId(),
        r.collection,
        r.id,
        jsonEncode(before.toJson()),
        rev,
        now.millisecondsSinceEpoch,
        r.updatedBy,
        now.add(trashRetention).millisecondsSinceEpoch,
      ],
    );
  }

  /// Health documents in the bin that only [memberId] could get back.
  void _forgetTrashOf(String memberId) {
    for (final row in _db.select('SELECT * FROM trash')) {
      final entry = _trashEntry(row);
      final audience = entry.record.visibleTo;
      if (audience?.length == 1 &&
          audience!.single == memberId &&
          RecordStore._isPersonalHealth(entry.record)) {
        _db.execute('DELETE FROM trash WHERE id = ?', [entry.id]);
      }
    }
  }

  TrashEntry _trashEntry(Row row) => TrashEntry(
    id: row['id'] as String,
    record: SyncRecord.fromJson(
      (jsonDecode(row['snapshot'] as String) as Map).cast(),
    ),
    deletedAt: DateTime.fromMillisecondsSinceEpoch(row['deleted_at'] as int),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int),
    deletedBy: row['deleted_by'] as String?,
    deletedRev: row['deleted_rev'] as int,
  );

  bool _trashVisible(TrashEntry entry, String memberId) {
    if (!recordDataIsValid(entry.record)) return false;
    final current = _get(entry.record.collection, entry.record.id);
    final snapshot = entry.record.collection == Collections.tasks
        ? _withSubstitutes(entry.record, entry.record)
        : entry.record;
    return entry.expiresAt.isAfter(DateTime.now()) &&
        current != null &&
        current.deleted &&
        current.rev == entry.deletedRev &&
        RecordStore._canSee(current, memberId) &&
        canAccess(snapshot, memberId) &&
        // In the trash there is no busy time to reduce it to.
        (_role(memberId) != MemberRole.service ||
            _confidentialEvent(snapshot) == null);
  }

  /// Pagination advances across inaccessible rows without revealing them.
  (List<TrashEntry>, int?) trashFor(String memberId, {int? before}) {
    final rows = _db.select(
      'SELECT * FROM trash WHERE expires_at > ? '
      'AND (? IS NULL OR deleted_rev < ?) ORDER BY deleted_rev DESC LIMIT 101',
      [DateTime.now().millisecondsSinceEpoch, before, before],
    );
    final page = rows.take(100).toList();
    return (
      [
        for (final row in page)
          if (_trashEntry(row) case final e when _trashVisible(e, memberId)) e,
      ],
      rows.length > 100 ? page.last['deleted_rev'] as int : null,
    );
  }

  /// The check and restore share a transaction: a second device cannot
  /// overwrite a restored or newly created version using an old snapshot.
  void restoreTrash(String memberId, String id) {
    SyncRecord? restored;
    _transaction(() {
      final row = _db.select('SELECT * FROM trash WHERE id = ?', [
        id,
      ]).firstOrNull;
      final entry = row == null ? null : _trashEntry(row);
      if (entry == null || !_trashVisible(entry, memberId)) {
        throw ApiException(404, 'not_found', t('Eintrag nicht gefunden'));
      }
      final old = entry.record;
      final current = _get(old.collection, old.id)!;
      final access = accessOf?.call(memberId) ?? ServiceAccess.full;
      if (!RecordStore.mayWrite(
        _role(memberId),
        memberId,
        old,
        current,
        access: access,
      )) {
        throw ApiException(403, 'forbidden', t('Keine Berechtigung'));
      }
      _validate(old);
      if (recordFileIds(
        old,
      ).any((f) => !(mayReferenceFile?.call(f, memberId) ?? false))) {
        throw ApiException.badRequest(
          'invalid_file_reference',
          t('Kein Zugriff auf die angehängte Datei.'),
        );
      }
      var next = old.copyWith(
        updatedAt: max(
          DateTime.now().millisecondsSinceEpoch,
          current.updatedAt + 1,
        ),
        updatedBy: memberId,
      );
      if (old.collection == Collections.tasks) {
        next = _withSubstitutes(RecordStore._taskAudience(next, current), old);
      }
      _put(next, previous: current);
      restored = next;
    });
    if (restored != null) onStored?.call(memberId, [(restored!, null)]);
  }

  bool mayRestoreTrash(String memberId, TrashEntry entry) =>
      _trashVisible(entry, memberId) &&
      RecordStore.mayWrite(
        _role(memberId),
        memberId,
        entry.record,
        _get(entry.record.collection, entry.record.id),
        access: accessOf?.call(memberId) ?? ServiceAccess.full,
      );

  int expireTrash({DateTime? now}) {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    _db.execute('DELETE FROM trash WHERE expires_at <= ?', [at]);
    final expired = _db.updatedRows;
    _removeCommentsOfDeletedEvents(at);
    return expired;
  }

  /// Comments wait with their appointment while it can still come back from
  /// the trash, and go for good after that.
  void _removeCommentsOfDeletedEvents(int at) {
    final comments = [
      for (final row in _db.select(
        'SELECT c.* FROM records c '
        'JOIN records e ON e.collection = ? AND e.deleted = 1 '
        "AND e.id = json_extract(c.data, '\$.eventId') "
        'WHERE c.collection = ? AND c.deleted = 0 AND NOT EXISTS '
        '(SELECT 1 FROM trash t WHERE t.collection = ? AND t.record_id = e.id)',
        [Collections.events, Collections.eventComments, Collections.events],
      ))
        RecordStore._record(row),
    ];
    if (comments.isEmpty) return;
    _transaction(() {
      for (final c in comments) {
        _put(
          SyncRecord(
            collection: c.collection,
            id: c.id,
            data: {SyncRecord.visibilityKey: ?c.visibleTo},
            deleted: true,
            updatedAt: at,
            updatedBy: RecordStore.serverMemberId,
          ),
          previous: c,
        );
      }
    });
  }

  List<TrashEntry> trashForExport({String? memberId}) => [
    for (final row in _db.select(
      'SELECT * FROM trash WHERE expires_at > ? ORDER BY deleted_rev',
      [DateTime.now().millisecondsSinceEpoch],
    ))
      if (_trashEntry(row) case final e
          when memberId == null || _trashVisible(e, memberId))
        e,
  ];
}

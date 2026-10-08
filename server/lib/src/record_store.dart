import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import 'api_exception.dart';

/// Persists [SyncRecord]s, hands out monotonically increasing revisions and
/// enforces per-record visibility ([SyncRecord.visibleTo]).
class RecordStore {
  RecordStore(
    this._db, {
    required this.memberIds,
    this.roleOf,
    this.accessOf,
  });

  final Database _db;

  /// Roles limit guests to some collections and keep children from
  /// managing chores and pocket money (see [Collections.guestReadable]).
  final MemberRole Function(String userId)? roleOf;

  MemberRole _role(String userId) => roleOf?.call(userId) ?? MemberRole.adult;

  /// What service accounts may change (see [ServiceAccess]).
  final ServiceAccess Function(String userId)? accessOf;

  /// Called after changes were stored by [sync] (not by [writeAsServer]),
  /// with the previous versions, e.g. for push notifications.
  void Function(String userId, List<(SyncRecord, SyncRecord?)> stored)?
  onStored;

  /// Called after [writeAsServer] stored changes.
  void Function(List<SyncRecord> stored)? onServerStored;

  /// Whether [userId] may receive [r]: its audience and the member's role.
  bool canAccess(SyncRecord r, String userId) =>
      _canSee(r, userId) &&
      (_role(userId) != MemberRole.guest ||
          Collections.guestReadable.contains(r.collection));

  /// Whether [role] may store [incoming] (over [existing]).
  static bool mayWrite(
    MemberRole role,
    String userId,
    SyncRecord incoming,
    SyncRecord? existing, {
    ServiceAccess access = ServiceAccess.full,
  }) {
    final collection = incoming.collection;
    switch (role) {
      case MemberRole.adult:
        return true;
      case MemberRole.service:
        return switch (access) {
          ServiceAccess.full => true,
          ServiceAccess.readOnly => false,
          ServiceAccess.everyday => _everyday(incoming, existing),
        };
      case MemberRole.guest:
        return Collections.guestWritable.contains(collection);
      case MemberRole.child:
        if (Collections.adultOnly.contains(collection)) return false;
        if (collection != Collections.pointEntries) return true;
        // Children ask for points (done chores, wished rewards); adults
        // decide. Their own open requests they may change or withdraw.
        bool ownPending(SyncRecord r) =>
            r.data['memberId'] == userId && r.data['status'] == 'pending';
        if (existing != null && !existing.deleted && !ownPending(existing)) {
          return false;
        }
        return incoming.deleted || ownPending(incoming);
    }
  }

  /// Ids of all family members; needed when a record visible to everyone
  /// becomes restricted, to know who loses access.
  final List<String> Function() memberIds;

  static const pageSize = 500;
  static const _maxDataBytes = 256 * 1024;

  /// Clients may be a little ahead of the server clock, but not much; a
  /// far-future timestamp would otherwise win every conflict forever.
  static const _maxClockSkew = Duration(minutes: 2);

  /// `updatedAt` of tombstones for revoked records: beats any local copy, so
  /// the record disappears even if the member edited it offline.
  static const revokedAt = 8640000000000000;

  /// `updatedBy` of records written by the server itself.
  static const serverMemberId = 'server';

  /// Live (not deleted) records per collection, for the admin overview.
  Map<String, int> counts() => {
    for (final row in _db.select(
      'SELECT collection, COUNT(*) AS n FROM records WHERE deleted = 0'
      ' GROUP BY collection ORDER BY collection',
    ))
      row['collection'] as String: row['n'] as int,
  };

  /// Never goes back, also when the newest record was a cleaned-up
  /// deletion mark (see [purgedRev]).
  int get currentRev => max(
    _db.select('SELECT COALESCE(MAX(rev), 0) FROM records').first.columnAt(0)
        as int,
    purgedRev,
  );

  static const _resetKey = 'dataResetAt';
  static const _purgedKey = 'purgedRev';

  /// Highest revision of a deletion mark that was cleaned up: a client
  /// behind it may have missed deletions and has to download everything.
  late int purgedRev = int.tryParse(_setting(_purgedKey) ?? '') ?? 0;

  /// How long deletion marks are kept: devices offline for longer download
  /// everything again.
  static const keepDeleted = Duration(days: 180);

  String? _setting(String key) =>
      _db
              .select('SELECT value FROM settings WHERE key = ?', [key])
              .firstOrNull
              ?.columnAt(0)
          as String?;

  /// Notes the current revision with the time and removes deletion marks
  /// (and revocations) that were older than [keepDeleted] by the server's
  /// clock. Run regularly; returns how many were removed.
  int purgeDeleted({DateTime? now}) {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final cutoff = at - keepDeleted.inMilliseconds;
    var removed = 0;
    _transaction(() {
      _db.execute(
        'INSERT OR REPLACE INTO rev_marks (at, rev) VALUES (?, ?)',
        [at, currentRev],
      );
      final horizon = _db
          .select(
            'SELECT at, rev FROM rev_marks WHERE at <= ? ORDER BY at DESC'
            ' LIMIT 1',
            [cutoff],
          )
          .firstOrNull;
      if (horizon == null) return;
      final rev = horizon['rev'] as int;
      // Older marks are no longer needed; the horizon stays as a floor.
      _db.execute('DELETE FROM rev_marks WHERE at < ?', [horizon['at']]);
      final purged = _db
          .select(
            'SELECT MAX(rev) FROM ('
            ' SELECT rev FROM records WHERE deleted = 1 AND rev <= ?1'
            ' UNION ALL SELECT rev FROM revocations WHERE rev <= ?1)',
            [rev],
          )
          .first
          .columnAt(0) as int?;
      if (purged == null) return;
      _db.execute('DELETE FROM records WHERE deleted = 1 AND rev <= ?', [rev]);
      removed += _db.updatedRows;
      _db.execute('DELETE FROM revocations WHERE rev <= ?', [rev]);
      removed += _db.updatedRows;
      if (purged > purgedRev) {
        purgedRev = purged;
        _db.execute(
          'INSERT INTO settings (key, value) VALUES (?, ?)'
          ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [_purgedKey, '$purged'],
        );
      }
    });
    return removed;
  }

  /// When an admin last deleted all data (ms since epoch, 0: never).
  late int resetAt =
      int.tryParse(
        _db
                    .select('SELECT value FROM settings WHERE key = ?', [
                      _resetKey,
                    ])
                    .firstOrNull
                    ?.columnAt(0)
                as String? ??
            '',
      ) ??
      0;

  /// Deletes every record, e.g. before a family starts over. Each one
  /// becomes an empty tombstone, so the apps delete their copies as well;
  /// changes made offline before now lose against it (see [resetAt]).
  /// Returns the number of records deleted.
  int wipe() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var count = 0;
    _transaction(() {
      final rows = _db.select(
        'SELECT collection, id, visible_to FROM records WHERE deleted = 0'
        ' ORDER BY rev',
      );
      var rev = currentRev;
      final update = _db.prepare(
        'UPDATE records SET data = ?, deleted = 1, updated_at = ?,'
        ' updated_by = ?, rev = ? WHERE collection = ? AND id = ?',
      );
      for (final row in rows) {
        final audience = row['visible_to'] as String?;
        update.execute([
          // Tombstones keep their audience (see [sync]).
          audience == null ? '{}' : '{"${SyncRecord.visibilityKey}":$audience}',
          now + _maxClockSkew.inMilliseconds,
          serverMemberId,
          ++rev,
          row['collection'],
          row['id'],
        ]);
      }
      update.close();
      _db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?)'
        ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [_resetKey, '$now'],
      );
      count = rows.length;
    });
    resetAt = now;
    return count;
  }

  /// Applies [request] for [userId] and returns the pull part of the answer.
  /// Runs synchronously, so concurrent requests cannot interleave.
  SyncResponse sync(SyncRequest request, String userId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final role = _role(userId);
    final access = role == MemberRole.service
        ? accessOf?.call(userId) ?? ServiceAccess.full
        : ServiceAccess.full;
    final stored = <(SyncRecord, SyncRecord?)>[];
    final rejected = <SyncRecord>[];
    final unsupported = <String>{};
    // A client ahead of the server means the server database was reset:
    // send it everything again. One behind cleaned-up deletion marks gets
    // everything too and drops what it does not receive (newer apps only;
    // older ones would ask again and again).
    final reset =
        request.resettable &&
        !request.full &&
        request.since > 0 &&
        request.since < purgedRev;
    final since = request.since > currentRev || reset ? 0 : request.since;
    // Newer clients may know collections this server does not; skip those
    // instead of failing the whole sync.
    final accepted = <SyncRecord>[];
    for (final change in request.changes) {
      if (Collections.serverOwned.contains(change.collection)) {
        // Read-only for clients: answer with the server's version, if any.
        final existing = _get(change.collection, change.id);
        if (existing != null && canAccess(existing, userId)) {
          rejected.add(existing);
        }
      } else if (Collections.all.contains(change.collection)) {
        _validate(change);
        accepted.add(change);
      } else {
        unsupported.add(change.collection);
      }
    }

    _transaction(() {
      for (final change in accepted) {
        var incoming = change.copyWith(
          updatedBy: userId,
          updatedAt: min(change.updatedAt, now + _maxClockSkew.inMilliseconds),
        );
        final existing = _get(change.collection, change.id);
        if (existing != null && !canAccess(existing, userId)) {
          // Not theirs to change. Stay silent so nothing leaks; if they lost
          // access recently, their revocation tombstone removes the copy.
          continue;
        }
        if (!mayWrite(
          role,
          userId,
          incoming,
          existing,
          access: access,
        )) {
          // Undo the change on the device: the stored version, or a
          // tombstone for something that must not exist.
          rejected.add(
            existing ??
                SyncRecord(
                  collection: change.collection,
                  id: change.id,
                  data: const {},
                  deleted: true,
                  updatedAt: revokedAt,
                  updatedBy: serverMemberId,
                ),
          );
          continue;
        }
        if ((existing == null || existing.deleted) &&
            incoming.updatedAt < resetAt) {
          // Written offline before an admin deleted all data: gone too.
          rejected.add(
            SyncRecord(
              collection: change.collection,
              id: change.id,
              data: const {},
              deleted: true,
              updatedAt: revokedAt,
              updatedBy: serverMemberId,
            ),
          );
          continue;
        }
        if (existing != null &&
            existing.updatedAt == incoming.updatedAt &&
            existing.updatedBy == incoming.updatedBy) {
          continue; // Re-sent after a lost response; already stored.
        }
        if (change.collection == Collections.calendarSubscriptions) {
          // Connected calendars belong to whoever added them; the others
          // may see them (if shared) but not change or remove them.
          final owner = existing?.data['ownerId'];
          if (owner != null && owner != userId && !existing!.deleted) {
            rejected.add(existing);
            continue;
          }
          if (!incoming.deleted &&
              incoming.data['ownerId'] != null &&
              incoming.data['ownerId'] != userId) {
            incoming = incoming.copyWith(
              data: {...incoming.data, 'ownerId': userId},
            );
          }
        }
        if (existing != null && !incoming.winsOver(existing)) {
          rejected.add(existing);
          continue;
        }
        if (incoming.deleted) {
          // Tombstones keep the old audience: only they need to know.
          incoming = incoming.copyWith(
            data: {
              if (existing?.visibleTo != null)
                SyncRecord.visibilityKey: existing!.visibleTo,
            },
          );
        } else if (incoming.visibleTo case final ids?
            when !ids.contains(userId)) {
          // Authors always keep access to what they write.
          incoming = incoming.copyWith(
            data: {
              ...incoming.data,
              SyncRecord.visibilityKey: [...ids, userId],
            },
          );
        }
        _put(incoming, previous: existing);
        stored.add((incoming, existing));
      }
    });

    if (stored.isNotEmpty) onStored?.call(userId, stored);
    return _pull(
      userId,
      since,
      now,
      rejected,
      unsupported,
      role,
      reset: reset,
    );
  }

  SyncResponse _pull(
    String userId,
    int since,
    int now,
    List<SyncRecord> rejected,
    Set<String> unsupported,
    MemberRole role, {
    bool reset = false,
  }) {
    // Guests only get their collections (names are constants, no input).
    final only = role == MemberRole.guest
        ? 'AND collection IN (${Collections.guestReadable.map((c) => "'$c'").join(', ')})'
        : '';
    final rows = _db.select(
      '''
      SELECT collection, id, data, deleted, updated_at, updated_by, rev
        FROM records
       WHERE rev > ?1 $only
         AND (visible_to IS NULL
              OR EXISTS (SELECT 1 FROM json_each(visible_to) WHERE value = ?2))
      UNION ALL
      SELECT collection, id, '{}', 1, $revokedAt, '$serverMemberId', rev
        FROM revocations
       WHERE member_id = ?2 AND rev > ?1 $only
      ORDER BY rev
      LIMIT ?3
      ''',
      [since, userId, pageSize + 1],
    );
    final hasMore = rows.length > pageSize;
    final changes = [for (final r in rows.take(pageSize)) _record(r)];
    return SyncResponse(
      rev: hasMore ? changes.last.rev : currentRev,
      serverTime: now,
      changes: changes,
      rejected: rejected,
      unsupported: unsupported,
      hasMore: hasMore,
      reset: reset,
    );
  }

  /// Writes [r] with the next revision and updates revocations: members who
  /// could see [previous] but not [r] get a tombstone, members who regain
  /// access lose their revocation.
  void _put(SyncRecord r, {required SyncRecord? previous}) {
    final rev = currentRev + 1;
    final audience = r.visibleTo;
    _db.execute(
      'INSERT OR REPLACE INTO records'
      ' (collection, id, data, deleted, updated_at, updated_by, rev, visible_to)'
      ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        r.collection,
        r.id,
        jsonEncode(r.data),
        r.deleted ? 1 : 0,
        r.updatedAt,
        r.updatedBy,
        rev,
        audience == null ? null : jsonEncode(audience),
      ],
    );

    if (audience == null) {
      _db.execute('DELETE FROM revocations WHERE collection = ? AND id = ?', [
        r.collection,
        r.id,
      ]);
      return;
    }
    for (final member in audience) {
      _db.execute(
        'DELETE FROM revocations WHERE member_id = ? AND collection = ? AND id = ?',
        [member, r.collection, r.id],
      );
    }
    if (previous == null || previous.deleted) return;
    final before = previous.visibleTo ?? memberIds();
    for (final member in before.where((m) => !audience.contains(m))) {
      _db.execute(
        'INSERT OR REPLACE INTO revocations (member_id, collection, id, rev)'
        ' VALUES (?, ?, ?, ?)',
        [member, r.collection, r.id, rev],
      );
    }
  }

  /// [ServiceAccess.everyday]: shopping lists' items, ticking off existing
  /// tasks and routine steps, and asking for the points of a done chore (like
  /// the shared wall display) – nothing else.
  static bool _everyday(SyncRecord incoming, SyncRecord? existing) {
    switch (incoming.collection) {
      case Collections.shoppingItems:
      case Collections.routineRuns:
        return true;
      case Collections.tasks:
        if (existing == null || existing.deleted || incoming.deleted) {
          return false;
        }
        const ticks = {'done', 'completedAt'};
        // Missing, null and "" are the same (clients write empty fields).
        String same(Object? v) => jsonEncode(v == '' ? null : v);
        final keys = {...existing.data.keys, ...incoming.data.keys};
        return keys.every(
          (k) =>
              ticks.contains(k) ||
              same(existing.data[k]) == same(incoming.data[k]),
        );
      case Collections.pointEntries:
        bool pending(SyncRecord r) => r.data['status'] == 'pending';
        if (existing != null && !existing.deleted && !pending(existing)) {
          return false;
        }
        return incoming.deleted || pending(incoming);
      default:
        return false;
    }
  }

  static bool _canSee(SyncRecord r, String userId) =>
      r.visibleTo?.contains(userId) ?? true;

  void _validate(SyncRecord r) {
    if (r.id.isEmpty || r.id.length > 64) {
      throw ApiException.badRequest('invalid_id', 'Ungültige ID: ${r.id}');
    }
    if (utf8.encode(jsonEncode(r.data)).length > _maxDataBytes) {
      throw ApiException(413, 'too_large', 'Eintrag ist zu groß');
    }
  }

  /// Live (non-deleted) records of [collection], optionally only those
  /// [visibleToMember].
  List<SyncRecord> all(String collection, {String? visibleToMember}) {
    if (visibleToMember != null &&
        _role(visibleToMember) == MemberRole.guest &&
        !Collections.guestReadable.contains(collection)) {
      return const [];
    }
    return [
      for (final row in _db.select(
        'SELECT * FROM records WHERE collection = ? AND deleted = 0',
        [collection],
      ))
        if (visibleToMember == null || _canSee(_record(row), visibleToMember))
          _record(row),
    ];
  }

  /// Whether a live record visible to [memberId] mentions [text] (e.g. a
  /// file id) in its data. Used to authorise file downloads.
  bool referencedFor(String text, String memberId) {
    final only = _role(memberId) == MemberRole.guest
        ? 'AND collection IN (${Collections.guestReadable.map((c) => "'$c'").join(', ')})'
        : '';
    final rows = _db.select(
      '''
      SELECT 1 FROM records
       WHERE deleted = 0 AND instr(data, ?1) > 0 $only
         AND (visible_to IS NULL
              OR EXISTS (SELECT 1 FROM json_each(visible_to) WHERE value = ?2))
       LIMIT 1
      ''',
      [text, memberId],
    );
    return rows.isNotEmpty;
  }

  /// Whether any live record mentions [text].
  bool referenced(String text) => _db.select(
    'SELECT 1 FROM records WHERE deleted = 0 AND instr(data, ?) > 0 LIMIT 1',
    [text],
  ).isNotEmpty;

  /// The stored version of a record (also tombstones), or null.
  SyncRecord? get(String collection, String id) => _get(collection, id);

  static bool canSee(SyncRecord r, String userId) => _canSee(r, userId);

  /// Stores [changes] as if [userId] had synced them (conflict resolution,
  /// visibility rules). Returns the stored versions that won over them.
  List<SyncRecord> writeAs(String userId, List<SyncRecord> changes) =>
      sync(SyncRequest(since: currentRev, changes: changes), userId).rejected;

  /// Highest revision that changed [collection] for [memberId] (including
  /// deletions and lost access), e.g. as a change tag for calendar apps.
  int collectionRev(String collection, String memberId) =>
      _db
              .select(
                'SELECT MAX(r) FROM ('
                ' SELECT MAX(rev) AS r FROM records WHERE collection = ?1'
                ' UNION ALL SELECT MAX(rev) FROM revocations'
                ' WHERE collection = ?1 AND member_id = ?2)',
                [collection, memberId],
              )
              .first
              .columnAt(0)
          as int? ??
      0;

  /// Records of [collection] changed after [rev] (tombstones included) and
  /// ids [memberId] lost access to since then.
  (List<SyncRecord>, Set<String>) changesSince(
    String collection,
    int rev,
    String memberId,
  ) => (
    [
      for (final row in _db.select(
        'SELECT * FROM records WHERE collection = ? AND rev > ? ORDER BY rev',
        [collection, rev],
      ))
        _record(row),
    ],
    {
      for (final row in _db.select(
        'SELECT id FROM revocations'
        ' WHERE collection = ? AND member_id = ? AND rev > ?',
        [collection, memberId, rev],
      ))
        row['id'] as String,
    },
  );

  /// Stores records on behalf of the server itself (e.g. imported calendar
  /// events), bypassing conflict resolution. Returns true if anything changed.
  bool writeAsServer(Iterable<SyncRecord> records) {
    var changed = false;
    final stored = <SyncRecord>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    _transaction(() {
      for (final r in records) {
        final existing = _get(r.collection, r.id);
        final data = r.deleted ? const <String, Object?>{} : r.data;
        if (existing != null &&
            existing.deleted == r.deleted &&
            jsonEncode(existing.data) == jsonEncode(data)) {
          continue;
        }
        if (existing == null && r.deleted) continue;
        final record = r.copyWith(
          data: data,
          // Ahead of any client edit, so server data always wins.
          updatedAt: max(now, (existing?.updatedAt ?? 0) + 1),
          updatedBy: serverMemberId,
        );
        _put(record, previous: existing);
        if (existing == null || existing.deleted) stored.add(record);
        changed = true;
      }
    });
    if (stored.isNotEmpty) onServerStored?.call(stored);
    return changed;
  }

  void _transaction(void Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      action();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  SyncRecord? _get(String collection, String id) {
    final rows = _db.select(
      'SELECT * FROM records WHERE collection = ? AND id = ?',
      [collection, id],
    );
    return rows.isEmpty ? null : _record(rows.first);
  }

  static SyncRecord _record(Row row) => SyncRecord(
    collection: row['collection'] as String,
    id: row['id'] as String,
    data: (jsonDecode(row['data'] as String) as Map).cast(),
    deleted: row['deleted'] == 1,
    updatedAt: row['updated_at'] as int,
    updatedBy: row['updated_by'] as String?,
    rev: row['rev'] as int,
  );
}

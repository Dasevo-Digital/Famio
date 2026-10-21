import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import 'api_exception.dart';
import 'i18n.dart';

/// Persists [SyncRecord]s, hands out monotonically increasing revisions and
/// enforces per-record visibility ([SyncRecord.visibleTo]).
class RecordStore {
  RecordStore(this._db, {required this.memberIds, this.roleOf, this.accessOf});

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
  bool canAccess(SyncRecord r, String userId) {
    final role = _role(userId);
    if (role != MemberRole.adult &&
        Collections.adultReadable.contains(r.collection)) {
      return false;
    }
    return _canSee(r, userId) &&
        (role != MemberRole.guest ||
            (Collections.guestReadable.contains(r.collection) &&
                _guestMaySee(r, userId)));
  }

  /// Leaves out [Collections.adultReadable] for everyone but adults (names
  /// are constants, no input).
  static String _adultsOnlySql(MemberRole role) => role == MemberRole.adult
      ? ''
      : 'AND collection NOT IN '
            '(${Collections.adultReadable.map((c) => "'$c'").join(', ')})';

  /// Guests see a task of the whole family only if it is assigned to them;
  /// others they see when its audience names them.
  static bool _guestMaySee(SyncRecord r, String guestId) =>
      r.collection != Collections.tasks ||
      r.visibleTo != null ||
      Task.assigneesIn(r.data).contains(guestId);

  /// [_guestMaySee] in SQL, for a guest's id as `?2`.
  static const _guestTasksSql =
      " AND (collection != '${Collections.tasks}' OR visible_to IS NOT NULL"
      " OR json_extract(data, '\$.assigneeId') = ?2"
      " OR EXISTS (SELECT 1 FROM json_each(data, '\$.assigneeIds')"
      ' WHERE value = ?2))';

  /// Who receives [r]: its audience; for a task of the whole family while
  /// there are guests, everyone but the guests it is not assigned to; else
  /// null for everyone.
  List<String>? _audience(SyncRecord r) {
    if (r.visibleTo case final ids?) return ids;
    if (r.collection != Collections.tasks) return null;
    final members = memberIds();
    if (!members.any((m) => _role(m) == MemberRole.guest)) return null;
    final assigned = Task.assigneesIn(r.data);
    return [
      for (final m in members)
        if (_role(m) != MemberRole.guest || assigned.contains(m)) m,
    ];
  }

  /// Whether [role] may store [incoming] (over [existing]).
  static bool mayWrite(
    MemberRole role,
    String userId,
    SyncRecord incoming,
    SyncRecord? existing, {
    ServiceAccess access = ServiceAccess.full,
  }) {
    final collection = incoming.collection;
    // Conflicts come from the server; the apps only remove decided ones.
    if (collection == Collections.conflicts) {
      return incoming.deleted &&
          existing != null &&
          role != MemberRole.guest &&
          access != ServiceAccess.readOnly;
    }
    // "Bin unterwegs" and emergency facts: everyone writes only their own.
    if ((collection == Collections.trips ||
            collection == Collections.memberEmergency) &&
        incoming.id != userId) {
      return false;
    }
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
        // Children save for their own goals only.
        if (collection == Collections.savingsGoals) {
          bool own(SyncRecord? r) =>
              r == null || r.deleted || r.data['memberId'] == userId;
          return own(existing) && (incoming.deleted || own(incoming));
        }
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

  /// Deletion marks still kept (see [purgeDeleted]).
  int deletedCount() =>
      _db
              .select('SELECT count(*) FROM records WHERE deleted = 1')
              .first
              .columnAt(0)
          as int;

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
      _db.execute('INSERT OR REPLACE INTO rev_marks (at, rev) VALUES (?, ?)', [
        at,
        currentRev,
      ]);
      final horizon = _db.select(
        'SELECT at, rev FROM rev_marks WHERE at <= ? ORDER BY at DESC'
        ' LIMIT 1',
        [cutoff],
      ).firstOrNull;
      if (horizon == null) return;
      final rev = horizon['rev'] as int;
      // Older marks are no longer needed; the horizon stays as a floor.
      _db.execute('DELETE FROM rev_marks WHERE at < ?', [horizon['at']]);
      final purged =
          _db
                  .select(
                    'SELECT MAX(rev) FROM ('
                    ' SELECT rev FROM records WHERE deleted = 1 AND rev <= ?1'
                    ' UNION ALL SELECT rev FROM revocations WHERE rev <= ?1)',
                    [rev],
                  )
                  .first
                  .columnAt(0)
              as int?;
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
        if (!mayWrite(role, userId, incoming, existing, access: access)) {
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
          _keepConflict(
            lost: incoming,
            kept: existing,
            base: change.rev,
            userId: userId,
            now: now,
          );
          rejected.add(existing);
          continue;
        }
        if (change.collection == Collections.shoppingLists &&
            !incoming.deleted) {
          incoming = _keepAudience(incoming, existing);
        }
        if (change.collection == Collections.shoppingItems &&
            !incoming.deleted) {
          // An item goes where its list goes, whoever writes it (older apps,
          // Bring!, CalDAV); into a list they cannot see nobody writes.
          final list = _listOf(incoming);
          if (list != null && !_canSee(list, userId)) {
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
          incoming = _itemAudience(incoming);
        }
        if (change.collection == Collections.tasks && !incoming.deleted) {
          incoming = _taskAudience(incoming, existing);
          if (role == MemberRole.guest &&
              incoming.visibleTo == null &&
              !Task.assigneesIn(incoming.data).contains(userId)) {
            // Guests see family tasks only when assigned; one they write
            // for the family stays visible to them.
            incoming = incoming.copyWith(
              data: {
                ...incoming.data,
                SyncRecord.visibilityKey: [...?_audience(incoming), userId],
              },
            );
          }
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
            when !ids.contains(userId) &&
                incoming.collection != Collections.shoppingItems) {
          // Authors always keep access to what they write (an item: as long
          // as they see its list).
          incoming = incoming.copyWith(
            data: {
              ...incoming.data,
              SyncRecord.visibilityKey: [...ids, userId],
            },
          );
        }
        _put(incoming, previous: existing);
        _itemsFollowList(incoming, existing);
        stored.add((incoming, existing));
        if (existing != null) {
          _keepConflict(
            lost: existing,
            kept: incoming,
            base: change.rev,
            userId: userId,
            now: now,
          );
        }
      }
    });

    if (stored.isNotEmpty) onStored?.call(userId, stored);
    return _pull(userId, since, now, rejected, unsupported, role, reset: reset);
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
    final tasks = role == MemberRole.guest ? _guestTasksSql : '';
    final adults = _adultsOnlySql(role);
    final rows = _db.select(
      '''
      SELECT collection, id, data, deleted, updated_at, updated_by, rev
        FROM records
       WHERE rev > ?1 $only $tasks $adults
         AND (visible_to IS NULL
              OR EXISTS (SELECT 1 FROM json_each(visible_to) WHERE value = ?2))
      UNION ALL
      SELECT collection, id, '{}', 1, $revokedAt, '$serverMemberId', rev
        FROM revocations
       WHERE member_id = ?2 AND rev > ?1 $only $adults
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

  static const _guestTasksKey = 'guestTasksRestricted';

  /// Until 2.0.3 guests saw every task. Once, takes the tasks of the whole
  /// family that are not assigned to them off their devices.
  void restrictGuestTasks() {
    if (_setting(_guestTasksKey) != null) return;
    final members = memberIds();
    _transaction(() {
      if (members.any((m) => _role(m) == MemberRole.guest)) {
        for (final r in all(Collections.tasks)) {
          if (r.visibleTo == null) _put(r, previous: r, before: members);
        }
      }
      _db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?)'
        ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [_guestTasksKey, '1'],
      );
    });
  }

  /// Undecided conflicts go away after this long.
  static const keepConflicts = Duration(days: 60);

  /// Removes conflicts nobody decided about within [keepConflicts].
  int expireConflicts({DateTime? now}) {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final old = [
      for (final r in all(Collections.conflicts))
        if (r.updatedAt < at - keepConflicts.inMilliseconds) r,
    ];
    _transaction(() {
      for (final r in old) {
        _put(
          r.copyWith(
            // Tombstones keep their audience (see [sync]).
            data: {SyncRecord.visibilityKey: ?r.visibleTo},
            deleted: true,
            updatedAt: at,
            updatedBy: serverMemberId,
          ),
          previous: r,
        );
      }
    });
    return old.length;
  }

  /// Keeps the version that lost as a conflict when [userId] changed the
  /// record without having seen the server's version (their [base]
  /// revision is older) and that version came from another member. Both
  /// authors see it (if they may see the record) and decide.
  void _keepConflict({
    required SyncRecord lost,
    required SyncRecord kept,
    required int base,
    required String userId,
    required int now,
  }) {
    final server = lost.updatedBy == userId ? kept : lost;
    final other = server.updatedBy;
    if (!Collections.conflictTracked.contains(lost.collection) ||
        base >= server.rev ||
        other == null ||
        other == userId ||
        other == serverMemberId ||
        (lost.deleted && kept.deleted) ||
        _sameContent(lost, kept)) {
      return;
    }
    final audience = [
      for (final id in {lost.updatedBy, kept.updatedBy})
        if (id != null && _canSee(kept, id) && _canSee(lost, id)) id,
    ];
    if (audience.isEmpty) return;
    final conflict = SyncConflict.between(lost: lost, kept: kept);
    _put(
      SyncRecord(
        collection: Collections.conflicts,
        id: conflict.id,
        data: conflict.toData(audience: audience),
        updatedAt: now,
        updatedBy: serverMemberId,
      ),
      previous: _get(Collections.conflicts, conflict.id),
    );
  }

  /// Same data apart from visibility and fields of other apps.
  static bool _sameContent(SyncRecord a, SyncRecord b) {
    Map<String, Object?> core(SyncRecord r) => {
      for (final e in r.data.entries)
        if (e.key != SyncRecord.visibilityKey &&
            !e.key.startsWith(SyncRecord.externalPrefix))
          e.key: e.value,
    };
    return a.deleted == b.deleted && jsonEncode(core(a)) == jsonEncode(core(b));
  }

  /// Writes [r] with the next revision and updates revocations: members who
  /// could see [previous] but not [r] get a tombstone, members who regain
  /// access lose their revocation.
  void _put(
    SyncRecord r, {
    required SyncRecord? previous,
    List<String>? before,
  }) {
    final rev = currentRev + 1;
    final stored = r.visibleTo;
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
        stored == null ? null : jsonEncode(stored),
      ],
    );

    final audience = _audience(r);
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
    final had = before ?? _audience(previous) ?? memberIds();
    for (final member in had.where((m) => !audience.contains(m))) {
      _db.execute(
        'INSERT OR REPLACE INTO revocations (member_id, collection, id, rev)'
        ' VALUES (?, ?, ?, ?)',
        [member, r.collection, r.id, rev],
      );
    }
  }

  /// Apps before 2.0.15 know nothing of who sees a shopping list and leave
  /// the key out; their changes keep the stored audience.
  static SyncRecord _keepAudience(SyncRecord incoming, SyncRecord? existing) {
    if (incoming.data.containsKey(SyncRecord.visibilityKey) ||
        existing == null ||
        existing.deleted ||
        existing.visibleTo == null) {
      return incoming;
    }
    return incoming.copyWith(
      data: {...incoming.data, SyncRecord.visibilityKey: existing.visibleTo},
    );
  }

  /// The live shopping list [item] belongs to, if any.
  SyncRecord? _listOf(SyncRecord item) {
    final listId = item.data['listId'];
    final list = listId is String
        ? _get(Collections.shoppingLists, listId)
        : null;
    return list == null || list.deleted ? null : list;
  }

  /// A shopping item is seen by exactly those who see its list (as it is
  /// stored); without a list it keeps what it says.
  SyncRecord _itemAudience(SyncRecord item) {
    if (item.collection != Collections.shoppingItems || item.deleted) {
      return item;
    }
    final list = _listOf(item);
    if (list == null) return item;
    final data = {...item.data}..remove(SyncRecord.visibilityKey);
    if (list.visibleTo case final ids?) data[SyncRecord.visibilityKey] = ids;
    return item.copyWith(data: data);
  }

  /// After [list] was stored: its items follow a changed audience, so those
  /// who no longer see the list lose its items too (revocations).
  void _itemsFollowList(SyncRecord list, SyncRecord? before) {
    if (list.collection != Collections.shoppingLists || list.deleted) return;
    if (before != null &&
        !before.deleted &&
        jsonEncode(before.visibleTo) == jsonEncode(list.visibleTo)) {
      return;
    }
    for (final row in _db.select(
      "SELECT * FROM records WHERE collection = ? AND deleted = 0"
      " AND json_extract(data, '\$.listId') = ?",
      [Collections.shoppingItems, list.id],
    )) {
      final item = _record(row);
      final next = _itemAudience(item);
      if (jsonEncode(next.visibleTo) != jsonEncode(item.visibleTo)) {
        _put(next, previous: item);
      }
    }
  }

  /// Apps before 2.0.3 know nothing of who sees a task and leave the key
  /// out; their changes keep the stored audience. Whoever takes care of a
  /// task always sees it.
  static SyncRecord _taskAudience(SyncRecord incoming, SyncRecord? existing) {
    final data = {...incoming.data};
    if (!data.containsKey(SyncRecord.visibilityKey) &&
        existing != null &&
        !existing.deleted &&
        existing.visibleTo != null) {
      data[SyncRecord.visibilityKey] = existing.visibleTo;
    }
    if (data[SyncRecord.visibilityKey] case final List<Object?> ids) {
      data[SyncRecord.visibilityKey] = {
        ...ids.whereType<String>(),
        ...Task.assigneesIn(data),
      }.toList();
    }
    return incoming.copyWith(data: data);
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
      throw ApiException.badRequest(
        'invalid_id',
        t('Ungültige ID: {id}', {'id': r.id}),
      );
    }
    if (utf8.encode(jsonEncode(r.data)).length > _maxDataBytes) {
      throw ApiException(413, 'too_large', t('Eintrag ist zu groß'));
    }
  }

  /// Live (non-deleted) records of [collection], optionally only those
  /// [visibleToMember].
  List<SyncRecord> all(String collection, {String? visibleToMember}) {
    if (visibleToMember != null &&
        ((_role(visibleToMember) == MemberRole.guest &&
                !Collections.guestReadable.contains(collection)) ||
            (_role(visibleToMember) != MemberRole.adult &&
                Collections.adultReadable.contains(collection)))) {
      return const [];
    }
    return [
      for (final row in _db.select(
        'SELECT * FROM records WHERE collection = ? AND deleted = 0',
        [collection],
      ))
        if (visibleToMember == null || canAccess(_record(row), visibleToMember))
          _record(row),
    ];
  }

  /// Whether a live record visible to [memberId] mentions [text] (e.g. a
  /// file id) in its data. Used to authorise file downloads.
  bool referencedFor(String text, String memberId) {
    final role = _role(memberId);
    final guest = role == MemberRole.guest;
    final only =
        '${guest ? 'AND collection IN (${Collections.guestReadable.map((c) => "'$c'").join(', ')})'
                  '$_guestTasksSql' : ''} ${_adultsOnlySql(role)}';
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
        final record = _itemAudience(
          r.copyWith(
            data: data,
            // Ahead of any client edit, so server data always wins.
            updatedAt: max(now, (existing?.updatedAt ?? 0) + 1),
            updatedBy: serverMemberId,
          ),
        );
        _put(record, previous: existing);
        _itemsFollowList(record, existing);
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

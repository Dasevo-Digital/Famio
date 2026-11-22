import 'dart:convert';
import 'dart:math';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:timezone/timezone.dart' as tz;

import 'api_exception.dart';
import 'i18n.dart';

part 'record_store_trash.dart';
part 'record_store_assignments.dart';
part 'record_store_files.dart';

/// Persists [SyncRecord]s, hands out monotonically increasing revisions and
/// enforces per-record visibility ([SyncRecord.visibleTo]).
class RecordStore {
  RecordStore(
    this._db, {
    required this.memberIds,
    this.roleOf,
    this.accessOf,
    this.assignmentLocation,
    DateTime Function()? today,
  }) : _today = today ?? _localToday;

  final Database _db;
  int _fileIndexRev = -1;
  int _fileIndexEpoch = 0;
  final _filesByRecord = <(String, String), Set<String>>{};
  final _recordsByFile = <String, Set<(String, String)>>{};
  final _damagedFileRecords = <(String, String), String>{};
  final _trashByFile = <String, Set<String>>{};
  final _damagedFileTrash = <String, String>{};
  final tz.Location Function()? assignmentLocation;
  (tz.Location, Map<String, Object?>)? _zoneRules;

  /// The family zone's rules for apps that do not have them yet.
  Map<String, Object?>? _zoneRulesFor(tz.Location? zone, String? clientKey) {
    if (zone == null) return null;
    if (_zoneRules?.$1 != zone) _zoneRules = (zone, calendarZoneRules(zone));
    final rules = _zoneRules!.$2;
    return rules['key'] == clientKey ? null : rules;
  }

  /// A new process may have opened a restored database, even if revisions
  /// have already caught up. Clients reconcile once per server instance.
  final String _generation = newId();

  /// Installed by FileStore: new attachments must already be accessible.
  bool Function(String fileId, String memberId)? mayReferenceFile;
  FileRef Function(FileRef)? canonicalFile;
  int Function()? maxUploadBytes;

  /// The family's day (its time zone), for absences.
  final DateTime Function() _today;

  static DateTime _localToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

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
    if (r.collection == Collections.assignmentResponses && !r.deleted) {
      final parent = _assignmentTarget(r);
      if (parent == null || parent.deleted || !canAccess(parent, userId)) {
        return false;
      }
    }
    // Comments and packing lists reach as far as their appointment does.
    // Its tombstone keeps the audience.
    if (!r.deleted) {
      final event = _attachedEvent(r);
      if (event != null && !_canSee(event, userId)) return false;
    }
    final role = _role(userId);
    if (role == MemberRole.service && _serviceHidden.contains(r.collection)) {
      return false;
    }
    if (role != MemberRole.adult &&
        (Collections.adultReadable.contains(r.collection) ||
            !_mayReceive(r, userId, role))) {
      return false;
    }
    return _canSee(r, userId) &&
        (role != MemberRole.guest ||
            (Collections.guestReadable.contains(r.collection) &&
                _guestMaySee(r, userId)));
  }

  /// What a service account (Home Assistant, a wall display) has no use for
  /// and so never gets: scanned letters, insurance cards and contracts are
  /// often health data before anyone files them (#507). Their files follow
  /// ([FileStore] asks [canAccess] of what refers to them).
  static const _serviceHidden = {
    Collections.documents,
    Collections.externalDocuments,
    Collections.inbox,
  };

  /// What everyone but adults may not receive although nothing restricts
  /// it: health data unless they are named (service accounts never), and
  /// confidential appointments they have no part in. A service account
  /// keeps those as busy times, without what they are about ([_shown]).
  bool _mayReceive(SyncRecord r, String userId, MemberRole role) {
    if (_hiddenFromChildren(r) && role == MemberRole.child) {
      return (r.data['createdBy'] ?? r.updatedBy) == userId;
    }
    if (Collections.isHealth(r.collection, r.data)) {
      return role != MemberRole.service &&
          (r.visibleTo?.contains(userId) ?? false);
    }
    if (role == MemberRole.service && _isConfidentialConflict(r)) return false;
    if (_isOrphanComment(r)) return false;
    final event = _confidentialEvent(r);
    if (event == null) return true;
    if (role == MemberRole.service) return r.collection == Collections.events;
    return event.updatedBy == userId ||
        [
          ...?(event.data['memberIds'] as List?),
          event.data['bringerId'],
          event.data['pickerId'],
        ].contains(userId);
  }

  /// An entry of the family inbox nobody shared with the children: scanned
  /// letters are often about health or money before anyone files them.
  /// Children receive only what they filed themselves (GRU-084).
  static bool _hiddenFromChildren(SyncRecord r) =>
      r.collection == Collections.inbox &&
      !r.deleted &&
      r.data[InboxItem.forChildrenKey] != true;

  /// The confidential appointment [r] is, comments on or is packed for.
  SyncRecord? _confidentialEvent(SyncRecord r) {
    final event = switch (r.collection) {
      Collections.events => r,
      Collections.eventComments => _get(
        Collections.events,
        '${r.data['eventId']}',
      ),
      Collections.shoppingLists => _packedFor(r),
      Collections.shoppingItems => _packedFor(
        _get(Collections.shoppingLists, '${r.data['listId']}'),
      ),
      _ => null,
    };
    return event?.data['confidential'] == true ? event : null;
  }

  /// The appointment a packing list was made for.
  SyncRecord? _packedFor(SyncRecord? list) {
    final id = list?.data['eventId'];
    return id == null ? null : _get(Collections.events, '$id');
  }

  /// The appointment [r] comments on or is packed for.
  SyncRecord? _attachedEvent(SyncRecord r) => switch (r.collection) {
    Collections.eventComments => _commentedEvent(r),
    Collections.shoppingLists => _packedFor(r),
    Collections.shoppingItems => _packedFor(
      _get(Collections.shoppingLists, '${r.data['listId']}'),
    ),
    _ => null,
  };

  /// The appointment, own or from a connected calendar, [comment] is about.
  SyncRecord? _commentedEvent(SyncRecord comment) {
    final id = '${comment.data['eventId']}';
    return _get(Collections.events, id) ?? _get(Collections.externalEvents, id);
  }

  /// A saved losing version of an appointment that is, or was then,
  /// confidential.
  bool _isConfidentialConflict(SyncRecord r) {
    if (r.collection != Collections.conflicts ||
        r.data['collection'] != Collections.events) {
      return false;
    }
    final lost = r.data['lost'];
    return (lost is Map && lost['confidential'] == true) ||
        _get(
              Collections.events,
              '${r.data['recordId']}',
            )?.data['confidential'] ==
            true;
  }

  /// A comment whose appointment is gone: a deleted one no longer says
  /// whether it was confidential, so everyone but adults loses the comment.
  bool _isOrphanComment(SyncRecord r) {
    if (r.collection != Collections.eventComments || r.deleted) return false;
    final event = _commentedEvent(r);
    return event == null || event.deleted;
  }

  /// [r] as a member with [role] gets it: for a service account a
  /// confidential appointment is only a busy time.
  static SyncRecord _shown(SyncRecord r, MemberRole role) =>
      role == MemberRole.service &&
          r.collection == Collections.events &&
          r.data['confidential'] == true
      ? r.copyWith(
          data: {...r.data, 'title': '', 'location': '', 'notes': ''}
            ..remove('files'),
        )
      : r;

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
    final health = Collections.isHealth(r.collection, r.data);
    final within = r.deleted ? null : _attachedEvent(r)?.visibleTo;
    final confidential = _confidentialEvent(r) != null;
    final notForChildren = _hiddenFromChildren(r);
    if (r.visibleTo case final ids?) {
      return [
        for (final id in ids)
          if ((!health || _role(id) != MemberRole.service) &&
              (within == null || within.contains(id)) &&
              (!(confidential || notForChildren) || canAccess(r, id)))
            id,
      ];
    }
    if (health || confidential || notForChildren || within != null) {
      return [
        for (final m in memberIds())
          if (canAccess(r, m)) m,
      ];
    }
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
    bool health(SyncRecord? r) =>
        r != null && Collections.isHealth(r.collection, r.data);
    // Service accounts neither receive health data nor see what confidential
    // appointments are about, so they cannot sensibly change them.
    if (role == MemberRole.service &&
        (_serviceHidden.contains(collection) ||
            health(incoming) ||
            health(existing) ||
            incoming.data['confidential'] == true ||
            existing?.data['confidential'] == true)) {
      return false;
    }
    if (collection == Collections.assignmentResponses) {
      return access != ServiceAccess.readOnly &&
          (incoming.deleted
              ? existing?.data['memberId'] == userId
              : incoming.data['memberId'] == userId);
    }
    // Conflicts come from the server; the apps only remove decided ones.
    if (collection == Collections.conflicts) {
      return incoming.deleted &&
          existing != null &&
          role != MemberRole.guest &&
          access != ServiceAccess.readOnly;
    }
    // Messages and comments carry their author's name: nobody writes in
    // somebody else's, and only adults take down what others wrote.
    if (collection == Collections.chatMessages ||
        collection == Collections.eventComments) {
      final live = existing != null && !existing.deleted;
      final author = live
          ? existing.data['authorId'] ?? existing.updatedBy
          : userId;
      if (!incoming.deleted &&
          (incoming.data['authorId'] ?? author) != author) {
        return false;
      }
      if (author != userId && (role != MemberRole.adult || !incoming.deleted)) {
        return false;
      }
    }
    if (collection == Collections.pollVotes) {
      bool own(SyncRecord? r) =>
          r == null || r.deleted || r.data['memberId'] == userId;
      if (!own(existing) || !(incoming.deleted || own(incoming))) return false;
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
        if (collection == Collections.tasks) {
          // What they may change of it is left to [_guestTaskChange]; their
          // own tasks they also delete (#365).
          return existing == null ||
              existing.deleted ||
              !incoming.deleted ||
              Task.createdBy(existing.data, userId);
        }
        return Collections.guestWritable.contains(collection);
      case MemberRole.child:
        if (Collections.adultOnly.contains(collection)) return false;
        // Who sees health data is for adults to decide: a child who may log
        // something keeps its audience as it is.
        if (health(incoming) || health(existing)) {
          if (incoming.deleted) return true;
          return existing == null || existing.deleted
              ? incoming.visibleTo?.contains(userId) ?? false
              : jsonEncode(incoming.visibleTo) ==
                    jsonEncode(existing.visibleTo);
        }
        // Children save for their own goals only, and tick off their own
        // routines, not a sibling's.
        if (collection == Collections.savingsGoals ||
            collection == Collections.routineRuns) {
          bool own(SyncRecord? r) =>
              r == null || r.deleted || r.data['memberId'] == userId;
          return own(existing) && (incoming.deleted || own(incoming));
        }
        if (collection != Collections.pointEntries) return true;
        // Children ask for points (done chores, wished rewards); adults
        // decide. Their own open requests they may change or withdraw, and
        // a declined one ask for again or take back (#581).
        bool own(SyncRecord r, Set<String> statuses) =>
            r.data['memberId'] == userId && statuses.contains(r.data['status']);
        if (existing != null &&
            !existing.deleted &&
            !own(existing, const {'pending', 'rejected'})) {
          return false;
        }
        return incoming.deleted || own(incoming, const {'pending'});
    }
  }

  /// Guests tick off what they were given and add their own; what a task
  /// is, who has it and who sees it is for the family. So of a guest's write
  /// only the ticks count, on top of the task as it is now: the device may
  /// not know yet that it has changed, and the tick must not get lost.
  /// Only what the writer ticked itself counts, against the version its
  /// change is based on ([SyncRecord.rev]): what the family ticked or took
  /// back meanwhile stays (#558). A repeating task moves on only when it is
  /// ticked off, not to any due date (#477).
  /// Tasks the guest created ([Task.createdBy]) are theirs to change (#365).
  SyncRecord _guestTaskChange(SyncRecord incoming, SyncRecord existing) {
    final theirs = incoming.data;
    final data = {...existing.data};
    // Written on an older version: of what changed on the server since,
    // nothing is theirs. Without a version (Home Assistant) or on the
    // stored one, every tick that differs is.
    final stale = incoming.rev > 0 && incoming.rev < existing.rev;
    final marks = stale ? _tickMarks(existing.id) : const <String, int>{};
    final ticks = {
      for (final field in _tickChanges(existing.data, theirs))
        if ((marks[field] ?? 0) <= incoming.rev) field,
    };
    void take(List<String> keys) {
      for (final key in keys) {
        if (theirs.containsKey(key)) {
          data[key] = theirs[key];
        } else {
          data.remove(key);
        }
      }
    }

    final done = ticks.contains(_doneTick);
    if (done) take(const ['done', 'completedAt']);
    // Ticking off a repeating task moves it on.
    if (existing.data['repeat'] != null &&
        ticks.contains(_dueTick) &&
        (done || _movesOn(existing.data, theirs))) {
      take(const ['due', 'remindAt']);
    }
    final steps = _steps(theirs);
    if (existing.data['checklist'] case final List<Object?> list) {
      data['checklist'] = [
        for (final step in list)
          if (step is Map && ticks.contains('$_stepTick${step['id']}'))
            {...step, 'done': steps[step['id']]}
          else
            step,
      ];
    }
    return incoming.copyWith(data: data);
  }

  static const _doneTick = 'done';
  static const _dueTick = 'due';
  static const _stepTick = 'step:';

  /// The ticks of a task that differ between [a] and [b]: whether it is
  /// done (and when), its due date (and reminder), each step by its id.
  static Set<String> _tickChanges(
    Map<String, Object?> a,
    Map<String, Object?> b,
  ) {
    // Missing, null and "" are the same (clients write empty fields).
    bool differs(String key) =>
        jsonEncode(a[key] == '' ? null : a[key]) !=
        jsonEncode(b[key] == '' ? null : b[key]);
    final before = _steps(a);
    return {
      if ((a['done'] == true) != (b['done'] == true) || differs('completedAt'))
        _doneTick,
      if (differs('due') || differs('remindAt')) _dueTick,
      for (final MapEntry(:key, :value) in _steps(b).entries)
        if (before[key] != value) '$_stepTick$key',
    };
  }

  /// Steps of a task's checklist: done or not, by id.
  static Map<String, bool> _steps(Map<String, Object?> data) => {
    for (final step in data['checklist'] as List? ?? const [])
      if (step is Map && step['id'] is String)
        step['id'] as String: step['done'] == true,
  };

  /// When the ticks of [taskId] last changed (see [_tickChanges]).
  Map<String, int> _tickMarks(String taskId) => {
    for (final row in _db.select(
      'SELECT field, rev FROM task_marks WHERE task_id = ?',
      [taskId],
    ))
      row['field'] as String: row['rev'] as int,
  };

  /// Notes at revision [rev] which ticks of task [r] changed against
  /// [previous], for writes based on an older version ([_guestTaskChange]).
  void _markTicks(SyncRecord r, SyncRecord? previous, int rev) {
    if (r.deleted || previous == null || previous.deleted) return;
    for (final field in _tickChanges(previous.data, r.data)) {
      _db.execute(
        'INSERT INTO task_marks (task_id, field, rev) VALUES (?, ?, ?)'
        ' ON CONFLICT (task_id, field) DO UPDATE SET rev = excluded.rev',
        [r.id, field, rev],
      );
    }
  }

  /// Whether the due date in [after] is where ticking off the repeating
  /// task [before] moves it ([Task.completed]): whole periods on, to the
  /// first not before the day it was ticked off (today, or a little
  /// earlier on a device that was offline).
  bool _movesOn(Map<String, Object?> before, Map<String, Object?> after) {
    final repeat = TaskRepeat.parse(before['repeat']);
    final to = _dayOf(after['due']);
    if (repeat == null || to == null) return false;
    final every = (before['repeatEvery'] as num?)?.toInt().clamp(1, 99) ?? 1;
    final today = _today();
    // A device clock may be a little ahead.
    final latest = DateTime(today.year, today.month, today.day + 1);
    final from = _dayOf(before['due']);
    if (from == null) {
      // Without a due date it moves one period on from the day it was
      // ticked off.
      for (var back = 0; back <= 31; back++) {
        final day = DateTime(latest.year, latest.month, latest.day - back);
        if (_sameDay(repeat.after(day, every), to)) return true;
      }
      return false;
    }
    DateTime? previous;
    var next = repeat.after(from, every);
    for (var i = 0; i < 10000 && next.isBefore(to); i++) {
      previous = next;
      next = repeat.after(next, every);
    }
    // It goes on past dates only while they lie before that day.
    return _sameDay(next, to) &&
        (previous == null || previous.isBefore(latest));
  }

  static DateTime? _dayOf(Object? value) {
    final at = value is String ? DateTime.tryParse(value) : null;
    return at == null ? null : DateTime(at.year, at.month, at.day);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Whether [incoming], an entry of [Collections.pointEntries], is covered
  /// by its member's points: an open wish ([PointEntry.reserves]) asks for
  /// no more than the confirmed points leave after the other open wishes
  /// (#377). What it asked for before ([existing], still open) stays
  /// covered, also when the points have gone down since. Adults deciding
  /// on wishes and booking points are not limited here.
  bool _wishCovered(SyncRecord incoming, SyncRecord? existing) {
    if (incoming.deleted) return true;
    final wish = PointEntry.fromRecord(incoming);
    if (!wish.reserves) return true;
    final before = existing == null || existing.deleted
        ? null
        : PointEntry.fromRecord(existing);
    final had =
        before != null && before.reserves && before.memberId == wish.memberId
        ? -before.points
        : 0;
    final cost = -wish.points;
    if (cost <= had) return true;
    final entries = [
      for (final row in _db.select(
        'SELECT * FROM records WHERE collection = ? AND deleted = 0'
        " AND json_extract(data, '\$.memberId') = ?",
        [Collections.pointEntries, wish.memberId],
      ))
        PointEntry.fromRecord(_record(row)),
    ];
    return PointEntry.available(entries, wish.memberId, except: wish.id) >=
        cost;
  }

  /// Ids of all family members; needed when a record visible to everyone
  /// becomes restricted, to know who loses access.
  final List<String> Function() memberIds;

  static const pageSize = 500;
  static const _maxDataBytes = 256 * 1024;

  /// Clients may be a little ahead of the server clock, but not much; a
  /// far-future timestamp would otherwise win every conflict forever.
  static const _maxClockSkew = Duration(minutes: 2);

  /// How far a device that has seen "delete all data" may be behind the
  /// deletion with what it writes after it (see [sync]).
  static const _resetGrace = Duration(seconds: 10);

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
  static const _resetRevKey = 'dataResetRev';
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
      _db.execute(
        'DELETE FROM task_marks WHERE task_id NOT IN'
        ' (SELECT id FROM records WHERE collection = ?)',
        [Collections.tasks],
      );
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

  /// The revision of the last deletion mark of [wipe]: a device that has
  /// synced up to it knows that all data was deleted (#491).
  late int resetRev =
      int.tryParse(
        _db
                    .select('SELECT value FROM settings WHERE key = ?', [
                      _resetRevKey,
                    ])
                    .firstOrNull
                    ?.columnAt(0)
                as String? ??
            '',
      ) ??
      0;

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
      for (final (key, value) in [(_resetKey, now), (_resetRevKey, rev)]) {
        _db.execute(
          'INSERT INTO settings (key, value) VALUES (?, ?)'
          ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, '$value'],
        );
      }
      resetRev = rev;
      count = rows.length;
      _db.execute('DELETE FROM trash');
      _db.execute('DELETE FROM assignment_reminders');
      _db.execute('DELETE FROM task_marks');
    });
    resetAt = now;
    return count;
  }

  /// Whether [record] is a deletion mark of [wipe].
  bool _wipeMark(SyncRecord record) =>
      record.deleted &&
      record.updatedBy == serverMemberId &&
      record.rev <= resetRev &&
      record.updatedAt == resetAt + _maxClockSkew.inMilliseconds;

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
    final blocked = <SyncWriteIssue>[];
    // Edits this member may not make at all (#539), or only partly (#550):
    // the app says so once.
    final refused = <SyncWriteIssue>[];
    void refuse(SyncRecord change) => refused.add(
      SyncWriteIssue(
        collection: change.collection,
        id: change.id,
        updatedAt: change.updatedAt,
        code: 'not_allowed',
      ),
    );
    // A client ahead of the server means the server database was reset:
    // send it everything again. One behind cleaned-up deletion marks gets
    // everything too and drops what it does not receive (newer apps only;
    // older ones would ask again and again).
    final scope = [
      _generation,
      role.name,
      access.name,
      if (role != MemberRole.adult) _accessRules,
    ].join(':');
    final reset =
        request.resettable &&
        request.since > 0 &&
        ((request.scope != null && request.scope != scope) ||
            (!request.full &&
                (request.since < purgedRev || request.since > currentRev)));
    final since = request.since > currentRev || reset ? 0 : request.since;
    // A device that has received the deletion marks of "delete all data"
    // saves its settings again over their marks, which lie ahead of the
    // deletion (#491). Its clock is corrected by the server's, so what it
    // wrote a moment before the deletion by that clock also counts as
    // after. What it holds from well before (more than a batch of offline
    // changes) still goes. A device ahead of the server or from another
    // instance has not seen this deletion.
    final sawReset = resetRev > 0 && !reset && since >= resetRev;
    final writtenAfter = sawReset
        ? resetAt - _resetGrace.inMilliseconds
        : resetAt;
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
        if (change.collection == Collections.assignmentResponses &&
            !_validAssignmentReply(incoming, userId)) {
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
        if (!incoming.deleted &&
            (incoming.collection == Collections.tasks ||
                incoming.collection == Collections.events) &&
            !incoming.data.containsKey('assignmentConfirmation') &&
            existing?.data['assignmentConfirmation'] != null) {
          incoming = incoming.copyWith(
            data: {
              ...incoming.data,
              'assignmentConfirmation':
                  existing!.data['assignmentConfirmation'],
            },
          );
        }
        if (existing != null && !canAccess(existing, userId)) {
          // Echo only the supplied key, never the inaccessible contents.
          // Role changes can revoke access without a per-record revocation.
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
          refuse(change);
          continue;
        }
        if (change.collection == Collections.pointEntries &&
            !_wishCovered(incoming, existing)) {
          // A wish for more than is left after the open ones (#377).
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
          refuse(change);
          continue;
        }
        if (_onlyMovedAlong(incoming, existing)) {
          // An app moved a household entry to new settings itself (older
          // apps did): the server does that and keeps who wrote it (#552).
          // Written in this member's name, it would leave the writer.
          rejected.add(existing!);
          continue;
        }
        if (role == MemberRole.child) {
          final checked = _childHealthWrite(incoming, existing, userId);
          if (checked == null) {
            refuse(change);
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
          incoming = checked;
        }
        if ((existing == null || existing.deleted) &&
            incoming.updatedAt < writtenAfter) {
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
          // may see them (if shared) but not change or remove them. One for
          // the whole family (no owner, such as the school holidays) is
          // the adults' (#538).
          final owner = existing?.data['ownerId'];
          if (existing != null &&
              !existing.deleted &&
              (owner == null ? role != MemberRole.adult : owner != userId)) {
            rejected.add(existing);
            refuse(change);
            continue;
          }
          if (!incoming.deleted &&
              (incoming.data['ownerId'] != null || role != MemberRole.adult) &&
              incoming.data['ownerId'] != userId) {
            // A child's new one is its own, not one it could no longer
            // change once it is the family's.
            incoming = incoming.copyWith(
              data: {...incoming.data, 'ownerId': userId},
            );
          }
        }
        var merged = false;
        // Kept partly: this member may change only some of what it sent
        // (a guest's task, a child's audience); the app says so (#550).
        var partlyKept = false;
        // What comes back over a deletion ("Rückgängig", the same id written
        // again) is judged against the last live version from the bin, not
        // against the empty tombstone: it is no new record (#416).
        final prior = existing != null && existing.deleted
            ? _lastLive(change.collection, change.id) ?? existing
            : existing;
        final everyday =
            role == MemberRole.service && access == ServiceAccess.everyday;
        if ((role == MemberRole.guest || everyday) &&
            change.collection == Collections.tasks &&
            !incoming.deleted &&
            prior != null &&
            !prior.deleted &&
            (everyday || !Task.createdBy(prior.data, userId))) {
          // Someone else's task, also one written again over its deletion:
          // only the guest's ticks count. Their own they change (#365).
          // Who created it is the server's to keep, not part of the ticks.
          final sent = _withCreator(incoming, prior, userId);
          incoming = _guestTaskChange(incoming, prior);
          merged = identical(prior, existing);
          // A wall display only ticks (#556): Famio's apps (they say they
          // are `resettable`) write whole tasks, and what else they send is
          // no choice to tell about. Home Assistant and the like are told
          // what was left out (#550). Written on an older version, what
          // differs is mostly the family's change meanwhile.
          final stale = change.rev > 0 && change.rev < prior.rev;
          partlyKept =
              !(everyday && request.resettable) &&
              !stale &&
              !_sameData(sent, incoming);
          if (merged && _sameData(incoming, prior)) {
            // Nothing of theirs is left to store: the device takes the task
            // as it is.
            rejected.add(existing!);
            if (partlyKept) {
              refused.add(
                SyncWriteIssue(
                  collection: change.collection,
                  id: change.id,
                  updatedAt: change.updatedAt,
                  code: 'partly_kept',
                ),
              );
            }
            continue;
          }
          if (merged && !incoming.winsOver(prior)) {
            // Ticked before someone changed the task meanwhile: the ticks
            // are put on the task as it is now, so nothing of either is
            // lost, and they come after it (#558).
            incoming = incoming.copyWith(updatedAt: prior.updatedAt + 1);
          }
        }
        incoming = _keepEventFiles(incoming, existing);
        // Even a losing edit can be retained as a readable conflict. Check
        // new attachments before either version can reach persistent data.
        final previousFiles =
            existing != null && !existing.deleted && recordDataIsValid(existing)
            ? recordFileIds(existing).toSet()
            : const <String>{};
        if (!incoming.deleted &&
            recordFileIds(incoming).any(
              (id) =>
                  !previousFiles.contains(id) &&
                  !(mayReferenceFile?.call(id, userId) ?? false),
            )) {
          if (!request.deferInvalidFiles) {
            throw ApiException.badRequest(
              'invalid_file_reference',
              t('Kein Zugriff auf die angehängte Datei.'),
            );
          }
          blocked.add(
            SyncWriteIssue(
              collection: change.collection,
              id: change.id,
              updatedAt: change.updatedAt,
              code: 'invalid_file_reference',
            ),
          );
          continue;
        }
        final canonical = _canonicalFiles(incoming);
        if (!identical(canonical, incoming)) {
          _validate(canonical);
          incoming = canonical;
        }
        if (existing != null &&
            !merged &&
            !incoming.winsOver(existing) &&
            !(sawReset && _wipeMark(existing))) {
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
        if ((change.collection == Collections.shoppingLists ||
                change.collection == Collections.events) &&
            !incoming.deleted) {
          incoming = _keepAudience(incoming, existing);
        }
        if ((change.collection == Collections.events ||
                change.collection == Collections.tasks) &&
            !incoming.deleted) {
          incoming = _withCreator(incoming, prior, userId);
        }
        if (role == MemberRole.child && !incoming.deleted) {
          final sent = incoming;
          incoming = _childAudience(incoming, prior, userId);
          partlyKept = partlyKept || !_sameData(sent, incoming);
        }
        if (change.collection == Collections.events && !incoming.deleted) {
          incoming = _withConfidentialBy(incoming, prior, userId);
        }
        if (change.collection == Collections.shoppingItems &&
            !incoming.deleted) {
          // An item goes where its list goes, whoever writes it (older apps,
          // Bring!, CalDAV); into a list they cannot see nobody writes.
          final list = _listOf(incoming);
          if (list != null && !_canSee(list, userId)) {
            refuse(change);
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
          incoming = _withSubstitutes(
            _taskAudience(incoming, existing),
            existing,
          );
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
        if (_budgetCollections.contains(change.collection) &&
            !incoming.deleted) {
          // Who sees the household book is set once, in its settings; an
          // entry goes there whoever writes it (an adult outside it whose
          // app has no settings, an older app). Its writer is added below.
          incoming = incoming.copyWith(
            data: {
              ...incoming.data,
              SyncRecord.visibilityKey: _budgetAudience(
                _get(Collections.budgetSettings, BudgetSettings.recordId),
              ),
            },
          );
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
        if (change.collection == Collections.wishes && !incoming.deleted) {
          incoming = _ideaAudience(incoming, existing);
        }
        SyncRecord? localDeletion;
        if (incoming.deleted &&
            (existing == null ||
                (!existing.deleted && change.rev == existing.rev)) &&
            _trashCollections.contains(incoming.collection) &&
            change.data['deletionSnapshot'] is Map) {
          var snapshot = incoming.copyWith(
            deleted: false,
            data: (change.data['deletionSnapshot'] as Map)
                .cast<String, Object?>(),
          );
          snapshot = _keepEventFiles(snapshot, existing);
          _validate(snapshot);
          // What comes back from the bin follows the same rules as a write:
          // a child cannot hide a family record in its own bin.
          if (change.collection == Collections.shoppingLists ||
              change.collection == Collections.events) {
            snapshot = _keepAudience(snapshot, existing);
          }
          if (change.collection == Collections.events ||
              change.collection == Collections.tasks) {
            // Who entered it comes back as stored, not as the app says.
            snapshot = _withCreator(snapshot, existing, userId);
          }
          if (role == MemberRole.child) {
            snapshot = _childAudience(snapshot, existing, userId);
          }
          if (change.collection == Collections.events) {
            snapshot = _withConfidentialBy(snapshot, existing, userId);
          }
          if (recordDataIsValid(snapshot) &&
              canAccess(snapshot, userId) &&
              mayWrite(role, userId, snapshot, existing, access: access) &&
              recordFileIds(
                snapshot,
              ).every((id) => mayReferenceFile?.call(id, userId) ?? false)) {
            localDeletion = snapshot;
          }
        }
        if (incoming.collection == Collections.assignmentResponses &&
            !incoming.deleted) {
          incoming = incoming.copyWith(
            data: {
              ...incoming.data,
              SyncRecord.visibilityKey: _assignmentAudience(
                _assignmentTarget(incoming)!,
              ),
            },
          );
        }
        _put(incoming, previous: existing, deletionSnapshot: localDeletion);
        _itemsFollowList(incoming, existing);
        stored.add((incoming, existing));
        if (partlyKept) {
          refused.add(
            SyncWriteIssue(
              collection: change.collection,
              id: change.id,
              updatedAt: change.updatedAt,
              code: 'partly_kept',
            ),
          );
        }
        // A guest's ticks on top of the stored task: nothing was lost.
        if (existing != null && !merged) {
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

    if (stored.any((s) => s.$1.collection == Collections.absences)) {
      refreshSubstitutes();
    }
    if (stored.isNotEmpty) onStored?.call(userId, stored);
    return _pull(
      userId,
      since,
      now,
      rejected,
      unsupported,
      role,
      reset: reset,
      scope: scope,
      blocked: blocked,
      refused: refused,
      zoneKey: request.timeZoneKey,
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
    required String scope,
    List<SyncWriteIssue> blocked = const [],
    List<SyncWriteIssue> refused = const [],
    String? zoneKey,
  }) {
    // Guests only get their collections (names are constants, no input).
    final only = role == MemberRole.guest
        ? 'AND collection IN (${Collections.guestReadable.map((c) => "'$c'").join(', ')})'
        : '';
    final tasks = role == MemberRole.guest ? _guestTasksSql : '';
    final adults = _adultsOnlySql(role);
    // A revocation has the rev of the record it is about. It goes first:
    // a page ending between the two would continue after that rev and lose
    // it, while the record itself, revoked for this member, is not sent.
    final rows = _db.select(
      '''
      SELECT collection, id, data, deleted, updated_at, updated_by, rev,
             1 AS kind
        FROM records
       WHERE rev > ?1 $only $tasks $adults
         AND (visible_to IS NULL
              OR EXISTS (SELECT 1 FROM json_each(visible_to) WHERE value = ?2))
      UNION ALL
      SELECT collection, id, '{}', 1, $revokedAt, '$serverMemberId', rev,
             0 AS kind
        FROM revocations
       WHERE member_id = ?2 AND rev > ?1 $only $adults
      ORDER BY rev, kind
      LIMIT ?3
      ''',
      [since, userId, pageSize + 1],
    );
    var size = pageSize;
    // Never between a revocation and the record of the same rev, which a
    // member sees again after a role change: the next page would start
    // after that rev and miss the record (#399).
    if (rows.length > size &&
        size > 1 &&
        rows[size]['rev'] == rows[size - 1]['rev']) {
      size--;
    }
    final hasMore = rows.length > size;
    final page = [for (final r in rows.take(size)) _record(r)];
    final changes = [
      for (final r in page)
        if (r.deleted ||
            (role == MemberRole.adult &&
                !_followsParent.contains(r.collection)) ||
            canAccess(r, userId))
          _shown(r, role),
    ];
    final zone = assignmentLocation?.call();
    return SyncResponse(
      rev: hasMore ? page.last.rev : currentRev,
      serverTime: now,
      changes: changes,
      rejected: [for (final r in rejected) _shown(r, role)],
      unsupported: unsupported,
      hasMore: hasMore,
      reset: reset,
      scope: scope,
      blocked: blocked,
      refused: refused,
      timeZone: zone?.name,
      timeZoneRules: _zoneRulesFor(zone, zoneKey),
      maxUploadBytes: maxUploadBytes?.call(),
    );
  }

  /// Decided by what they belong to, for adults too.
  static const _followsParent = {
    Collections.assignmentResponses,
    Collections.eventComments,
    Collections.shoppingLists,
    Collections.shoppingItems,
  };

  /// Raised when members other than adults receive less than before: their
  /// next sync is a full one, which takes the rest off their devices.
  static const _accessRules = 7;

  static const _guestTasksKey = 'guestTasksRestricted';

  /// Until 2.0.3 guests saw every task. Once, takes the tasks of the whole
  /// family that are not assigned to them off their devices.
  static const _budgetAudienceKey = 'budgetAudience1';

  /// Once after upgrading: entries an older server kept open although the
  /// household book was restricted (an adult outside it, HAU-162) follow
  /// the current settings.
  void followBudgetSettings() {
    if (_setting(_budgetAudienceKey) != null) return;
    _transaction(() {
      for (final settings in all(Collections.budgetSettings)) {
        _budgetFollow(settings, null);
      }
      _db.execute(
        'INSERT INTO settings (key, value) VALUES (?, ?)'
        ' ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [_budgetAudienceKey, '1'],
      );
    });
  }

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
        if (id != null && canAccess(kept, id) && canAccess(lost, id)) id,
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

  /// What hangs on an appointment goes with it: when it becomes confidential
  /// (or no longer is) or its audience changes, its comments and packing list
  /// reach as many people as it does, and when it comes back from the trash
  /// devices that dropped them get them again.
  void _attachedFollow(SyncRecord event, SyncRecord? previous) {
    if (event.collection != Collections.events &&
        event.collection != Collections.externalEvents) {
      return;
    }
    if (previous == null) return;
    if (event.deleted) {
      _pinPackingListAudience(previous);
      return;
    }
    if (previous.deleted) {
      _releasePackingList(event);
    } else if (jsonEncode(_reach(event)) == jsonEncode(_reach(previous))) {
      return;
    }
    final members = memberIds();
    void rewrite(String collection, String field, String id) {
      for (final row in _db.select(
        'SELECT * FROM records WHERE collection = ? AND deleted = 0 '
        "AND json_extract(data, '\$.$field') = ?",
        [collection, id],
      )) {
        final r = _record(row);
        _put(r, previous: r, before: members);
        if (r.collection == Collections.shoppingLists) {
          rewrite(Collections.shoppingItems, 'listId', r.id);
        }
      }
    }

    rewrite(Collections.eventComments, 'eventId', event.id);
    rewrite(Collections.shoppingLists, 'eventId', event.id);
  }

  /// What the household book's settings decide who sees (#538).
  static const _budgetCollections = {
    Collections.budgetEntries,
    Collections.subscriptions,
  };

  /// Who sees the household book by its [settings]: null (everyone the
  /// collections reach) when it is open to all.
  static List<String>? _budgetAudience(SyncRecord? settings) {
    if (settings == null || settings.deleted) return null;
    final ids = [
      for (final id in settings.data['memberIds'] as List? ?? const [])
        if (id is String) id,
    ];
    return ids.isEmpty ? null : ids;
  }

  /// [incoming] only changes whom a household entry or subscription
  /// reaches, which follows the settings anyway (see [_budgetFollow]).
  static bool _onlyMovedAlong(SyncRecord incoming, SyncRecord? existing) {
    if (!_budgetCollections.contains(incoming.collection) ||
        existing == null ||
        existing.deleted ||
        incoming.deleted) {
      return false;
    }
    Map<String, Object?> content(SyncRecord r) =>
        {...r.data}..remove(SyncRecord.visibilityKey);
    return jsonEncode(_sorted(content(incoming))) ==
        jsonEncode(_sorted(content(existing)));
  }

  /// Whether [a] and [b] hold the same data, audience included, whatever
  /// the order of their keys.
  static bool _sameData(SyncRecord a, SyncRecord b) =>
      jsonEncode(_sorted(a.data)) == jsonEncode(_sorted(b.data));

  /// [value] with its maps' keys in order, to compare JSON by content.
  static Object? _sorted(Object? value) => switch (value) {
    Map() => {
      for (final key in value.keys.map((k) => '$k').toList()..sort())
        key: _sorted(value[key]),
    },
    List() => [for (final v in value) _sorted(v)],
    _ => value,
  };

  /// New settings move every entry and subscription along, also those an
  /// app did not move itself (written offline, by an older app, or in a
  /// later batch than the settings). Their writer keeps them, as when
  /// writing one.
  void _budgetFollow(SyncRecord settings, SyncRecord? previous) {
    if (settings.collection != Collections.budgetSettings) return;
    // Gone settings (e.g. with the only member who saw the book) open
    // nothing: every entry keeps whom it reaches.
    if (settings.deleted) return;
    final audience = _budgetAudience(settings);
    if (previous != null &&
        jsonEncode(_budgetAudience(previous)) == jsonEncode(audience)) {
      return;
    }
    for (final collection in _budgetCollections) {
      for (final row in _db.select(
        'SELECT * FROM records WHERE collection = ? AND deleted = 0',
        [collection],
      )) {
        final r = _record(row);
        final writer = r.updatedBy;
        final wanted = audience == null
            ? null
            : {
                ...audience,
                if (writer != null && writer != serverMemberId) writer,
              }.toList();
        if (jsonEncode(r.visibleTo) == jsonEncode(wanted)) continue;
        _put(
          r.copyWith(data: {...r.data, SyncRecord.visibilityKey: wanted}),
          previous: r,
        );
      }
    }
  }

  /// What decides who gets an appointment: besides the audience, for a
  /// confidential one who takes part.
  static List<Object?> _reach(SyncRecord e) => [
    e.data['confidential'] == true,
    e.visibleTo,
    if (e.data['confidential'] == true) ...[
      e.updatedBy,
      e.data['memberIds'],
      e.data['bringerId'],
      e.data['pickerId'],
    ],
  ];

  /// Who may see an appointment, for its packing list.
  List<String> _pinnedAudience(SyncRecord event) => [
    for (final m in memberIds())
      if (_role(m) != MemberRole.service && canAccess(event, m)) m,
  ];

  /// Marks an audience that only stands in for a deleted appointment, as
  /// against one somebody chose for the list.
  static const _standInAudience = 'audienceFromEvent';

  /// The packing lists made for [event].
  List<SyncRecord> _packingLists(SyncRecord event) => [
    for (final row in _db.select(
      'SELECT * FROM records WHERE collection = ? AND deleted = 0 '
      "AND json_extract(data, '\$.eventId') = ?",
      [Collections.shoppingLists, event.id],
    ))
      _record(row),
  ];

  /// The appointment is back and says again who sees its packing list.
  void _releasePackingList(SyncRecord event) {
    for (final list in _packingLists(event)) {
      if (list.data[_standInAudience] != true) continue;
      final open = list.copyWith(
        data: {...list.data}
          ..remove(SyncRecord.visibilityKey)
          ..remove(_standInAudience),
      );
      _put(open, previous: list);
      _itemsFollowList(open, list);
    }
  }

  /// A deleted appointment soon no longer says who may see it (its deletion
  /// mark goes after a while, and a mark does not say that it was
  /// confidential): from now on its packing list says so itself.
  void _pinPackingListAudience(SyncRecord event) {
    if (event.deleted ||
        (event.data['confidential'] != true && event.visibleTo == null)) {
      return;
    }
    final audience = _pinnedAudience(event);
    for (final list in _packingLists(event)) {
      final own = list.visibleTo;
      final SyncRecord pinned;
      if (own == null) {
        pinned = list.copyWith(
          data: {
            ...list.data,
            SyncRecord.visibilityKey: audience,
            _standInAudience: true,
          },
        );
      } else {
        final kept = [
          for (final id in own)
            if (audience.contains(id)) id,
        ];
        if (kept.length == own.length) continue;
        pinned = list.copyWith(
          data: {...list.data, SyncRecord.visibilityKey: kept},
        );
      }
      _put(pinned, previous: list);
      _itemsFollowList(pinned, list);
    }
  }

  /// Removes what is [memberId]'s alone before their account goes: their
  /// emergency facts and every entry only they could see, such as private
  /// notes, documents and health data (it would stay on the server with no
  /// one left to read or delete it, files included). Children's records
  /// stay, they are the family's; what the server keeps for connected
  /// services is theirs to update. Returns how many went.
  int purgeMember(String memberId, {DateTime? now}) {
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final personal = [
      for (final row in _db.select(
        'SELECT * FROM records WHERE deleted = 0 AND ('
        '(collection = ? AND id = ?) OR '
        "(json_array_length(visible_to) = 1 "
        "AND json_extract(visible_to, '\$[0]') = ?))",
        [Collections.memberEmergency, memberId, memberId],
      ))
        if (_isPrivate(_record(row))) _record(row),
    ];
    // What hangs on them goes too: the packing list of a private
    // appointment (it would keep the departed account as its audience) and
    // the entries of the lists that go.
    final going = {for (final r in personal) '${r.collection}/${r.id}'};
    void add(SyncRecord r) {
      if (going.add('${r.collection}/${r.id}')) personal.add(r);
    }

    for (final r in [...personal]) {
      if (r.collection == Collections.events) _packingLists(r).forEach(add);
    }
    for (final r in [...personal]) {
      if (r.collection != Collections.shoppingLists) continue;
      for (final row in _db.select(
        'SELECT * FROM records WHERE collection = ? AND deleted = 0'
        " AND json_extract(data, '\$.listId') = ?",
        [Collections.shoppingItems, r.id],
      )) {
        add(_record(row));
      }
    }
    _transaction(() {
      for (final listed in personal) {
        // As it is now: deleting an appointment may have just changed its
        // packing list's audience.
        final r = get(listed.collection, listed.id) ?? listed;
        if (r.deleted) continue;
        _put(
          SyncRecord(
            collection: r.collection,
            id: r.id,
            data: {SyncRecord.visibilityKey: ?r.visibleTo},
            deleted: true,
            updatedAt: at > r.updatedAt ? at : r.updatedAt + 1,
            updatedBy: serverMemberId,
          ),
          previous: r,
          trash: false,
        );
      }
      _forgetTrashOf(memberId);
      _handOnChildren(memberId, at);
    });
    return personal.length;
  }

  /// What stays of a departed member: children's records and timetables
  /// they were named for lose them as guardian and audience. What no other
  /// adult was named for goes to the child's other guardians (#506). Where
  /// none remain either, the record is for the whole family, as a child
  /// without guardians is in the apps (else nobody could see or change
  /// it), and for whoever else was named, the child itself, say.
  void _handOnChildren(String memberId, int at) {
    const kept = [
      Collections.children,
      Collections.childEntries,
      Collections.childLogs,
      Collections.timetables,
    ];
    final records = [
      for (final row in _db.select(
        'SELECT * FROM records WHERE deleted = 0'
        ' AND collection IN (?, ?, ?, ?)',
        kept,
      ))
        _record(row),
    ];
    final members = memberIds().toSet();
    bool adult(Object? id) =>
        id is String &&
        id != memberId &&
        members.contains(id) &&
        _role(id) == MemberRole.adult;
    List<String> guardiansOf(SyncRecord r) => [
      for (final g in r.data['guardianIds'] as List? ?? const []) '$g',
    ];
    // Read before any child is changed: whom each one still has.
    final guardiansLeft = {
      for (final r in records)
        if (r.collection == Collections.children)
          r.id: guardiansOf(r).where(adult).toList(),
    };
    final adults = members.where(adult).toList();
    for (final r in records) {
      final audience = r.visibleTo;
      final guardians = r.collection == Collections.children
          ? guardiansOf(r)
          : const <String>[];
      if (!(audience?.contains(memberId) ?? false) &&
          !guardians.contains(memberId)) {
        continue;
      }
      final childId =
          r.collection == Collections.childEntries ||
              r.collection == Collections.childLogs
          ? '${r.data['childId']}'
          : r.id;
      final rest = [...?audience]..remove(memberId);
      final others = guardiansLeft[childId] ?? const <String>[];
      final List<String>? next = audience == null || rest.any(adult)
          ? (audience == null ? null : rest)
          : others.isNotEmpty
          ? {...rest, ...others}.toList()
          : rest.isEmpty
          ? null
          : {...rest, ...adults}.toList();
      _put(
        r.copyWith(
          data: {
            for (final e in r.data.entries)
              if (e.key != SyncRecord.visibilityKey) e.key: e.value,
            if (guardians.contains(memberId))
              'guardianIds': [...guardians]..remove(memberId),
            SyncRecord.visibilityKey: ?next,
          },
          updatedAt: at > r.updatedAt ? at : r.updatedAt + 1,
          updatedBy: serverMemberId,
        ),
        previous: r,
        trash: false,
      );
    }
  }

  /// Goes with the member whose audience it is alone (see [purgeMember]).
  static bool _isPrivate(SyncRecord r) =>
      r.collection == Collections.memberEmergency ||
      !(const {
            Collections.children,
            Collections.childEntries,
            Collections.childLogs,
            // A child's timetable, even when only one parent keeps it.
            Collections.timetables,
          }.contains(r.collection) ||
          Collections.serverOwned.contains(r.collection));

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
    SyncRecord? deletionSnapshot,
    bool trash = true,
  }) {
    r = _canonicalFiles(r);
    if (deletionSnapshot != null) {
      deletionSnapshot = _canonicalFiles(deletionSnapshot);
    }
    if (previous != null) previous = _canonicalFiles(previous);
    if (r.deleted && previous != null) {
      final audience = _audience(previous);
      r = r.copyWith(data: {SyncRecord.visibilityKey: ?audience});
    }
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

    if (trash) _rememberDeletion(r, deletionSnapshot ?? previous, rev);
    if (r.collection == Collections.tasks) _markTicks(r, previous, rev);
    _assignmentsFollow(r);
    _attachedFollow(r, previous);
    _budgetFollow(r, previous);

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

  /// Apps before 2.0.15 know nothing of who sees a shopping list, and no app
  /// of who sees an appointment from a shared calendar: they leave the key
  /// out, and their changes keep the stored audience.
  /// What a child logs or ticks off belongs to a child or plan it is named
  /// for, goes to whoever sees that, and is in its own name. What someone
  /// else entered (a vaccination, a dose, a measurement) stays as they
  /// entered it (#505). Null when the write is not allowed.
  SyncRecord? _childHealthWrite(
    SyncRecord incoming,
    SyncRecord? existing,
    String userId,
  ) {
    final (parentCollection, parentKey) = switch (incoming.collection) {
      Collections.childEntries ||
      Collections.childLogs => (Collections.children, 'childId'),
      Collections.medicationIntakes => (
        Collections.medications,
        'medicationId',
      ),
      _ => (null, null),
    };
    if (parentCollection == null) return incoming;
    if (existing != null && !existing.deleted && existing.updatedBy != userId) {
      return null;
    }
    if (incoming.deleted) return incoming;
    final parent = _get(parentCollection, '${incoming.data[parentKey]}');
    if (parent == null || parent.deleted || !canAccess(parent, userId)) {
      return null;
    }
    return incoming.copyWith(
      data: {
        ...incoming.data,
        if (incoming.collection == Collections.medicationIntakes)
          'byId': userId,
        SyncRecord.visibilityKey: parent.data[SyncRecord.visibilityKey],
      },
    );
  }

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

  /// Children do not decide who sees something: on a record that exists,
  /// what they write keeps the stored audience. Only what so far they alone
  /// see they may share. Health data never gets here with a changed
  /// audience ([mayWrite] turns that down). The same holds for what else
  /// widens it: a confidential appointment stays confidential and gets no
  /// new people taking part, a task kept to a few gets no one else assigned.
  /// A child's own appointment: the child entered it (see
  /// [CalendarEvent.createdByKey]) and nobody else takes part. Who wrote it
  /// last does not count: a child's note on the parents' appointment does
  /// not make it the child's (#416). Appointments from before the key have
  /// no owner here.
  /// One an adult made confidential is not the child's here either (see
  /// [CalendarEvent.childOwns]).
  static bool childOwnsEvent(Map<String, Object?> event, String userId) =>
      CalendarEvent.childOwns(event, userId);

  /// Who entered an appointment or created a task ([CalendarEvent.createdByKey],
  /// [Task.createdByKey]): set when it is created, kept on every change;
  /// what an app sends for it does not count. [existing] is the stored
  /// version or, over a deletion, the last live one; over a tombstone whose
  /// live version is gone, the writer.
  static SyncRecord _withCreator(
    SyncRecord incoming,
    SyncRecord? existing,
    String userId,
  ) {
    final event = incoming.collection == Collections.events;
    final key = event ? CalendarEvent.createdByKey : Task.createdByKey;
    final data = {...incoming.data}..remove(key);
    if (event) data.remove(CalendarEvent.confidentialByKey);
    // Over a tombstone whose live version has left the bin nothing of the
    // earlier record is left: what is written now is new.
    final creator = existing == null || existing.deleted
        ? userId
        : existing.data[key];
    if (creator != null) data[key] = creator;
    if (event && existing != null && !existing.deleted) {
      final by = existing.data[CalendarEvent.confidentialByKey];
      if (by != null) data[CalendarEvent.confidentialByKey] = by;
    }
    return incoming.copyWith(data: data);
  }

  /// A client that omits the attachment field cannot tell us it removed
  /// the files. Preserve the stored references, including for old offline
  /// edits sent after this upgrade. An explicit list always wins.
  static SyncRecord _keepEventFiles(SyncRecord next, SyncRecord? previous) {
    if (next.collection != Collections.events ||
        next.deleted ||
        previous == null ||
        previous.deleted ||
        next.data['files'] != null) {
      return next;
    }
    final files = previous.data['files'];
    return files is List && files.isNotEmpty && recordDataIsValid(previous)
        ? next.copyWith(data: {...next.data, 'files': files})
        : next;
  }

  /// Who made an appointment confidential, after what a child may change
  /// was settled ([_childAudience]): who switches it on, kept while it
  /// stays on, gone with it.
  static SyncRecord _withConfidentialBy(
    SyncRecord incoming,
    SyncRecord? existing,
    String userId,
  ) {
    final data = {...incoming.data};
    if (data['confidential'] != true) {
      data.remove(CalendarEvent.confidentialByKey);
    } else if (existing == null ||
        existing.deleted ||
        existing.data['confidential'] != true) {
      data[CalendarEvent.confidentialByKey] = userId;
    }
    return incoming.copyWith(data: data);
  }

  static SyncRecord _childAudience(
    SyncRecord incoming,
    SyncRecord? existing,
    String userId,
  ) {
    if (existing == null || existing.deleted) return incoming;
    final before = existing.visibleTo;
    if (before != null && before.length == 1 && before.single == userId) {
      return incoming;
    }
    final data = {...incoming.data};
    if (jsonEncode(incoming.visibleTo) != jsonEncode(before)) {
      data.remove(SyncRecord.visibilityKey);
      if (before != null) data[SyncRecord.visibilityKey] = before;
    }
    final confidential = existing.data['confidential'] == true;
    final owned =
        incoming.collection == Collections.events &&
        childOwnsEvent(existing.data, userId);
    if (incoming.collection == Collections.events &&
        (data['confidential'] == true) != confidential &&
        !owned) {
      // Neither hides a family appointment nor reveals a confidential one;
      // their own appointments children mark as they like.
      if (existing.data.containsKey('confidential')) {
        data['confidential'] = existing.data['confidential'];
      } else {
        data.remove('confidential');
      }
    }
    // A confidential appointment someone else entered or made confidential
    // gets no new people taking part; one the child entered and made
    // confidential itself it shares with whom it likes (KAL-046).
    if (incoming.collection == Collections.events &&
        confidential &&
        !CalendarEvent.childEntered(existing.data, userId)) {
      final reach = {
        existing.updatedBy,
        ...?(existing.data['memberIds'] as List?),
        existing.data['bringerId'],
        existing.data['pickerId'],
      };
      if (data['memberIds'] case final List<Object?> ids) {
        data['memberIds'] = [
          for (final id in ids)
            if (reach.contains(id)) id,
        ];
      }
      for (final key in const ['bringerId', 'pickerId']) {
        if (data[key] != null && !reach.contains(data[key])) {
          data[key] = existing.data[key];
        }
      }
    }
    if (incoming.collection == Collections.events &&
        !CalendarEvent.childEntered(existing.data, userId)) {
      // Who else takes part in an appointment the child did not enter
      // stays in it: a child takes only itself out. In its own the child
      // adds and removes people freely.
      final ids = [...?(data['memberIds'] as List?)];
      final before = existing.data['memberIds'] as List? ?? const [];
      if (before.isEmpty) {
        // Nor does it name people in an appointment of the whole family:
        // naming itself would take it from everyone else (#559).
        if (ids.isNotEmpty) data['memberIds'] = <Object?>[];
      } else {
        final missing = [
          for (final id in before)
            if (id != userId && !ids.contains(id)) id,
        ];
        if (missing.isNotEmpty) data['memberIds'] = [...ids, ...missing];
      }
      // Nor does it take single dates out of such a series: "only this
      // date" would make the date the child's own copy (#416).
      if (existing.data.containsKey('exceptions')) {
        data['exceptions'] = existing.data['exceptions'];
      } else {
        data.remove('exceptions');
      }
    }
    if (incoming.collection == Collections.tasks && before != null) {
      final allowed = {...before, ...Task.assigneesIn(existing.data)};
      final ids = Task.assigneesIn(data);
      if (ids.any((id) => !allowed.contains(id))) {
        final kept = [
          for (final id in ids)
            if (allowed.contains(id)) id,
        ];
        data['assigneeIds'] = kept;
        data['assigneeId'] = kept.firstOrNull;
      }
    }
    return incoming.copyWith(data: data);
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

  /// Key of a task's data: who sees it only because they stand in for an
  /// absent assignee (see [MemberAbsence]); taken out again when the
  /// absence is over.
  static const substitutesKey = 'substitutes';

  /// The substitutes of [assignees] absent on [day]: for overlapping
  /// absences only the one the apps show too (see [absenceFor]).
  List<String> _standingIn(List<String> assignees, DateTime day) {
    final absences = [
      for (final r in all(Collections.absences)) MemberAbsence.fromRecord(r),
    ];
    return {
      for (final id in assignees) ?absenceFor(absences, id, day)?.substituteId,
    }.toList();
  }

  /// A task only some see is also seen by whoever stands in for one of its
  /// assignees today; who was added for an absence is noted, so they lose
  /// it again afterwards. Apps do not know the note and send the audience
  /// with the substitute in it: those added before count as added.
  SyncRecord _withSubstitutes(SyncRecord task, SyncRecord? previous) {
    final added = {
      for (final id in previous?.data[substitutesKey] as List? ?? const [])
        '$id',
    };
    final data = {...task.data}..remove(substitutesKey);
    final ids = task.visibleTo;
    if (ids == null) return task.copyWith(data: data);
    final assignees = Task.assigneesIn(data);
    final base = {
      for (final id in ids)
        if (!added.contains(id) || assignees.contains(id)) id,
    };
    final standing = [
      for (final id in _standingIn(assignees, _today()))
        if (!base.contains(id)) id,
    ];
    data[SyncRecord.visibilityKey] = [...base, ...standing];
    if (standing.isNotEmpty) data[substitutesKey] = standing;
    return task.copyWith(data: data);
  }

  /// Gives the substitutes of today's absences their tasks and takes them
  /// away from those whose absence is over: after absences changed and
  /// regularly for the change of day. Returns whether anything changed.
  bool refreshSubstitutes() {
    var changed = false;
    _transaction(() {
      for (final task in all(Collections.tasks)) {
        if (task.visibleTo == null && task.data[substitutesKey] == null) {
          continue;
        }
        final next = _withSubstitutes(task, task);
        if (jsonEncode(next.data) == jsonEncode(task.data)) continue;
        _put(next, previous: task);
        changed = true;
      }
    });
    return changed;
  }

  /// A gift idea (see [Wish.ideaBy]) is seen by everyone but the member
  /// it is for, whatever an app sends; one written by an app that does not
  /// know ideas stays an idea.
  SyncRecord _ideaAudience(SyncRecord incoming, SyncRecord? existing) {
    final before = existing == null || existing.deleted ? null : existing;
    final ideaBy =
        incoming.data[Wish.ideaByKey] ?? before?.data[Wish.ideaByKey];
    if (ideaBy == null) return incoming;
    final owner = incoming.data['ownerId'] ?? before?.data['ownerId'];
    final audience = incoming.visibleTo ?? before?.visibleTo ?? memberIds();
    return incoming.copyWith(
      data: {
        ...incoming.data,
        Wish.ideaByKey: ideaBy,
        'ownerId': owner,
        SyncRecord.visibilityKey: [
          for (final id in audience)
            if (id != owner) id,
        ],
      },
    );
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
        // Of an existing task only the ticks count, put on the task as it
        // is ([_guestTaskChange]), as for guests: ticking a repeating task
        // also moves it on, and the app writes whole tasks (#556).
        return existing != null && !existing.deleted && !incoming.deleted;
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
    final snapshotEnvelope =
        r.deleted && r.data.length == 1 && r.data['deletionSnapshot'] is Map;
    if (utf8.encode(jsonEncode(r.data)).length >
        _maxDataBytes + (snapshotEnvelope ? 32 : 0)) {
      throw ApiException(413, 'too_large', t('Eintrag ist zu groß'));
    }
    try {
      validateRecordData(r);
    } on FormatException {
      throw ApiException.badRequest('invalid_record', t('Ungültiger Eintrag.'));
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
    final rows = _db.select(
      'SELECT * FROM records WHERE collection = ? AND deleted = 0',
      [collection],
    );
    if (visibleToMember == null) return [for (final row in rows) _record(row)];
    final role = _role(visibleToMember);
    return [
      for (final row in rows)
        if (_record(row) case final r when canAccess(r, visibleToMember))
          _shown(r, role),
    ];
  }

  /// Whether a visible record has an actual attachment with this file id.
  bool referencedFor(String fileId, String memberId) {
    _refreshFileReferences();
    if (_indexedTrashReference(fileId, memberId: memberId)) return true;
    for (final key in _recordsByFile[fileId] ?? const <(String, String)>{}) {
      final record = _get(key.$1, key.$2);
      if (record != null &&
          !record.deleted &&
          canAccess(record, memberId) &&
          _showsFile(record, fileId, memberId)) {
        return true;
      }
    }
    return false;
  }

  /// Whether [fileId] is still there in what [memberId] gets of [r].
  bool _showsFile(SyncRecord r, String fileId, String memberId) =>
      recordFileIds(_shown(r, _role(memberId))).contains(fileId);

  /// Retention includes quarantined data without granting read permission.
  bool referenced(String fileId) {
    _refreshFileReferences();
    return (_recordsByFile[fileId]?.isNotEmpty ?? false) ||
        _indexedTrashReference(fileId) ||
        _damagedFileRecords.values.any((data) => data.contains(fileId));
  }

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

  /// Leaves [ids] of [collection] deleted for good, also where nothing was
  /// stored yet: a job that writes records under fixed ids then skips them,
  /// as one an adult deleted (pocket money on a paused payday, #581).
  /// Returns whether any mark is new.
  bool markDeletedAsServer(String collection, Iterable<String> ids) {
    var changed = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    _transaction(() {
      for (final id in {...ids}) {
        if (_get(collection, id) != null) continue;
        _put(
          SyncRecord(
            collection: collection,
            id: id,
            data: const {},
            deleted: true,
            updatedAt: now,
            updatedBy: serverMemberId,
          ),
          previous: null,
        );
        changed = true;
      }
    });
    return changed;
  }

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
    final indexed = _fileIndexRev;
    _db.execute('BEGIN IMMEDIATE');
    try {
      action();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      // Only if the index has read rows of this transaction.
      if (_fileIndexRev != indexed) _resetFileReferences();
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

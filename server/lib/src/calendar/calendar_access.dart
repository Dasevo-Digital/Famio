import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../record_store.dart';

/// Decides who sees the events of connected calendars (ICS subscriptions and
/// CalDAV accounts): the owner's sharing, minus members an admin switched
/// the calendar off for in their calendar profile. The owner always sees
/// their own calendars.
class CalendarAccess {
  CalendarAccess(this.db, {required this.records, required this.memberIds});

  final Database db;
  final RecordStore records;
  final List<String> Function() memberIds;

  /// Source key of CalDAV account [accountId].
  static String caldavSource(String accountId) => 'caldav:$accountId';

  /// Source key of an imported event's `sourceId`: the subscription id, or
  /// `caldav:<account>` for read-only events of CalDAV accounts.
  static String sourceOf(String sourceId) {
    if (!sourceId.startsWith('caldav:')) return sourceId;
    final parts = sourceId.split(':');
    return parts.length < 2 ? sourceId : caldavSource(parts[1]);
  }

  /// Sources switched off for [memberId].
  Set<String> hiddenFor(String memberId) => {
    for (final row in db.select(
      'SELECT source FROM calendar_hidden WHERE member_id = ?',
      [memberId],
    ))
      row['source'] as String,
  };

  void setHidden(String memberId, Iterable<String> sources) {
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM calendar_hidden WHERE member_id = ?', [memberId]);
      for (final s in {...sources}) {
        db.execute(
          'INSERT INTO calendar_hidden (member_id, source) VALUES (?, ?)',
          [memberId, s],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Owner and sharing of [source], or null if it no longer exists.
  (String? owner, CalendarSharing sharing)? _sourceInfo(String source) {
    if (source.startsWith('caldav:')) {
      final row = db.select(
        'SELECT user_id, shared_with FROM caldav_accounts WHERE id = ?',
        [source.substring('caldav:'.length)],
      ).firstOrNull;
      if (row == null) return null;
      final shared = row['shared_with'] as String?;
      return (
        row['user_id'] as String,
        CalendarSharing.fromJson(shared == null ? null : jsonDecode(shared)),
      );
    }
    final r = records.get(Collections.calendarSubscriptions, source);
    if (r == null || r.deleted) return null;
    final sub = CalendarSubscription.fromRecord(r);
    return (sub.ownerId, sub.sharing);
  }

  /// Audience of events from [source]: null for the whole family.
  List<String>? audience(String source) {
    final info = _sourceInfo(source);
    if (info == null) return null;
    final (owner, sharing) = info;
    final hidden = {
      for (final row in db.select(
        'SELECT member_id FROM calendar_hidden WHERE source = ?',
        [source],
      ))
        row['member_id'] as String,
    }..remove(owner);
    if (sharing.family && hidden.isEmpty) return null;
    final base = sharing.family || owner == null
        ? memberIds()
        : sharing.audience(owner)!;
    return [
      for (final m in base)
        if (!hidden.contains(m)) m,
    ]..sort();
  }

  /// The calendars that reach [memberId] by their owner's sharing (not their
  /// own), with the admin's choice.
  List<MemberCalendar> calendarsOf(String memberId) {
    final hidden = hiddenFor(memberId);
    bool reaches(String? owner, CalendarSharing sharing) =>
        owner != memberId &&
        (sharing.family ||
            owner == null ||
            sharing.members!.contains(memberId));
    return [
      for (final r in records.all(Collections.calendarSubscriptions))
        if (CalendarSubscription.fromRecord(r) case final sub
            when reaches(sub.ownerId, sub.sharing))
          MemberCalendar(
            source: sub.id,
            name: sub.name,
            kind: 'subscription',
            ownerId: sub.ownerId,
            hidden: hidden.contains(sub.id),
          ),
      for (final row in db.select(
        'SELECT id, user_id, name, shared_with, oauth FROM caldav_accounts'
        ' ORDER BY name',
      ))
        if (reaches(
          row['user_id'] as String,
          CalendarSharing.fromJson(
            row['shared_with'] == null
                ? null
                : jsonDecode(row['shared_with'] as String),
          ),
        ))
          MemberCalendar(
            source: caldavSource(row['id'] as String),
            name: row['name'] as String,
            kind: row['oauth'] == null ? 'caldav' : 'google',
            ownerId: row['user_id'] as String,
            hidden: hidden.contains(caldavSource(row['id'] as String)),
          ),
    ];
  }

  /// Brings the audience of every imported event (and subscription status)
  /// in line after sharing, calendar profiles or the family changed. Returns
  /// whether anything changed.
  bool reapply() {
    final cache = <String, List<String>?>{};
    List<String>? of(String source) =>
        cache.putIfAbsent(source, () => audience(source));
    final changes = <SyncRecord>[];
    void check(SyncRecord r, String source) {
      final want = of(source);
      if (jsonEncode(r.visibleTo) == jsonEncode(want)) return;
      changes.add(
        r.copyWith(
          data: {...r.data..remove(SyncRecord.visibilityKey)}
            ..addAll({SyncRecord.visibilityKey: ?want}),
        ),
      );
    }

    for (final r in records.all(Collections.externalEvents)) {
      final sourceId = r.data['sourceId'] as String?;
      if (sourceId != null) check(r, sourceOf(sourceId));
    }
    for (final r in records.all(Collections.calendarSyncStatus)) {
      check(r, r.id);
    }
    // Hidden members need not see the subscription itself either.
    for (final r in records.all(Collections.calendarSubscriptions)) {
      check(r, r.id);
    }
    // Two-way events that came from a CalDAV account.
    for (final row in db.select(
      "SELECT account_id, event_id FROM caldav_links WHERE mode = 'sync'"
      " AND origin = 'remote' AND event_id IS NOT NULL",
    )) {
      final r = records.get(Collections.events, row['event_id'] as String);
      if (r != null && !r.deleted) {
        check(r, caldavSource(row['account_id'] as String));
      }
    }
    return records.writeAsServer(changes);
  }
}

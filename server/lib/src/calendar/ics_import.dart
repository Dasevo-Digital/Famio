import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:rrule/rrule.dart';
import 'package:timezone/timezone.dart' as tz;

import 'ics.dart';

/// Converts an external iCalendar feed into Famio events for the time window
/// `[from, to)`. Series are expanded into single events, so every RRULE the
/// source can express (BYDAY, BYSETPOS, …) is shown correctly.
///
/// Returned events have stable ids derived from [sourceId], the UID and the
/// original start, so re-imports update instead of duplicating.
List<CalendarEvent> importIcs(
  String text, {
  required String sourceId,
  required tz.Location fallback,
  required DateTime from,
  required DateTime to,
  int maxEvents = 5000,
}) {
  final root = parseIcs(text);
  final calendar = root.components('VCALENDAR').firstOrNull ?? root;
  final zone =
      resolveTimeZone(calendar.property('X-WR-TIMEZONE')?.value) ?? fallback;

  final masters = <String, IcsComponent>{};
  final overrides = <String, Map<DateTime, IcsComponent>>{};
  var anonymous = 0;
  for (final v in calendar.components('VEVENT')) {
    final uid = v.property('UID')?.value ?? 'no-uid-${anonymous++}';
    final recurrenceId = parseIcsTime(v.property('RECURRENCE-ID'), zone);
    if (recurrenceId == null) {
      masters[uid] = v;
    } else {
      (overrides[uid] ??= {})[recurrenceId.instant] = v;
    }
  }

  final result = <CalendarEvent>[];

  /// Adds [v] as an event; [at] moves it to one occurrence of its series.
  void add(IcsComponent v, String uid, String key, {IcsTime? at}) {
    if (result.length >= maxEvents) return;
    if (v.property('STATUS')?.value.toUpperCase() == 'CANCELLED') return;
    var event = _event(
      v,
      zone,
      id: _id(sourceId, uid, key),
      sourceId: sourceId,
    );
    if (event == null) return;
    if (at != null) {
      final begin = at.dateOnly ? at.wall : at.instant;
      event = event.copyWith(start: begin, end: begin.add(event.duration));
    }
    final visible =
        event.start.isBefore(to) &&
        (event.end.isAfter(from) ||
            (event.end == event.start && !event.start.isBefore(from)));
    if (visible) result.add(event);
  }

  for (final MapEntry(key: uid, value: master) in masters.entries) {
    final start = parseIcsTime(master.property('DTSTART'), zone);
    final rrule = master.property('RRULE');
    if (start == null) continue;
    if (rrule == null) {
      add(master, uid, '');
      continue;
    }

    final moved = overrides.remove(uid) ?? {};
    final excluded = {
      for (final p in master.all('EXDATE'))
        for (final t in parseIcsTimes(p, start.location))
          start.dateOnly ? t.wall : t.instant,
    };
    // Start early enough to catch occurrences still running at [from].
    final lookBack = from.subtract(_length(master, start, zone));
    for (final wall in _instances(rrule.value, start, lookBack, to)) {
      if (result.length >= maxEvents) break;
      final occurrence = start.withWall(wall);
      final key = occurrence.instant.toIso8601String();
      if (excluded.contains(start.dateOnly ? wall : occurrence.instant)) {
        continue;
      }
      final override = moved.remove(occurrence.instant);
      if (override != null) {
        add(override, uid, key);
      } else {
        add(master, uid, key, at: occurrence);
      }
    }
    // Moved occurrences whose original slot is outside the window.
    for (final MapEntry(key: instant, value: v) in moved.entries) {
      add(v, uid, instant.toIso8601String());
    }
  }
  // Overrides without a master (e.g. only one instance was shared).
  for (final MapEntry(key: uid, value: byInstant) in overrides.entries) {
    for (final MapEntry(key: instant, value: v) in byInstant.entries) {
      add(v, uid, instant.toIso8601String());
    }
  }
  return result;
}

CalendarEvent? _event(
  IcsComponent v,
  tz.Location zone, {
  required String id,
  required String sourceId,
}) {
  final start = parseIcsTime(v.property('DTSTART'), zone);
  if (start == null) return null;
  final length = _length(v, start, zone);
  final title = v.property('SUMMARY')?.text.trim() ?? '';
  final begin = start.dateOnly ? start.wall : start.instant;
  return CalendarEvent(
    id: id,
    title: title.isEmpty ? '(Ohne Titel)' : title,
    start: begin,
    end: start.dateOnly ? _addDays(begin, length.inDays) : begin.add(length),
    allDay: start.dateOnly,
    location: v.property('LOCATION')?.text.trim() ?? '',
    notes: v.property('DESCRIPTION')?.text.trim() ?? '',
    sourceId: sourceId,
  );
}

/// Event length from DTEND or DURATION; all-day events default to one day.
Duration _length(IcsComponent v, IcsTime start, tz.Location zone) {
  final end = parseIcsTime(v.property('DTEND'), zone);
  if (end != null) {
    final d = start.dateOnly
        ? Duration(days: end.wall.difference(start.wall).inDays)
        : end.instant.difference(start.instant);
    if (!d.isNegative) return d;
  }
  final duration = parseIcsDuration(v.property('DURATION')?.value);
  if (duration != null && !duration.isNegative) return duration;
  return start.dateOnly ? const Duration(days: 1) : Duration.zero;
}

DateTime _addDays(DateTime d, int days) =>
    DateTime.utc(d.year, d.month, d.day + (days < 1 ? 1 : days));

/// Wall-clock starts of a series within `[from, to)`. UNTIL values in UTC
/// are moved into the series' zone first, because rrule compares wall-clock
/// times.
Iterable<DateTime> _instances(
  String rrule,
  IcsTime start,
  DateTime from,
  DateTime to,
) sync* {
  final value = rrule.replaceAllMapped(RegExp(r'UNTIL=(\d{8}T\d{6})Z'), (m) {
    final t = parseIcsTimes(IcsProperty('UNTIL', '${m[1]}Z'), tz.UTC).first;
    final local = tz.TZDateTime.from(t.instant, start.location);
    return 'UNTIL=${formatIcsTime(local, dateOnly: start.dateOnly)}';
  });
  final RecurrenceRule rule;
  try {
    rule = RecurrenceRule.fromString('RRULE:$value');
  } catch (_) {
    yield start.wall; // Unparseable rule: show at least the first date.
    return;
  }
  DateTime wall(DateTime instant) {
    final t = tz.TZDateTime.from(instant, start.location);
    return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }

  final fromWall = wall(from).subtract(const Duration(days: 1));
  var count = 0;
  for (final w in rule.getInstances(
    start: start.wall,
    after: fromWall.isAfter(start.wall) ? fromWall : null,
    includeAfter: true,
  )) {
    if (!w.isBefore(wall(to)) || ++count > 5000) break;
    yield w;
  }
}

String _id(String sourceId, String uid, String key) => sha1
    .convert(utf8.encode('$sourceId|$uid|$key'))
    .toString()
    .substring(0, 32);

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:rrule/rrule.dart';
import 'package:timezone/timezone.dart' as tz;

import 'ics.dart';
import 'ics_export.dart';

/// Renders one Famio event as a complete iCalendar object, as CalDAV
/// resources are exchanged (one event with its own VCALENDAR).
String eventToIcs(
  CalendarEvent e, {
  required tz.Location location,
  required int updatedAt,
  DateTime? now,
}) {
  final w = IcsWriter()
    ..begin('VCALENDAR')
    ..line('VERSION', '2.0')
    ..line('PRODID', '-//Famio//Famio Server//DE')
    ..line('CALSCALE', 'GREGORIAN');
  // Series are written with TZID, which needs its definition.
  if (e.recurrence != null && !e.allDay) {
    writeVTimezone(w, location, e.start.year - 1);
  }
  final modified = formatIcsTime(
    DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    utc: true,
  );
  w
    ..begin('VEVENT')
    ..line('UID', escapeText(e.uid))
    ..line('DTSTAMP', formatIcsTime((now ?? DateTime.now()).toUtc(), utc: true))
    ..line('LAST-MODIFIED', modified)
    ..line('CREATED', modified);
  writeEventTimes(w, e, location);
  w
    ..text('SUMMARY', e.title)
    ..text('LOCATION', e.location)
    ..text('DESCRIPTION', e.notes);
  if (e.confidential) w.line('CLASS', 'CONFIDENTIAL');
  final reminder = e.reminderMinutes;
  if (reminder != null) {
    w
      ..begin('VALARM')
      ..line('ACTION', 'DISPLAY')
      ..text('DESCRIPTION', e.title.isEmpty ? 'Erinnerung' : e.title)
      ..line('TRIGGER', _duration(-reminder))
      ..end('VALARM');
  }
  w
    ..end('VEVENT')
    ..end('VCALENDAR');
  return w.toString();
}

/// `-PT15M`, `PT8H`, `-P1DT6H` …
String _duration(int minutes) {
  final sign = minutes < 0 ? '-' : '';
  var rest = minutes.abs();
  final days = rest ~/ 1440;
  rest %= 1440;
  final hours = rest ~/ 60;
  final mins = rest % 60;
  final time = [
    if (hours > 0) '${hours}H',
    if (mins > 0 || (hours == 0 && days == 0)) '${mins}M',
  ].join();
  return '${sign}P${days > 0 ? '${days}D' : ''}${time.isEmpty ? '' : 'T$time'}';
}

/// Writes a VTIMEZONE for [location] with the daylight saving rules in
/// effect in [year] (repeated yearly), or a fixed offset if it has none.
void writeVTimezone(IcsWriter w, tz.Location location, int year) {
  final from = DateTime.utc(year).millisecondsSinceEpoch;
  final to = DateTime.utc(year + 1).millisecondsSinceEpoch;
  final changes = <int>[
    for (var i = 1; i < location.transitionAt.length; i++)
      if (location.transitionAt[i] >= from && location.transitionAt[i] < to) i,
  ];
  w
    ..begin('VTIMEZONE')
    ..line('TZID', location.name);
  if (changes.isEmpty) {
    final zone = location.timeZone(from);
    w
      ..begin('STANDARD')
      ..line('DTSTART', '19700101T000000')
      ..line('TZOFFSETFROM', _offset(zone.offset))
      ..line('TZOFFSETTO', _offset(zone.offset))
      ..text('TZNAME', zone.abbreviation)
      ..end('STANDARD');
  } else {
    for (final i in changes) {
      final before = location.zones[location.transitionZone[i - 1]];
      final after = location.zones[location.transitionZone[i]];
      final wall = DateTime.fromMillisecondsSinceEpoch(
        location.transitionAt[i] + before.offset.inMilliseconds,
        isUtc: true,
      );
      final lastDay = DateTime.utc(wall.year, wall.month + 1, 0).day;
      final nth = wall.day > lastDay - 7 ? -1 : (wall.day - 1) ~/ 7 + 1;
      final kind = after.isDst ? 'DAYLIGHT' : 'STANDARD';
      w
        ..begin(kind)
        ..line('DTSTART', formatIcsTime(wall))
        ..line(
          'RRULE',
          'FREQ=YEARLY;BYMONTH=${wall.month};'
              'BYDAY=$nth${icsWeekdays[wall.weekday - 1]}',
        )
        ..line('TZOFFSETFROM', _offset(before.offset))
        ..line('TZOFFSETTO', _offset(after.offset))
        ..text('TZNAME', after.abbreviation)
        ..end(kind);
    }
  }
  w.end('VTIMEZONE');
}

String _offset(Duration offset) {
  final minutes = offset.inMinutes;
  final sign = minutes < 0 ? '-' : '+';
  final abs = minutes.abs();
  return '$sign${(abs ~/ 60).toString().padLeft(2, '0')}'
      '${(abs % 60).toString().padLeft(2, '0')}';
}

/// What a calendar object from another app means for Famio.
class ParsedEvent {
  ParsedEvent({
    this.event,
    this.detached = const [],
    this.unsupported,
    this.hasOverrides = false,
    this.lastModified,
    this.uid,
  });

  /// The event (series master), null if the object holds no event.
  final CalendarEvent? event;

  /// Single occurrences edited in the other app (RECURRENCE-ID), turned into
  /// standalone events; their dates are exceptions of [event].
  final List<CalendarEvent> detached;

  /// Why the event cannot be edited in Famio, e.g. a repetition rule Famio
  /// has no equivalent for. [event] is then null.
  final String? unsupported;

  /// Whether single occurrences were changed in the other app.
  final bool hasOverrides;
  final DateTime? lastModified;
  final String? uid;
}

/// Parses a calendar object (one VCALENDAR with the VEVENTs of one UID)
/// into a Famio event with id [id]. Participants, visibility and the
/// confidential flag of [existing] are kept, as other apps do not know them.
/// [allowConfidential] lets CLASS:PRIVATE/CONFIDENTIAL mark the event
/// confidential.
ParsedEvent parseEventIcs(
  String text, {
  required String id,
  required tz.Location location,
  CalendarEvent? existing,
  bool allowConfidential = true,
}) {
  final root = parseIcs(text);
  final calendar = root.components('VCALENDAR').firstOrNull ?? root;
  final vevents = calendar.components('VEVENT').toList();
  final masters = [
    for (final v in vevents)
      if (v.property('RECURRENCE-ID') == null) v,
  ];
  final overrides = [
    for (final v in vevents)
      if (v.property('RECURRENCE-ID') != null) v,
  ];
  if (masters.isEmpty) {
    return ParsedEvent(
      unsupported: overrides.isEmpty
          ? 'Kein Termin (VEVENT) enthalten'
          : 'Nur einzelne Termine einer Serie enthalten',
      hasOverrides: overrides.isNotEmpty,
    );
  }
  final master = masters.first;
  final uid = master.property('UID')?.value;
  final lastModified = parseIcsTime(
    master.property('LAST-MODIFIED') ?? master.property('DTSTAMP'),
    tz.UTC,
  )?.instant;
  if (masters.length > 1) {
    return ParsedEvent(
      unsupported: 'Mehrere Termine in einem Eintrag',
      uid: uid,
      lastModified: lastModified,
    );
  }

  final result = _single(
    master,
    id: id,
    location: location,
    existing: existing,
    allowConfidential: allowConfidential,
  );
  if (result.$2 != null) {
    return ParsedEvent(
      unsupported: result.$2,
      hasOverrides: overrides.isNotEmpty,
      uid: uid,
      lastModified: lastModified,
    );
  }
  var event = result.$1!;
  if (uid != null && uid != '$id@famio') {
    event = CalendarEvent.fromRecord(
      SyncRecord(
        collection: Collections.events,
        id: id,
        data: {...event.toData(), 'icalUid': uid},
        updatedAt: 0,
      ),
    );
  }

  final detached = <CalendarEvent>[];
  final skipped = <DateTime>{};
  if (event.recurrence != null) {
    for (final o in overrides) {
      final original = parseIcsTime(o.property('RECURRENCE-ID'), location);
      if (original == null) continue;
      skipped.add(_localDate(original, location));
      if (o.property('STATUS')?.value.toUpperCase() == 'CANCELLED') continue;
      final detachedId = sha1
          .convert(utf8.encode('$id|${original.instant.toIso8601String()}'))
          .toString()
          .substring(0, 32);
      final single = _single(
        o,
        id: detachedId,
        location: location,
        existing: null,
        allowConfidential: allowConfidential,
        ignoreRule: true,
      ).$1;
      if (single == null) continue;
      detached.add(
        single.copyWith(
          memberIds: event.memberIds,
          confidential: event.confidential || single.confidential,
        ),
      );
    }
  }
  if (skipped.isNotEmpty) {
    event = event.copyWith(exceptions: {...event.exceptions, ...skipped});
  }
  return ParsedEvent(
    event: event,
    detached: detached,
    hasOverrides: overrides.isNotEmpty,
    uid: uid,
    lastModified: lastModified,
  );
}

/// Converts one VEVENT; returns the event or why it is not supported.
(CalendarEvent?, String?) _single(
  IcsComponent v, {
  required String id,
  required tz.Location location,
  required CalendarEvent? existing,
  required bool allowConfidential,
  bool ignoreRule = false,
}) {
  final startTime = parseIcsTime(v.property('DTSTART'), location);
  if (startTime == null) return (null, 'Termin ohne Beginn');
  final allDay = startTime.dateOnly;
  final DateTime start;
  final DateTime end;
  if (allDay) {
    start = DateTime(
      startTime.wall.year,
      startTime.wall.month,
      startTime.wall.day,
    );
    final endTime = parseIcsTime(v.property('DTEND'), location);
    var days = endTime == null
        ? (parseIcsDuration(v.property('DURATION')?.value)?.inDays ?? 1)
        : DateTime.utc(
            endTime.wall.year,
            endTime.wall.month,
            endTime.wall.day,
          ).difference(startTime.wall).inDays;
    if (days < 1) days = 1;
    end = DateTime(start.year, start.month, start.day + days);
  } else {
    start = startTime.instant.toLocal();
    final endTime = parseIcsTime(v.property('DTEND'), location);
    final duration = parseIcsDuration(v.property('DURATION')?.value);
    var e = endTime != null
        ? endTime.instant.toLocal()
        : start.add(duration ?? Duration.zero);
    if (e.isBefore(start)) e = start;
    end = e;
  }

  Recurrence? recurrence;
  final exceptions = <DateTime>{};
  if (!ignoreRule) {
    final rules = v.all('RRULE').toList();
    if (rules.length > 1) return (null, 'Mehrere Wiederholungsregeln');
    if (v.property('RDATE') != null) {
      return (null, 'Zusätzliche Einzeltermine (RDATE)');
    }
    if (rules.isNotEmpty) {
      final parsed = _recurrence(rules.single.value, startTime, location);
      if (parsed.$2 != null) return (null, parsed.$2);
      recurrence = parsed.$1;
      for (final p in v.all('EXDATE')) {
        for (final t in parseIcsTimes(p, startTime.location)) {
          exceptions.add(_localDate(t, location));
        }
      }
    }
  }

  int? reminder;
  for (final alarm in v.components('VALARM')) {
    final trigger = alarm.property('TRIGGER');
    if (trigger == null ||
        trigger.params['VALUE'] == 'DATE-TIME' ||
        trigger.params['RELATED'] == 'END') {
      continue;
    }
    final d = parseIcsDuration(trigger.value);
    if (d == null) continue;
    reminder = -d.inMinutes;
    break;
  }

  final classValue = v.property('CLASS')?.value.toUpperCase();
  final markedConfidential =
      allowConfidential &&
      (classValue == 'PRIVATE' || classValue == 'CONFIDENTIAL');
  final title = v.property('SUMMARY')?.text.trim() ?? '';
  return (
    CalendarEvent(
      id: id,
      title: title.isEmpty ? '(Ohne Titel)' : title,
      start: start,
      end: end,
      allDay: allDay,
      location: v.property('LOCATION')?.text.trim() ?? '',
      notes: v.property('DESCRIPTION')?.text.trim() ?? '',
      memberIds: existing?.memberIds ?? const [],
      // Other apps know no lifts: kept as they were.
      bringerId: existing?.bringerId,
      pickerId: existing?.pickerId,
      countdown: existing?.countdown ?? false,
      recurrence: recurrence,
      exceptions: exceptions,
      reminderMinutes: reminder,
      // Other apps cannot see or clear Famio's flag, so it only ever gets set.
      confidential: (existing?.confidential ?? false) || markedConfidential,
    ),
    null,
  );
}

/// The family-zone date an occurrence starting at [t] falls on.
DateTime _localDate(IcsTime t, tz.Location location) {
  if (t.dateOnly) return DateTime(t.wall.year, t.wall.month, t.wall.day);
  final local = tz.TZDateTime.from(t.instant, location);
  return DateTime(local.year, local.month, local.day);
}

const _frequencies = {
  'DAILY': RecurrenceFrequency.daily,
  'WEEKLY': RecurrenceFrequency.weekly,
  'MONTHLY': RecurrenceFrequency.monthly,
  'YEARLY': RecurrenceFrequency.yearly,
};

/// Maps an RRULE onto Famio's [Recurrence], or says why it cannot.
(Recurrence?, String?) _recurrence(
  String value,
  IcsTime start,
  tz.Location location,
) {
  const unsupported = 'Diese Wiederholungsregel gibt es in Famio nicht';
  final parts = <String, String>{};
  for (final part in value.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    parts[part.substring(0, eq).toUpperCase()] = part
        .substring(eq + 1)
        .toUpperCase();
  }
  var frequency = _frequencies[parts.remove('FREQ')];
  if (frequency == null) return (null, unsupported);
  final interval = int.tryParse(parts.remove('INTERVAL') ?? '1') ?? 0;
  if (interval < 1 || interval > 999) return (null, unsupported);
  final untilText = parts.remove('UNTIL');
  final countText = parts.remove('COUNT');
  final wkst = parts.remove('WKST') ?? 'MO';

  var weekdays = <int>[];
  final byDay = parts.remove('BYDAY');
  final startWall = start.wall;
  if (byDay != null) {
    for (final code in byDay.split(',')) {
      final index = icsWeekdays.indexOf(code.trim());
      if (index < 0) return (null, unsupported); // e.g. 2TU, -1FR
      weekdays.add(index + 1);
    }
    if (frequency == RecurrenceFrequency.daily && interval == 1) {
      frequency = RecurrenceFrequency.weekly; // "every weekday"
    }
    if (frequency != RecurrenceFrequency.weekly) return (null, unsupported);
    weekdays = Recurrence.normalizeWeekdays(weekdays);
    if (weekdays.length == 1 && weekdays.single == startWall.weekday) {
      weekdays = [];
    }
    if (interval > 1 && wkst != 'MO' && weekdays.length > 1) {
      return (null, unsupported);
    }
  }
  final byMonthDay = parts.remove('BYMONTHDAY');
  if (byMonthDay != null &&
      (frequency == RecurrenceFrequency.daily ||
          frequency == RecurrenceFrequency.weekly ||
          int.tryParse(byMonthDay) != startWall.day)) {
    return (null, unsupported);
  }
  final byMonth = parts.remove('BYMONTH');
  if (byMonth != null &&
      (frequency != RecurrenceFrequency.yearly ||
          int.tryParse(byMonth) != startWall.month)) {
    return (null, unsupported);
  }
  if (parts.isNotEmpty) return (null, unsupported);

  DateTime? until;
  if (untilText != null) {
    final t = parseIcsTimes(
      IcsProperty('UNTIL', untilText),
      start.location,
    ).firstOrNull;
    if (t == null) return (null, unsupported);
    until = _localDate(t, location);
    if (!t.dateOnly && !start.dateOnly) {
      // UNTIL is an instant; Famio keeps the last day an occurrence may
      // start on. Before the series' time of day, that is the day before.
      final end = tz.TZDateTime.from(t.instant, location);
      final first = tz.TZDateTime.from(start.instant, location);
      final endSeconds = end.hour * 3600 + end.minute * 60 + end.second;
      final startSeconds = first.hour * 3600 + first.minute * 60 + first.second;
      if (endSeconds < startSeconds) {
        until = DateTime(until.year, until.month, until.day - 1);
      }
    }
  } else if (countText != null) {
    final count = int.tryParse(countText);
    if (count == null || count < 1) return (null, unsupported);
    final last = _nthWall(value, start, count);
    if (last == null) return (null, unsupported);
    until = DateTime(last.year, last.month, last.day);
  }
  return (
    Recurrence(frequency, interval: interval, until: until, weekdays: weekdays),
    null,
  );
}

/// Wall-clock date of the [count]th occurrence (for COUNT → UNTIL).
DateTime? _nthWall(String rrule, IcsTime start, int count) {
  try {
    final rule = RecurrenceRule.fromString('RRULE:$rrule');
    return rule.getInstances(start: start.wall).skip(count - 1).firstOrNull;
  } catch (_) {
    return null;
  }
}

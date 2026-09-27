import 'package:famio_shared/famio_shared.dart';
import 'package:timezone/timezone.dart' as tz;

import 'ics.dart';

/// Renders Famio events as an iCalendar feed for subscription in Google
/// Calendar, Apple Calendar, Outlook, …
///
/// Single timed events are written in UTC. Series use [location] with TZID so
/// a weekly 19:00 appointment stays at 19:00 after daylight saving changes.
String exportIcs({
  required Iterable<(CalendarEvent, SyncRecord)> events,
  required String calendarName,
  required tz.Location location,
  required Map<String, String> memberNames,
  bool hideDetails = false,
  DateTime? now,
}) {
  final stamp = formatIcsTime((now ?? DateTime.now()).toUtc(), utc: true);
  final w = IcsWriter()
    ..begin('VCALENDAR')
    ..line('VERSION', '2.0')
    ..line('PRODID', '-//Famio//Famio Server//DE')
    ..line('CALSCALE', 'GREGORIAN')
    ..line('METHOD', 'PUBLISH')
    ..text('X-WR-CALNAME', calendarName)
    ..line('X-WR-TIMEZONE', location.name)
    // Hints for how often clients should refresh (Apple honours these).
    ..line('REFRESH-INTERVAL', 'PT15M', {'VALUE': 'DURATION'})
    ..line('X-PUBLISHED-TTL', 'PT15M');

  for (final (e, record) in events) {
    // Confidential events (e.g. doctor's appointments) never leave Famio.
    if (e.confidential) continue;
    w
      ..begin('VEVENT')
      ..line('UID', '${e.id}@famio')
      ..line('DTSTAMP', stamp)
      ..line(
        'LAST-MODIFIED',
        formatIcsTime(
          DateTime.fromMillisecondsSinceEpoch(record.updatedAt, isUtc: true),
          utc: true,
        ),
      );
    writeEventTimes(w, e, location);
    if (hideDetails) {
      w
        ..text('SUMMARY', 'Belegt')
        ..line('CLASS', 'PRIVATE')
        ..end('VEVENT');
      continue;
    }
    w.text('SUMMARY', e.title);
    w.text('LOCATION', e.location);
    final participants = [for (final id in e.memberIds) ?memberNames[id]];
    w.text(
      'DESCRIPTION',
      [
        if (e.notes.isNotEmpty) e.notes,
        participants.isEmpty
            ? 'Für: ganze Familie'
            : 'Für: ${participants.join(', ')}',
      ].join('\n\n'),
    );
    w.end('VEVENT');
  }
  w.end('VCALENDAR');
  return w.toString();
}

/// Writes DTSTART, DTEND, RRULE and EXDATE of [e]. Series use [location]
/// with TZID, so their wall-clock time survives daylight saving changes.
void writeEventTimes(IcsWriter w, CalendarEvent e, tz.Location location) {
  final rule = e.recurrence;
  if (e.allDay) {
    w
      ..line('DTSTART', formatIcsTime(e.start, dateOnly: true), {
        'VALUE': 'DATE',
      })
      ..line('DTEND', formatIcsTime(e.end, dateOnly: true), {'VALUE': 'DATE'});
    if (rule != null) {
      w.line(
        'RRULE',
        _rrule(
          rule,
          until: rule.until == null
              ? null
              : formatIcsTime(rule.until!, dateOnly: true),
        ),
      );
      if (e.exceptions.isNotEmpty) {
        w.line(
          'EXDATE',
          e.exceptions.map((d) => formatIcsTime(d, dateOnly: true)).join(','),
          {'VALUE': 'DATE'},
        );
      }
    }
    return;
  }

  if (rule == null) {
    w
      ..line('DTSTART', formatIcsTime(e.start.toUtc(), utc: true))
      ..line('DTEND', formatIcsTime(e.end.toUtc(), utc: true));
    return;
  }

  final start = tz.TZDateTime.from(e.start, location);
  final end = tz.TZDateTime.from(e.end, location);
  final zone = {'TZID': location.name};
  w
    ..line('DTSTART', formatIcsTime(start), zone)
    ..line('DTEND', formatIcsTime(end), zone);
  String? until;
  if (rule.until != null) {
    // UNTIL must be UTC when DTSTART has a zone: end of that day locally.
    final u = rule.until!;
    until = formatIcsTime(
      tz.TZDateTime(location, u.year, u.month, u.day, 23, 59, 59).toUtc(),
      utc: true,
    );
  }
  w.line('RRULE', _rrule(rule, until: until));
  if (e.exceptions.isNotEmpty) {
    w.line(
      'EXDATE',
      e.exceptions
          .map(
            (d) => formatIcsTime(
              DateTime(
                d.year,
                d.month,
                d.day,
                start.hour,
                start.minute,
                start.second,
              ),
            ),
          )
          .join(','),
      zone,
    );
  }
}

String _rrule(Recurrence rule, {String? until}) => [
  'FREQ=${rule.frequency.name.toUpperCase()}',
  if (rule.interval > 1) 'INTERVAL=${rule.interval}',
  if (until != null) 'UNTIL=$until',
  if (rule.weekdays.isNotEmpty) ...[
    'BYDAY=${rule.weekdays.map((d) => icsWeekdays[d - 1]).join(',')}',
    // Weeks start on Monday in Famio; matters for every-other-week series.
    if (rule.interval > 1) 'WKST=MO',
  ],
].join(';');

/// iCalendar weekday codes, Monday first (like [DateTime.weekday]).
const icsWeekdays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

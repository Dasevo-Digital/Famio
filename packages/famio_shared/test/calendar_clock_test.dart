import 'dart:convert';

import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as zones;
import 'package:timezone/timezone.dart' as tz;

void main() {
  // Like the server; apps only get the family's zone (see the last test).
  setUpAll(zones.initializeTimeZones);
  for (final (start, expected) in [
    (DateTime.utc(2027, 3, 27, 9), DateTime.utc(2027, 3, 28, 8)),
    (DateTime.utc(2026, 10, 24, 8), DateTime.utc(2026, 10, 25, 9)),
  ]) {
    test('family wall time survives DST from $start', () {
      final event = CalendarEvent(
        id: 'event',
        title: 'Event',
        start: start,
        end: start.add(const Duration(hours: 1)),
        recurrence: const Recurrence(RecurrenceFrequency.daily),
      ).inTimeZone('Europe/Berlin');
      final next = event.nthStart(2)!;
      expect(next.toUtc(), expected);
      expect(next.hour, 10);
      expect(
        event
            .occurrencesBetween(
              expected,
              expected.add(const Duration(hours: 2)),
            )
            .single
            .start
            .toUtc(),
        expected,
      );
    });
  }
  test(
    'all-day recurrence preserves civil dates and exclusive ends over DST',
    () {
      final event = CalendarEvent(
        id: 'event',
        title: 'Day',
        start: DateTime(2027, 3, 27),
        end: DateTime(2027, 3, 28),
        allDay: true,
        recurrence: const Recurrence(RecurrenceFrequency.daily),
      ).inTimeZone('Europe/Berlin');
      final occurrence = event
          .occurrencesBetween(
            DateTime.utc(2027, 3, 28),
            DateTime.utc(2027, 3, 28, 21),
          )
          .single;
      expect(occurrence.start.day, 28);
      expect(occurrence.end.day, 29);
      expect(occurrence.end.difference(occurrence.start).inHours, 23);
      expect(event.toData()['start'], '2027-03-27');
    },
  );
  test(
    'weekly precision and inclusive until do not create extra occurrences',
    () {
      final event = CalendarEvent(
        id: 'event',
        title: 'Event',
        start: DateTime.utc(2027, 3, 27, 9, 0, 0, 123),
        end: DateTime.utc(2027, 3, 27, 10, 0, 0, 123),
        recurrence: Recurrence(
          RecurrenceFrequency.weekly,
          weekdays: [6],
          until: DateTime(2027, 3, 27),
        ),
      ).inTimeZone('Europe/Berlin');
      expect(event.nthStart(1)!.millisecond, 123);
      expect(event.nthStart(2), isNull);
      final midnight = CalendarEvent(
        id: 'midnight',
        title: 'Midnight',
        start: DateTime(2027, 3, 27),
        end: DateTime(2027, 3, 27, 1),
        recurrence: Recurrence(
          RecurrenceFrequency.daily,
          until: DateTime(2027, 3, 27),
        ),
      ).inTimeZone('Europe/Berlin');
      expect(midnight.nthStart(2), isNull);
    },
  );
  test('apps calculate with the zone rules the server sent', () {
    final berlin = calendarZoneRules(tz.getLocation('Europe/Berlin'));
    // A link the smaller bundled database used to lack.
    final accra = calendarZoneRules(tz.getLocation('Africa/Accra'));
    expect(berlin['key'], isNot(accra['key']));
    expect(
      calendarZoneRules(tz.getLocation('Europe/Berlin'))['key'],
      berlin['key'],
    );
    final sent = (jsonDecode(jsonEncode(berlin)) as Map)
        .cast<String, Object?>();
    tz.timeZoneDatabase.clear();
    addTearDown(zones.initializeTimeZones);
    expect(calendarLocation('Europe/Berlin'), isNull);
    expect(
      registerCalendarZone({
        ...sent,
        'zone': [99],
      }),
      isFalse,
    );
    expect(registerCalendarZone({...sent, 'zones': 'CET'}), isFalse);
    expect(calendarLocation('Europe/Berlin'), isNull);
    expect(registerCalendarZone(sent), isTrue);
    expect(
      calendarZoneRules(calendarLocation('Europe/Berlin')!)['key'],
      berlin['key'],
    );
    final event = CalendarEvent(
      id: 'event',
      title: 'Event',
      start: DateTime.utc(2027, 3, 27, 9),
      end: DateTime.utc(2027, 3, 27, 10),
      recurrence: const Recurrence(RecurrenceFrequency.daily),
    ).inTimeZone('Europe/Berlin');
    expect(event.nthStart(2)!.toUtc(), DateTime.utc(2027, 3, 28, 8));
    expect(
      const FamilyCalendar(
        'Europe/Berlin',
      ).today(DateTime.utc(2026, 10, 28, 23, 30)).toUtc(),
      DateTime.utc(2026, 10, 28, 23),
    );
  });
}

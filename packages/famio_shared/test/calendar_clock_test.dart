import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
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
}

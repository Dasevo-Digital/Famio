import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

CalendarEvent event({
  required DateTime start,
  Duration length = const Duration(hours: 1),
  bool allDay = false,
  Recurrence? recurrence,
  Set<DateTime> exceptions = const {},
}) => CalendarEvent(
  id: 'e',
  title: 'Test',
  start: start,
  end: start.add(length),
  allDay: allDay,
  recurrence: recurrence,
  exceptions: exceptions,
);

List<DateTime> starts(CalendarEvent e, DateTime from, DateTime to) => [
  for (final o in e.occurrencesBetween(from, to)) o.start,
];

void main() {
  test('single event overlaps window', () {
    final e = event(
      start: DateTime(2026, 10, 1, 23),
      length: const Duration(hours: 2),
    );
    expect(starts(e, DateTime(2026, 10, 2), DateTime(2026, 10, 3)), [
      DateTime(2026, 10, 1, 23),
    ]);
    expect(starts(e, DateTime(2026, 10, 3), DateTime(2026, 10, 4)), isEmpty);
  });

  test('weekly series keeps local wall time across DST', () {
    // Europe switches to winter time on 25 Oct 2026.
    final e = event(
      start: DateTime(2026, 10, 20, 19),
      recurrence: const Recurrence(RecurrenceFrequency.weekly),
    );
    final result = starts(e, DateTime(2026, 10, 1), DateTime(2026, 11, 5));
    expect(result, [
      DateTime(2026, 10, 20, 19),
      DateTime(2026, 10, 27, 19),
      DateTime(2026, 11, 3, 19),
    ]);
  });

  test('every second week with until and exceptions', () {
    final e = event(
      start: DateTime(2026, 1, 5, 8),
      recurrence: Recurrence(
        RecurrenceFrequency.weekly,
        interval: 2,
        until: DateTime(2026, 2, 16),
      ),
      exceptions: {DateTime(2026, 2, 2)},
    );
    expect(starts(e, DateTime(2026, 1, 1), DateTime(2026, 12, 31)), [
      DateTime(2026, 1, 5, 8),
      DateTime(2026, 1, 19, 8),
      DateTime(2026, 2, 16, 8), // until is inclusive, 2 Feb is skipped
    ]);
  });

  test('monthly on the 31st skips short months', () {
    final e = event(
      start: DateTime(2026, 1, 31, 10),
      recurrence: const Recurrence(RecurrenceFrequency.monthly),
    );
    expect(starts(e, DateTime(2026, 1, 1), DateTime(2026, 6, 1)), [
      DateTime(2026, 1, 31, 10),
      DateTime(2026, 3, 31, 10),
      DateTime(2026, 5, 31, 10),
    ]);
  });

  test('yearly birthday on 29 Feb only in leap years', () {
    final e = event(
      start: DateTime(2024, 2, 29),
      length: const Duration(days: 1),
      allDay: true,
      recurrence: const Recurrence(RecurrenceFrequency.yearly),
    );
    expect(starts(e, DateTime(2025, 1, 1), DateTime(2029, 1, 1)), [
      DateTime(2028, 2, 29),
    ]);
  });

  test('old daily series is expanded quickly and correctly', () {
    final e = event(
      start: DateTime(2000, 1, 1, 7),
      recurrence: const Recurrence(RecurrenceFrequency.daily),
    );
    final result = starts(e, DateTime(2026, 10, 1), DateTime(2026, 10, 4));
    expect(result, [
      DateTime(2026, 10, 1, 7),
      DateTime(2026, 10, 2, 7),
      DateTime(2026, 10, 3, 7),
    ]);
  });

  test('multi-day all-day event keeps its length per occurrence', () {
    final e = event(
      start: DateTime(2026, 7, 1),
      length: const Duration(days: 3),
      allDay: true,
      recurrence: const Recurrence(RecurrenceFrequency.yearly),
    );
    final o = e
        .occurrencesBetween(DateTime(2027, 7, 3), DateTime(2027, 7, 4))
        .single;
    expect(o.start, DateTime(2027, 7, 1));
    expect(o.end, DateTime(2027, 7, 4));
  });

  test('record roundtrip for timed and all-day events', () {
    final timed = CalendarEvent(
      id: 'a',
      title: 'Elternabend',
      start: DateTime(2026, 11, 3, 19, 30),
      end: DateTime(2026, 11, 3, 21),
      memberIds: const ['m1'],
      recurrence: Recurrence(
        RecurrenceFrequency.monthly,
        until: DateTime(2027, 6, 30),
      ),
      exceptions: {DateTime(2026, 12, 3)},
      reminderMinutes: 30,
    );
    SyncRecord rec(CalendarEvent e) => SyncRecord.fromJson(
      SyncRecord(
        collection: Collections.events,
        id: e.id,
        data: e.toData(),
        updatedAt: 1,
      ).toJson(),
    );
    final back = CalendarEvent.fromRecord(rec(timed));
    expect(back.start, timed.start);
    expect(back.end, timed.end);
    expect(back.recurrence, timed.recurrence);
    expect(back.exceptions, timed.exceptions);
    expect(back.reminderMinutes, 30);
    expect(back.involves('m1'), isTrue);
    expect(back.involves('m2'), isFalse);

    final allDay = CalendarEvent(
      id: 'b',
      title: 'Urlaub',
      start: DateTime(2026, 8, 1),
      end: DateTime(2026, 8, 15),
      allDay: true,
    );
    expect(allDay.toData()['start'], '2026-08-01');
    expect(CalendarEvent.fromRecord(rec(allDay)).end, DateTime(2026, 8, 15));
  });

  test('weekly series on several weekdays', () {
    // Tuesday 1 Sep 2026, 17:00; Tuesdays and Thursdays every other week.
    final e = event(
      start: DateTime(2026, 9, 1, 17),
      recurrence: const Recurrence(
        RecurrenceFrequency.weekly,
        interval: 2,
        weekdays: [2, 4],
      ),
      exceptions: {DateTime(2026, 9, 17)},
    );
    expect(starts(e, DateTime(2026, 9, 1), DateTime(2026, 10, 1)), [
      DateTime(2026, 9, 1, 17),
      DateTime(2026, 9, 3, 17),
      DateTime(2026, 9, 15, 17),
      DateTime(2026, 9, 29, 17),
    ]);
    // Far in the future the skip-ahead still lands on the right weeks.
    expect(starts(e, DateTime(2027, 9, 6), DateTime(2027, 9, 20)), [
      DateTime(2027, 9, 14, 17),
      DateTime(2027, 9, 16, 17),
    ]);
    expect(e.nthStart(3), DateTime(2026, 9, 15, 17));
  });

  test('weekdays before the first start are skipped', () {
    // Wednesday start with Monday and Wednesday: first week only Wednesday.
    final e = event(
      start: DateTime(2026, 9, 2, 8),
      recurrence: const Recurrence(
        RecurrenceFrequency.weekly,
        weekdays: [1, 3],
      ),
    );
    expect(starts(e, DateTime(2026, 8, 30), DateTime(2026, 9, 10)), [
      DateTime(2026, 9, 2, 8),
      DateTime(2026, 9, 7, 8),
      DateTime(2026, 9, 9, 8),
    ]);
  });

  test('weekdays and ical uid survive a round trip', () {
    final e = CalendarEvent(
      id: 'x',
      title: 'Training',
      start: DateTime(2026, 9, 1, 17),
      end: DateTime(2026, 9, 1, 18),
      recurrence: const Recurrence(
        RecurrenceFrequency.weekly,
        weekdays: [4, 2, 2],
      ),
      icalUid: 'ABC-123',
    );
    final back = CalendarEvent.fromRecord(
      SyncRecord(collection: 'events', id: 'x', data: e.toData(), updatedAt: 1),
    );
    expect(back.recurrence!.weekdays, [2, 4]);
    expect(back.uid, 'ABC-123');
    expect(back.withId('y').uid, 'y@famio');
  });
}

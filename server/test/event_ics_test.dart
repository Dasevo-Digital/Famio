import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/calendar/event_ics.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

String wrap(String body) =>
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:x\r\n'
    '$body\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';

void main() {
  late tz.Location berlin;
  setUpAll(() {
    FamioServerApp.initTimeZones();
    berlin = tz.getLocation('Europe/Berlin');
  });

  ParsedEvent parse(String body) =>
      parseEventIcs(wrap(body), id: 'x', location: berlin);

  test('UNTIL at midnight keeps the last day of the series', () {
    final e = parse(
      'DTSTART;TZID=Europe/Berlin:20261006T170000\r\n'
      'DTEND;TZID=Europe/Berlin:20261006T180000\r\n'
      'RRULE:FREQ=WEEKLY;BYDAY=TU,TH;UNTIL=20261231T230000Z',
    ).event!;
    expect(e.recurrence!.until, DateTime(2026, 12, 31));
    // Written back, the series ends on the same day.
    final ics = eventToIcs(e, location: berlin, updatedAt: 0);
    expect(ics, contains('UNTIL=20261231T225959Z'));
  });

  test('every weekday becomes a weekly series on five days', () {
    final e = parse(
      'DTSTART:20261005T060000Z\r\nDTEND:20261005T063000Z\r\n'
      'RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR;COUNT=7',
    ).event!;
    expect(e.recurrence!.frequency, RecurrenceFrequency.weekly);
    expect(e.recurrence!.weekdays, [1, 2, 3, 4, 5]);
    // Seven workdays from Monday 5 October: until Tuesday 13 October.
    expect(e.recurrence!.until, DateTime(2026, 10, 13));
  });

  test('rules without an equivalent are reported', () {
    for (final rule in [
      'FREQ=MONTHLY;BYDAY=2TU',
      'FREQ=YEARLY;BYMONTH=3,9',
      'FREQ=WEEKLY;BYHOUR=9,17',
      'FREQ=MONTHLY;BYSETPOS=-1;BYDAY=FR',
    ]) {
      final parsed = parse(
        'DTSTART:20261013T170000Z\r\nDTEND:20261013T180000Z\r\nRRULE:$rule',
      );
      expect(parsed.event, isNull, reason: rule);
      expect(parsed.unsupported, contains('Wiederholungsregel'));
    }
  });

  test('all-day events and reminders', () {
    final e = parse(
      'DTSTART;VALUE=DATE:20261224\r\nDTEND;VALUE=DATE:20261227\r\n'
      'SUMMARY:Weihnachten bei Oma\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\n'
      'TRIGGER:-PT15H\r\nEND:VALARM',
    ).event!;
    expect(e.allDay, isTrue);
    expect(e.start, DateTime(2026, 12, 24));
    expect(e.end, DateTime(2026, 12, 27));
    // 9:00 on the day before.
    expect(e.reminderMinutes, 900);
    final ics = eventToIcs(e, location: berlin, updatedAt: 0);
    expect(ics, contains('DTSTART;VALUE=DATE:20261224'));
    expect(ics, contains('TRIGGER:-PT15H'));
  });

  test('private events are only marked confidential when allowed', () {
    const body =
        'DTSTART:20261013T170000Z\r\nDTEND:20261013T180000Z\r\nCLASS:PRIVATE';
    expect(parse(body).event!.confidential, isTrue);
    expect(
      parseEventIcs(
        wrap(body),
        id: 'x',
        location: berlin,
        allowConfidential: false,
      ).event!.confidential,
      isFalse,
    );
  });
}

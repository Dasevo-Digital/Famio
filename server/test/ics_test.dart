import 'package:famio_server/src/calendar/ics.dart';
import 'package:famio_server/src/calendar/ics_export.dart';
import 'package:famio_server/src/calendar/ics_import.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const googleFeed = '''BEGIN:VCALENDAR\r
PRODID:-//Google Inc//Google Calendar 70.9054//EN\r
VERSION:2.0\r
X-WR-CALNAME:Schule\r
X-WR-TIMEZONE:Europe/Berlin\r
BEGIN:VTIMEZONE\r
TZID:Europe/Berlin\r
END:VTIMEZONE\r
BEGIN:VEVENT\r
DTSTART;TZID=Europe/Berlin:20260908T190000\r
DTEND;TZID=Europe/Berlin:20260908T203000\r
RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20261231T225959Z\r
EXDATE;TZID=Europe/Berlin:20261110T190000\r
UID:elternrat@google.com\r
SUMMARY:Elternrat\\, Klasse 3b\r
LOCATION:Grundschule\\; Raum 12\r
DESCRIPTION:Bitte mitbringen:\\nProtokoll vom letzten Mal und eine sehr lang\r
 e Liste mit Themen\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;TZID=Europe/Berlin:20261013T200000\r
DTEND;TZID=Europe/Berlin:20261013T213000\r
RECURRENCE-ID;TZID=Europe/Berlin:20261013T190000\r
UID:elternrat@google.com\r
SUMMARY:Elternrat (verschoben)\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;VALUE=DATE:20261026\r
DTEND;VALUE=DATE:20261031\r
UID:herbstferien@google.com\r
SUMMARY:Herbstferien\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART:20261001T080000Z\r
DURATION:PT45M\r
UID:utc@google.com\r
SUMMARY:Zahnarzt\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART:20261002T080000Z\r
DTEND:20261002T090000Z\r
UID:cancelled@google.com\r
STATUS:CANCELLED\r
SUMMARY:Abgesagt\r
END:VEVENT\r
BEGIN:VEVENT\r
DTSTART;TZID=W. Europe Standard Time:20261020T070000\r
DTEND;TZID=W. Europe Standard Time:20261020T080000\r
RRULE:FREQ=WEEKLY;COUNT=3\r
UID:outlook@example.com\r
SUMMARY:Frühsport\r
END:VEVENT\r
END:VCALENDAR\r
''';

void main() {
  late tz.Location berlin;

  setUpAll(() {
    tzdata.initializeTimeZones();
    berlin = tz.getLocation('Europe/Berlin');
  });

  DateTime inBerlin(int y, int m, int d, [int h = 0, int min = 0]) =>
      tz.TZDateTime(berlin, y, m, d, h, min).toUtc();

  List<CalendarEvent> import(String text) => importIcs(
    text,
    sourceId: 'sub1',
    fallback: berlin,
    from: DateTime.utc(2026, 9, 1),
    to: DateTime.utc(2027, 1, 1),
  )..sort((a, b) => a.start.compareTo(b.start));

  test('parses lines, parameters, folding and escapes', () {
    final root = parseIcs(googleFeed);
    final event = root.children.single.components('VEVENT').first;
    expect(event.property('SUMMARY')!.text, 'Elternrat, Klasse 3b');
    expect(event.property('LOCATION')!.text, 'Grundschule; Raum 12');
    expect(
      event.property('DESCRIPTION')!.text,
      'Bitte mitbringen:\nProtokoll vom letzten Mal und eine sehr lange Liste mit Themen',
    );
    expect(event.property('DTSTART')!.params['TZID'], 'Europe/Berlin');
  });

  test('imports a Google-style feed with series, overrides and exdates', () {
    final events = import(googleFeed);
    String show(CalendarEvent e) => '${e.title} ${e.start.toIso8601String()}';

    final elternrat = events
        .where((e) => e.title.startsWith('Elternrat'))
        .toList();
    expect(elternrat.map(show), [
      'Elternrat, Klasse 3b ${inBerlin(2026, 9, 8, 19).toIso8601String()}',
      // 13 Oct was moved to 20:00; 10 Nov is excluded.
      'Elternrat (verschoben) ${inBerlin(2026, 10, 13, 20).toIso8601String()}',
      // 8 Dec is after the switch to winter time and still at 19:00 local.
      'Elternrat, Klasse 3b ${inBerlin(2026, 12, 8, 19).toIso8601String()}',
    ]);
    expect(elternrat.first.end, inBerlin(2026, 9, 8, 20, 30));

    final ferien = events.singleWhere((e) => e.title == 'Herbstferien');
    expect(ferien.allDay, isTrue);
    expect(ferien.toData()['start'], '2026-10-26');
    expect(ferien.toData()['end'], '2026-10-31');

    final zahnarzt = events.singleWhere((e) => e.title == 'Zahnarzt');
    expect(
      zahnarzt.end.difference(zahnarzt.start),
      const Duration(minutes: 45),
    );

    expect(events.where((e) => e.title == 'Abgesagt'), isEmpty);

    // Windows zone names map to IANA; the series crosses the DST change.
    expect(events.where((e) => e.title == 'Frühsport').map((e) => e.start), [
      inBerlin(2026, 10, 20, 7),
      inBerlin(2026, 10, 27, 7),
      inBerlin(2026, 11, 3, 7),
    ]);
    expect(events.every((e) => e.sourceId == 'sub1'), isTrue);
  });

  test('ids are stable across imports and differ per occurrence', () {
    final first = import(googleFeed).map((e) => e.id).toList();
    final second = import(googleFeed).map((e) => e.id).toList();
    expect(second, first);
    expect(first.toSet().length, first.length);
  });

  test('old daily series only expands the window', () {
    const feed = '''BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART;TZID=Europe/Berlin:19900101T070000
DTEND;TZID=Europe/Berlin:19900101T073000
RRULE:FREQ=DAILY
UID:daily
SUMMARY:Täglich
END:VEVENT
END:VCALENDAR''';
    final events = importIcs(
      feed,
      sourceId: 's',
      fallback: berlin,
      from: DateTime.utc(2026, 10, 1),
      to: DateTime.utc(2026, 10, 4),
    );
    expect(events.map((e) => e.start), [
      inBerlin(2026, 10, 1, 7),
      inBerlin(2026, 10, 2, 7),
      inBerlin(2026, 10, 3, 7),
    ]);
  });

  test('Famio export survives a round trip through the importer', () {
    final weekly = CalendarEvent(
      id: 'w',
      title: 'Training',
      start: inBerlin(2026, 10, 6, 17, 30).toLocal(),
      end: inBerlin(2026, 10, 6, 19).toLocal(),
      recurrence: Recurrence(
        RecurrenceFrequency.weekly,
        until: DateTime(2026, 11, 10),
      ),
      exceptions: {DateTime(2026, 10, 20)},
      memberIds: const ['kid'],
      notes: 'Sporttasche!',
    );
    final holiday = CalendarEvent(
      id: 'h',
      title: 'Urlaub',
      start: DateTime(2026, 12, 23),
      end: DateTime(2027, 1, 2),
      allDay: true,
    );
    final single = CalendarEvent(
      id: 's',
      title: 'Arzt',
      start: inBerlin(2026, 10, 2, 9).toLocal(),
      end: inBerlin(2026, 10, 2, 10).toLocal(),
    );
    SyncRecord rec(CalendarEvent e) => SyncRecord(
      collection: Collections.events,
      id: e.id,
      data: e.toData(),
      updatedAt: DateTime.utc(2026, 9, 26).millisecondsSinceEpoch,
    );
    final ics = exportIcs(
      events: [
        for (final e in [weekly, holiday, single]) (e, rec(e)),
      ],
      calendarName: 'Famio',
      location: berlin,
      memberNames: const {'kid': 'Lena'},
      now: DateTime.utc(2026, 9, 26),
    );

    expect(ics, contains('DTSTART;TZID=Europe/Berlin:20261006T173000'));
    expect(ics, contains('RRULE:FREQ=WEEKLY;UNTIL=20261110T225959Z'));
    expect(ics, contains('EXDATE;TZID=Europe/Berlin:20261020T173000'));
    expect(ics, contains('DTSTART;VALUE=DATE:20261223'));
    expect(ics, contains('DTSTART:20261002T070000Z'));
    expect(ics, contains('Für: Lena'));
    for (final line in ics.split('\r\n')) {
      expect(line.length, lessThanOrEqualTo(75));
    }

    final back = import(ics);
    expect(back.where((e) => e.title == 'Training').map((e) => e.start), [
      inBerlin(2026, 10, 6, 17, 30),
      inBerlin(2026, 10, 13, 17, 30),
      inBerlin(2026, 10, 27, 17, 30),
      inBerlin(2026, 11, 3, 17, 30),
      inBerlin(2026, 11, 10, 17, 30),
    ]);
    expect(
      back.singleWhere((e) => e.title == 'Arzt').start,
      inBerlin(2026, 10, 2, 9),
    );
    expect(
      back.singleWhere((e) => e.title == 'Urlaub').toData()['end'],
      '2027-01-02',
    );
  });

  test(
    'confidential events stay out, detail-free feeds show only "Belegt"',
    () {
      final doctor = CalendarEvent(
        id: 'd',
        title: 'Kinderarzt U5 Mia',
        start: DateTime.utc(2026, 10, 2, 8),
        end: DateTime.utc(2026, 10, 2, 9),
        location: 'Praxis Dr. Sonne',
        confidential: true,
      );
      final swim = CalendarEvent(
        id: 's',
        title: 'Schwimmkurs',
        start: DateTime.utc(2026, 10, 3, 8),
        end: DateTime.utc(2026, 10, 3, 9),
        location: 'Hallenbad',
        notes: 'Badekappe',
      );
      SyncRecord rec(CalendarEvent e) => SyncRecord(
        collection: Collections.events,
        id: e.id,
        data: e.toData(),
        updatedAt: 0,
      );
      String export({bool hideDetails = false}) => exportIcs(
        events: [
          for (final e in [doctor, swim]) (e, rec(e)),
        ],
        calendarName: 'Famio',
        location: berlin,
        memberNames: const {},
        hideDetails: hideDetails,
      );
      final full = export();
      expect(full, isNot(contains('Kinderarzt')));
      expect(full, isNot(contains('Praxis')));
      expect(full, contains('Schwimmkurs'));
      expect(CalendarEvent.fromRecord(rec(doctor)).confidential, isTrue);

      final busy = export(hideDetails: true);
      expect(busy, contains('SUMMARY:Belegt'));
      expect(busy, isNot(contains('Schwimmkurs')));
      expect(busy, isNot(contains('Hallenbad')));
      expect(busy, isNot(contains('Badekappe')));
      expect(busy, contains('DTSTART:20261003T080000Z'));
    },
  );
}

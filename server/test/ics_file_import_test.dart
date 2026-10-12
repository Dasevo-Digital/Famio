import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/calendar/ics_file_import.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// A school's calendar export plus an invitation, as other apps write them.
const _file = '''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Schule//Kalender//DE
BEGIN:VEVENT
UID:elternabend-2026@schule.example
DTSTART;TZID=Europe/Berlin:20261020T193000
DTEND;TZID=Europe/Berlin:20261020T210000
SUMMARY:Elternabend Klasse 3b
LOCATION:Aula
DESCRIPTION:Bitte Hausschuhe mitbringen.
END:VEVENT
BEGIN:VEVENT
UID:schwimmen@schule.example
DTSTART;TZID=Europe/Berlin:20261006T080000
DTEND;TZID=Europe/Berlin:20261006T093000
RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261222T230000Z
EXDATE;TZID=Europe/Berlin:20261103T080000
SUMMARY:Schwimmen
END:VEVENT
BEGIN:VEVENT
UID:schwimmen@schule.example
RECURRENCE-ID;TZID=Europe/Berlin:20261110T080000
DTSTART;TZID=Europe/Berlin:20261110T100000
DTEND;TZID=Europe/Berlin:20261110T113000
SUMMARY:Schwimmen (später)
END:VEVENT
BEGIN:VEVENT
UID:ferien@schule.example
DTSTART;VALUE=DATE:20261026
DTEND;VALUE=DATE:20261031
SUMMARY:Herbstferien
END:VEVENT
BEGIN:VEVENT
DTSTART;TZID=Europe/Berlin:20261115T150000
DTEND;TZID=Europe/Berlin:20261115T160000
SUMMARY:Laternenumzug
END:VEVENT
BEGIN:VEVENT
UID:foerderverein@schule.example
DTSTART;TZID=Europe/Berlin:20261030T180000
DTEND;TZID=Europe/Berlin:20261030T190000
RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=4
SUMMARY:Förderverein
END:VEVENT
END:VCALENDAR
''';

void main() {
  setUpAll(FamioServerApp.initTimeZones);

  test('series stay series, other rules become single events', () {
    final berlin = tz.getLocation('Europe/Berlin');
    final content = readIcsFile(
      _file,
      location: berlin,
      now: DateTime(2026, 10, 12),
    );
    CalendarEvent named(String title) =>
        content.events.firstWhere((e) => e.title == title);

    final evening = named('Elternabend Klasse 3b');
    expect(evening.location, 'Aula');
    expect(evening.notes, 'Bitte Hausschuhe mitbringen.');
    expect(evening.recurrence, isNull);
    expect(evening.icalUid, 'elternabend-2026@schule.example');

    final swimming = named('Schwimmen');
    expect(swimming.recurrence?.frequency, RecurrenceFrequency.weekly);
    // The cancelled and the moved Tuesday are exceptions of the series.
    expect(
      swimming.exceptions,
      containsAll([DateTime(2026, 11, 3), DateTime(2026, 11, 10)]),
    );
    expect(named('Schwimmen (später)').start.toUtc().hour, 9);

    final holidays = named('Herbstferien');
    expect(holidays.allDay, isTrue);
    expect(holidays.end.difference(holidays.start).inDays, 5);
    expect(named('Laternenumzug').title, 'Laternenumzug');

    // "Last Friday of the month" has no Famio rule: single events instead.
    expect(content.expanded, 1);
    final friday = content.events.where((e) => e.title == 'Förderverein');
    expect(friday, hasLength(4));
    expect(
      friday.every((e) => e.recurrence == null && e.sourceId == null),
      isTrue,
    );
    expect(content.skipped, isEmpty);

    // A second import of the same file updates the same events.
    final again = readIcsFile(
      _file,
      location: berlin,
      now: DateTime(2026, 10, 12),
    );
    expect(
      {for (final e in again.events) e.id},
      {for (final e in content.events) e.id},
    );
  });

  test('the app sends a file and gets the events, nothing is saved', () async {
    final app = FamioServerApp.inMemory();
    final admin = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      passwordHash: 'x',
      isAdmin: true,
    );
    final token = app.accounts.createSession(admin.id, method: 'password');
    Future<Response> post(Object body) async => app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/calendar/ics-file'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
      ),
    );
    final r = await post({'ics': _file});
    expect(r.statusCode, 200);
    final json = jsonDecode(await r.readAsString()) as Map;
    final events = [
      for (final e in json['events'] as List)
        CalendarEvent.fromRecord(
          SyncRecord(
            collection: Collections.events,
            id: (e as Map)['id'] as String,
            data: (e['data'] as Map).cast(),
            updatedAt: 0,
          ),
        ),
    ];
    expect(events.map((e) => e.title), contains('Elternabend Klasse 3b'));
    expect(app.records.all(Collections.events), isEmpty);

    final empty = await post({
      'ics': 'BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n',
    });
    expect(empty.statusCode, 400);
    expect((await post({'ics': ''})).statusCode, 400);
    await app.close();
  });
}

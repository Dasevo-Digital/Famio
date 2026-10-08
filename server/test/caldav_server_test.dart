import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// Series as Apple Calendar writes it: Tuesday and Thursday, 17:00 Berlin
/// time, a reminder, one moved occurrence and one skipped date.
const appleSeries = '''
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//macOS 15.0//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Europe/Berlin
BEGIN:DAYLIGHT
TZOFFSETFROM:+0100
RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
DTSTART:19810329T020000
TZNAME:MESZ
TZOFFSETTO:+0200
END:DAYLIGHT
BEGIN:STANDARD
TZOFFSETFROM:+0200
RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
DTSTART:19961027T030000
TZNAME:MEZ
TZOFFSETTO:+0100
END:STANDARD
END:VTIMEZONE
BEGIN:VEVENT
UID:6E1C5E2A-APPLE-UID
DTSTAMP:20260901T100000Z
DTSTART;TZID=Europe/Berlin:20260901T170000
DTEND;TZID=Europe/Berlin:20260901T183000
RRULE:FREQ=WEEKLY;COUNT=6;BYDAY=TU,TH
EXDATE;TZID=Europe/Berlin:20260908T170000
SUMMARY:Fußballtraining
LOCATION:Sportplatz
BEGIN:VALARM
ACTION:DISPLAY
DESCRIPTION:Reminder
TRIGGER:-PT30M
END:VALARM
END:VEVENT
BEGIN:VEVENT
UID:6E1C5E2A-APPLE-UID
DTSTAMP:20260901T100000Z
RECURRENCE-ID;TZID=Europe/Berlin:20260903T170000
DTSTART;TZID=Europe/Berlin:20260903T180000
DTEND;TZID=Europe/Berlin:20260903T193000
SUMMARY:Fußballtraining (später)
END:VEVENT
END:VCALENDAR
''';

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late String token;
  late String memberId;
  late String secret;

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final login = await http.post(
      base.resolve('api/auth/setup'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': 'mama',
        'password': 'geheim123',
        'setupCode': app.setupCode,
      }),
    );
    final body = jsonDecode(login.body) as Map;
    token = body['token'] as String;
    memberId = (body['member'] as Map)['id'] as String;
    final created = await http.post(
      base.resolve('api/me/app-passwords'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode({'name': 'iPhone'}),
    );
    expect(created.statusCode, 201);
    secret = (jsonDecode(created.body) as Map)['secret'] as String;
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  Future<http.Response> dav(
    String method,
    String path, {
    String? body,
    Map<String, String> headers = const {},
    String? password,
    String user = 'mama',
  }) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] =
          'Basic ${base64.encode(utf8.encode('$user:${password ?? secret}'))}'
      ..headers.addAll(headers);
    if (body != null) {
      request.headers['content-type'] = path.endsWith('.ics')
          ? 'text/calendar; charset=utf-8'
          : 'application/xml; charset=utf-8';
      request.body = body;
    }
    return http.Response.fromStream(await request.send());
  }

  Future<void> sync(List<SyncRecord> changes) async {
    final r = await http.post(
      base.resolve('api/sync'),
      headers: {
        'authorization': 'Bearer $token',
        'content-type': 'application/json',
      },
      body: jsonEncode(SyncRequest(since: 0, changes: changes).toJson()),
    );
    expect(r.statusCode, 200);
  }

  List<CalendarEvent> events() => [
    for (final r in app.records.all(Collections.events))
      CalendarEvent.fromRecord(r),
  ];

  test('discovery leads from the site root to the calendar', () async {
    final wellKnown = await dav('PROPFIND', '.well-known/caldav');
    expect(wellKnown.statusCode, 301);
    expect(wellKnown.headers['location'], '/dav/');

    final root = await dav(
      'PROPFIND',
      '',
      body:
          '<propfind xmlns="DAV:"><prop><current-user-principal/></prop>'
          '</propfind>',
      headers: {'depth': '0'},
    );
    expect(root.statusCode, 207);
    expect(root.body, contains('<d:href>/dav/principals/mama/</d:href>'));

    final principal = await dav(
      'PROPFIND',
      'dav/principals/mama/',
      body:
          '<propfind xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
          '<prop><C:calendar-home-set/><C:calendar-user-address-set/></prop>'
          '</propfind>',
      headers: {'depth': '0'},
    );
    expect(principal.body, contains('/dav/calendars/mama/'));
    // Unknown properties are reported as missing, not as an error.
    expect(principal.body, contains('404 Not Found'));

    final home = await dav('PROPFIND', 'dav/calendars/mama/');
    expect(home.body, contains('/dav/calendars/mama/famio/'));
    expect(home.body, contains('<c:comp name="VEVENT"/>'));
    expect(home.body, contains('<d:write/>'));
  });

  test('wrong or missing credentials are refused', () async {
    final none = await http.Request('PROPFIND', base.resolve('dav/')).send();
    expect(none.statusCode, 401);
    expect(none.headers['www-authenticate'], startsWith('Basic'));
    // The login password is not an app password.
    final login = await dav('PROPFIND', 'dav/', password: 'geheim123');
    expect(login.statusCode, 401);
    // Somebody else's calendar.
    final other = await dav('PROPFIND', 'dav/calendars/papa/famio/');
    expect(other.statusCode, 403);
    // Dashes and case do not matter when typing the password.
    final typed = await dav(
      'PROPFIND',
      'dav/',
      password: secret.replaceAll('-', '').toUpperCase(),
    );
    expect(typed.statusCode, 207);
  });

  test('famio events can be listed and fetched', () async {
    final start = DateTime.utc(2026, 10, 5, 8);
    await sync([
      SyncRecord(
        collection: Collections.events,
        id: 'arzt',
        data: CalendarEvent(
          id: 'arzt',
          title: 'Kinderarzt',
          start: start,
          end: start.add(const Duration(hours: 1)),
          confidential: true,
        ).toData(),
        updatedAt: 1,
      ),
      SyncRecord(
        collection: Collections.events,
        id: 'kita',
        data: CalendarEvent(
          id: 'kita',
          title: 'Kita-Fest',
          start: start,
          end: start.add(const Duration(hours: 3)),
          recurrence: const Recurrence(RecurrenceFrequency.yearly),
          reminderMinutes: 60,
        ).toData(),
        updatedAt: 1,
      ),
    ]);

    final list = await dav(
      'PROPFIND',
      'dav/calendars/mama/famio/',
      body: '<propfind xmlns="DAV:"><prop><getetag/></prop></propfind>',
      headers: {'depth': '1'},
    );
    expect(list.body, contains('/dav/calendars/mama/famio/kita.ics'));
    // Confidential events are not shown to this app password.
    expect(list.body, isNot(contains('arzt.ics')));
    expect(
      (await dav('GET', 'dav/calendars/mama/famio/arzt.ics')).statusCode,
      404,
    );

    final get = await dav('GET', 'dav/calendars/mama/famio/kita.ics');
    expect(get.statusCode, 200);
    expect(get.headers['etag'], isNotNull);
    expect(get.body, contains('UID:kita@famio'));
    expect(get.body, contains('RRULE:FREQ=YEARLY'));
    expect(get.body, contains('BEGIN:VTIMEZONE'));
    expect(get.body, contains('TRIGGER:-PT1H'));

    final multiget = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body:
          '<C:calendar-multiget xmlns:D="DAV:" '
          'xmlns:C="urn:ietf:params:xml:ns:caldav">'
          '<D:prop><D:getetag/><C:calendar-data/></D:prop>'
          '<D:href>/dav/calendars/mama/famio/kita.ics</D:href>'
          '<D:href>/dav/calendars/mama/famio/arzt.ics</D:href>'
          '</C:calendar-multiget>',
    );
    expect(multiget.statusCode, 207);
    expect(multiget.body, contains('SUMMARY:Kita-Fest'));
    expect(multiget.body, contains('HTTP/1.1 404'));

    final query = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body:
          '<C:calendar-query xmlns:D="DAV:" '
          'xmlns:C="urn:ietf:params:xml:ns:caldav">'
          '<D:prop><D:getetag/></D:prop><C:filter>'
          '<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">'
          '<C:time-range start="20271001T000000Z" end="20271101T000000Z"/>'
          '</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>',
    );
    // The yearly series has an occurrence in October 2027.
    expect(query.body, contains('kita.ics'));
    final empty = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body:
          '<C:calendar-query xmlns:D="DAV:" '
          'xmlns:C="urn:ietf:params:xml:ns:caldav">'
          '<D:prop><D:getetag/></D:prop><C:filter>'
          '<C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">'
          '<C:time-range start="20250101T000000Z" end="20250201T000000Z"/>'
          '</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>',
    );
    expect(empty.body, isNot(contains('kita.ics')));
  });

  test('an app creates, edits and deletes an event', () async {
    const path = 'dav/calendars/mama/famio/6E1C5E2A-APPLE-UID.ics';
    final created = await dav(
      'PUT',
      path,
      body: appleSeries,
      headers: {'if-none-match': '*'},
    );
    expect(created.statusCode, 201, reason: created.body);
    // Created again with If-None-Match: already there.
    final again = await dav(
      'PUT',
      path,
      body: appleSeries,
      headers: {'if-none-match': '*'},
    );
    expect(again.statusCode, 412);

    final series = events().firstWhere((e) => e.id == '6E1C5E2A-APPLE-UID');
    expect(series.title, 'Fußballtraining');
    expect(series.uid, '6E1C5E2A-APPLE-UID');
    expect(series.recurrence!.weekdays, [2, 4]);
    // COUNT=6 from Tue 1 Sep: 1, 3, 8, 10, 15, 17 September.
    expect(series.recurrence!.until, DateTime(2026, 9, 17));
    expect(series.reminderMinutes, 30);
    expect(series.exceptions, {DateTime(2026, 9, 8), DateTime(2026, 9, 3)});
    // The moved occurrence became an event of its own.
    final moved = events().firstWhere((e) => e.title.contains('später'));
    expect(moved.start, DateTime.utc(2026, 9, 3, 16).toLocal());
    expect(moved.recurrence, isNull);

    final get = await dav('GET', path);
    expect(get.body, contains('UID:6E1C5E2A-APPLE-UID'));
    expect(get.body, contains('BYDAY=TU,TH'));
    final etag = get.headers['etag']!;

    // A stale ETag loses; the current one wins.
    final stale = await dav(
      'PUT',
      path,
      body: appleSeries.replaceAll('Fußballtraining\n', 'Training\n'),
      headers: {'if-match': '"999"'},
    );
    expect(stale.statusCode, 412);
    final edited = await dav(
      'PUT',
      path,
      body: appleSeries.replaceFirst(
        'SUMMARY:Fußballtraining\n',
        'SUMMARY:Training\n',
      ),
      headers: {'if-match': etag},
    );
    expect(edited.statusCode, 204);
    expect(
      events().firstWhere((e) => e.id == '6E1C5E2A-APPLE-UID').title,
      'Training',
    );

    final deleted = await dav('DELETE', path);
    expect(deleted.statusCode, 204);
    expect(events().where((e) => e.id == '6E1C5E2A-APPLE-UID'), isEmpty);
    expect((await dav('GET', path)).statusCode, 404);
  });

  test('participants and privacy set in famio survive edits', () async {
    final start = DateTime.utc(2026, 11, 2, 14);
    await sync([
      SyncRecord(
        collection: Collections.events,
        id: 'schule',
        data: {
          ...CalendarEvent(
            id: 'schule',
            title: 'Elterngespräch',
            start: start,
            end: start.add(const Duration(hours: 1)),
            memberIds: [memberId],
          ).toData(),
          SyncRecord.visibilityKey: [memberId],
        },
        updatedAt: 1,
      ),
    ]);
    final get = await dav('GET', 'dav/calendars/mama/famio/schule.ics');
    final put = await dav(
      'PUT',
      'dav/calendars/mama/famio/schule.ics',
      body: get.body.replaceAll('Elterngespräch', 'Elterngespräch Schule'),
      headers: {'if-match': get.headers['etag']!},
    );
    expect(put.statusCode, 204);
    final record = app.records.get(Collections.events, 'schule')!;
    expect(record.visibleTo, [memberId]);
    final e = CalendarEvent.fromRecord(record);
    expect(e.title, 'Elterngespräch Schule');
    expect(e.memberIds, [memberId]);
    expect(e.icalUid, isNull);
  });

  test('unsupported rules are refused with a reason', () async {
    final response = await dav(
      'PUT',
      'dav/calendars/mama/famio/monthly.ics',
      body: '''
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:monthly
DTSTART:20260908T170000Z
DTEND:20260908T180000Z
RRULE:FREQ=MONTHLY;BYDAY=2TU
SUMMARY:Elternbeirat
END:VEVENT
END:VCALENDAR
''',
    );
    expect(response.statusCode, 403);
    expect(response.body, contains('Wiederholungsregel'));
  });

  test('sync-collection reports changes and deletions', () async {
    final initial = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body:
          '<D:sync-collection xmlns:D="DAV:"><D:sync-token/>'
          '<D:sync-level>1</D:sync-level><D:prop><D:getetag/></D:prop>'
          '</D:sync-collection>',
    );
    expect(initial.statusCode, 207);
    final token = RegExp(
      r'<d:sync-token>([^<]+)</d:sync-token>',
    ).firstMatch(initial.body)![1]!;

    final start = DateTime.utc(2026, 12, 1, 9);
    await sync([
      SyncRecord(
        collection: Collections.events,
        id: 'neu',
        data: CalendarEvent(
          id: 'neu',
          title: 'Neu',
          start: start,
          end: start,
        ).toData(),
        updatedAt: 1,
      ),
    ]);
    String report(String t) =>
        '<D:sync-collection xmlns:D="DAV:"><D:sync-token>$t</D:sync-token>'
        '<D:sync-level>1</D:sync-level><D:prop><D:getetag/></D:prop>'
        '</D:sync-collection>';
    final changed = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body: report(token),
    );
    expect(changed.body, contains('neu.ics'));
    final token2 = RegExp(
      r'<d:sync-token>([^<]+)</d:sync-token>',
    ).firstMatch(changed.body)![1]!;

    await dav('DELETE', 'dav/calendars/mama/famio/neu.ics');
    final removed = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body: report(token2),
    );
    expect(removed.body, contains('neu.ics'));
    expect(removed.body, contains('HTTP/1.1 404'));

    final bogus = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body: report('http://famio.app/ns/sync/999999'),
    );
    expect(bogus.statusCode, 403);
    expect(bogus.body, contains('valid-sync-token'));

    // Half a year later the deletion mark is gone: an app with the old
    // token has to start over instead of missing the deletion.
    final t0 = DateTime(2026);
    app.records
      ..purgeDeleted(now: t0)
      ..purgeDeleted(now: t0.add(const Duration(days: 181)));
    final stale = await dav(
      'REPORT',
      'dav/calendars/mama/famio/',
      body: report(token2),
    );
    expect(stale.statusCode, 403);
  });

  test('app passwords can be listed and revoked', () async {
    final headers = {
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
    };
    final list =
        jsonDecode(
              (await http.get(
                base.resolve('api/me/app-passwords'),
                headers: headers,
              )).body,
            )
            as Map;
    final passwords = [
      for (final p in list['passwords'] as List)
        AppPassword.fromJson((p as Map).cast()),
    ];
    expect(passwords.single.name, 'iPhone');
    await http.delete(
      base.resolve('api/me/app-passwords/${passwords.single.id}'),
      headers: headers,
    );
    expect((await dav('PROPFIND', 'dav/')).statusCode, 401);
  });
}

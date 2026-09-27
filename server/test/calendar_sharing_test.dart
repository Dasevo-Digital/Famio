import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

String _ics(String title) {
  final start = DateTime.now().toUtc().add(const Duration(days: 2));
  String f(DateTime t) =>
      '${t.toIso8601String().replaceAll(RegExp(r'[-:]'), '').split('.').first}Z';
  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'BEGIN:VEVENT',
    'UID:$title',
    'SUMMARY:$title',
    'DTSTART:${f(start)}',
    'DTEND:${f(start.add(const Duration(hours: 1)))}',
    'END:VEVENT',
    'END:VCALENDAR',
  ].join('\r\n');
}

/// One family member talking to the server.
class _Member {
  _Member(this.base, this.token, this.id);

  final Uri base;
  final String token;
  final String id;
  int rev = 0;

  Future<Map<String, Object?>> call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await request.send());
    final decoded = jsonDecode(response.body);
    return {
      '_status': response.statusCode,
      if (decoded is Map) ...decoded.cast(),
    };
  }

  /// Local copy of what this member has received.
  final seen = <String, SyncRecord>{};

  Future<SyncResponse> sync([List<SyncRecord> changes = const []]) async {
    final response = SyncResponse.fromJson(
      await call(
        'POST',
        'api/sync',
        SyncRequest(since: rev, changes: changes).toJson(),
      ),
    );
    for (final r in response.changes) {
      r.deleted
          ? seen.remove('${r.collection}/${r.id}')
          : seen['${r.collection}/${r.id}'] = r;
    }
    rev = response.rev;
    return response;
  }

  List<String> get externalTitles => [
    for (final r in seen.values)
      if (r.collection == Collections.externalEvents) r.data['title'] as String,
  ]..sort();

  List<String> get subscriptionNames => [
    for (final r in seen.values)
      if (r.collection == Collections.calendarSubscriptions)
        r.data['name'] as String,
  ]..sort();
}

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late _Member mama; // admin
  late _Member papa;
  late _Member kind;

  Future<_Member> login(String username) async {
    final response = await http.post(
      base.resolve('api/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': 'geheim123',
        'device': 'test',
      }),
    );
    final body = jsonDecode(response.body) as Map;
    return _Member(
      base,
      body['token'] as String,
      (body['member'] as Map)['id'] as String,
    );
  }

  Future<_Member> addMember(String username) async {
    await mama.call('POST', 'api/admin/users', {
      'username': username,
      'displayName': username,
      'password': 'geheim123',
    });
    return login(username);
  }

  setUp(() async {
    app = FamioServerApp.inMemory(
      httpClient: MockClient((request) async {
        // The path names the calendar, e.g. /arbeit.ics → "arbeit".
        final title = request.url.pathSegments.last.replaceAll('.ics', '');
        return http.Response.bytes(
          utf8.encode(_ics(title)),
          200,
          headers: {'content-type': 'text/calendar'},
        );
      }),
    );
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final setup = await http.post(
      base.resolve('api/auth/setup'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': 'mama', 'password': 'geheim123'}),
    );
    final body = jsonDecode(setup.body) as Map;
    mama = _Member(
      base,
      body['token'] as String,
      (body['member'] as Map)['id'] as String,
    );
    papa = await addMember('papa');
    kind = await addMember('kind');
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  SyncRecord subscription(
    String id,
    String owner, {
    CalendarSharing sharing = const CalendarSharing.family(),
    String? name,
  }) => SyncRecord(
    collection: Collections.calendarSubscriptions,
    id: id,
    data: CalendarSubscription(
      id: id,
      name: name ?? id,
      url: 'https://example.org/$id.ics',
      ownerId: owner,
      sharing: sharing,
    ).toData(),
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );

  Future<void> syncAll() async {
    for (final m in [mama, papa, kind]) {
      await m.sync();
    }
  }

  test('a calendar is shown only to the members it is shared with', () async {
    await papa.sync([
      subscription('arbeit', papa.id, sharing: CalendarSharing.only([mama.id])),
      subscription('privat', papa.id, sharing: const CalendarSharing.private()),
      subscription('schule', papa.id),
    ]);
    await app.importer.refreshAll();
    await syncAll();

    expect(papa.externalTitles, ['arbeit', 'privat', 'schule']);
    expect(mama.externalTitles, ['arbeit', 'schule']);
    expect(kind.externalTitles, ['schule']);
    // Not even the name or address of the others' calendars reaches them.
    expect(kind.subscriptionNames, ['schule']);

    // Sharing later with the child as well.
    await papa.sync([
      subscription(
        'arbeit',
        papa.id,
        sharing: CalendarSharing.only([mama.id, kind.id]),
      ),
    ]);
    await app.importer.refreshAll();
    await kind.sync();
    expect(kind.externalTitles, ['arbeit', 'schule']);
  });

  test('only the owner may change or remove a calendar', () async {
    await papa.sync([subscription('arbeit', papa.id)]);
    final hijack = subscription(
      'arbeit',
      papa.id,
      name: 'Gekapert',
      sharing: const CalendarSharing.private(),
    );
    final answer = await mama.sync([
      hijack.copyWith(updatedAt: hijack.updatedAt + 1000),
    ]);
    expect(answer.rejected.single.data['name'], 'arbeit');
    final removal = await kind.sync([
      SyncRecord(
        collection: Collections.calendarSubscriptions,
        id: 'arbeit',
        data: const {},
        deleted: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch + 2000,
      ),
    ]);
    expect(removal.rejected, hasLength(1));
    expect(
      app.records.get(Collections.calendarSubscriptions, 'arbeit')!.deleted,
      isFalse,
    );

    // Nobody can pass a calendar off as someone else's.
    await kind.sync([subscription('fake', papa.id)]);
    expect(
      app.records
          .get(Collections.calendarSubscriptions, 'fake')!
          .data['ownerId'],
      kind.id,
    );
  });

  test('an admin chooses which shared calendars a member sees', () async {
    await papa.sync([
      subscription('arbeit', papa.id),
      subscription('schule', papa.id),
    ]);
    await app.importer.refreshAll();
    await syncAll();
    expect(kind.externalTitles, ['arbeit', 'schule']);

    var profile = await mama.call(
      'GET',
      'api/admin/users/${kind.id}/calendars',
    );
    var calendars = [
      for (final c in profile['calendars'] as List)
        MemberCalendar.fromJson((c as Map).cast()),
    ];
    expect(calendars.map((c) => c.name), unorderedEquals(['arbeit', 'schule']));
    expect(calendars.every((c) => !c.hidden && c.ownerId == papa.id), isTrue);

    // Members may not change profiles.
    final denied = await kind.call(
      'PUT',
      'api/admin/users/${kind.id}/calendars',
      {'hidden': <String>[]},
    );
    expect(denied['_status'], 403);

    profile = await mama.call('PUT', 'api/admin/users/${kind.id}/calendars', {
      'hidden': ['arbeit', 'unknown'],
    });
    calendars = [
      for (final c in profile['calendars'] as List)
        MemberCalendar.fromJson((c as Map).cast()),
    ];
    expect(calendars.firstWhere((c) => c.source == 'arbeit').hidden, isTrue);
    await syncAll();
    expect(kind.externalTitles, ['schule']);
    expect(kind.subscriptionNames, ['schule']);
    expect(mama.externalTitles, ['arbeit', 'schule']);
    // The owner always keeps their own calendar.
    expect(papa.externalTitles, ['arbeit', 'schule']);

    // A new member sees family calendars even while hidden for someone.
    final oma = await addMember('oma');
    await oma.sync();
    expect(oma.externalTitles, ['arbeit', 'schule']);

    // Switching it back on.
    await mama.call('PUT', 'api/admin/users/${kind.id}/calendars', {
      'hidden': <String>[],
    });
    await kind.sync();
    expect(kind.externalTitles, ['arbeit', 'schule']);
  });

  test('CalDAV accounts keep their sharing', () async {
    final account = app.caldav.create(
      papa.id,
      name: 'Google Papa',
      serverUrl: 'https://caldav.example.org',
      username: 'papa',
      password: 'x',
      calendarUrl: 'https://caldav.example.org/cal/',
      calendarName: 'Papa',
      sharing: CalendarSharing.only([mama.id]),
    );
    expect(account.sharing, CalendarSharing.only([mama.id]));
    expect(account.privateImport, isFalse);
    final source = CalendarAccess.caldavSource(account.id);
    expect(
      app.calendarAccess.audience(source),
      unorderedEquals([papa.id, mama.id]),
    );
    expect(app.calendarAccess.calendarsOf(mama.id).single.kind, 'caldav');
    expect(app.calendarAccess.calendarsOf(kind.id), isEmpty);

    final private = app.caldav.update(
      papa.id,
      account.id,
      sharing: const CalendarSharing.private(),
    );
    expect(private.privateImport, isTrue);
    expect(app.calendarAccess.audience(source), [papa.id]);

    app.caldav.update(
      papa.id,
      account.id,
      sharing: const CalendarSharing.family(),
    );
    expect(app.calendarAccess.audience(source), isNull);
    app.calendarAccess.setHidden(kind.id, [source]);
    expect(
      app.calendarAccess.audience(source),
      unorderedEquals([mama.id, papa.id]),
    );
  });

  test('occurrences expand series and include shared calendars', () async {
    final start = DateTime.now().add(const Duration(hours: 1));
    SyncRecord event(String id, String title, {List<String>? only}) =>
        SyncRecord(
          collection: Collections.events,
          id: id,
          data: {
            ...CalendarEvent(
              id: id,
              title: title,
              start: start,
              end: start.add(const Duration(hours: 1)),
              recurrence: id == 'turnen'
                  ? const Recurrence(RecurrenceFrequency.weekly)
                  : null,
            ).toData(),
            SyncRecord.visibilityKey: ?only,
          },
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
    await papa.sync([
      event('turnen', 'Turnen'),
      event('geheim', 'Geschenk kaufen', only: [papa.id]),
      subscription('schule', papa.id),
    ]);
    await app.importer.refreshAll();

    final from = DateTime.now().toUtc();
    final to = from.add(const Duration(days: 15));
    final answer = await kind.call(
      'GET',
      'api/calendar/occurrences?from=${from.toIso8601String()}'
          '&to=${to.toIso8601String()}',
    );
    final list = [
      for (final o in answer['occurrences'] as List)
        (o as Map).cast<String, Object?>(),
    ];
    expect(
      list.where((o) => o['title'] == 'Turnen'),
      hasLength(greaterThanOrEqualTo(2)),
    );
    expect(list.where((o) => o['title'] == 'Geschenk kaufen'), isEmpty);
    final school = list.singleWhere((o) => o['title'] == 'schule');
    expect(school['calendar'], 'schule');
    expect(school['readOnly'], isTrue);
    expect(list.first['recurring'], isTrue);

    final tooLong = await kind.call(
      'GET',
      'api/calendar/occurrences?from=${from.toIso8601String()}'
          '&to=${from.add(const Duration(days: 500)).toIso8601String()}',
    );
    expect(tooLong['_status'], 400);
  });
}

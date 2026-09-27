import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

String feed(List<String> events) =>
    ['BEGIN:VCALENDAR', 'VERSION:2.0', ...events, 'END:VCALENDAR'].join('\r\n');

String vevent(String uid, String title, DateTime start) {
  String f(DateTime t) =>
      '${t.toUtc().toIso8601String().replaceAll(RegExp(r'[-:]'), '').split('.').first}Z';
  return 'BEGIN:VEVENT\r\nUID:$uid\r\nSUMMARY:$title\r\n'
      'DTSTART:${f(start)}\r\nDTEND:${f(start.add(const Duration(hours: 1)))}\r\n'
      'END:VEVENT';
}

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late String token;
  late String memberId;

  // What the fake "Google" server currently returns.
  var remote = '';
  var remoteStatus = 200;
  var requests = <http.BaseRequest>[];

  setUp(() async {
    requests = [];
    remoteStatus = 200;
    final soon = DateTime.now().add(const Duration(days: 2));
    remote = feed([
      vevent('a', 'Schwimmkurs', soon),
      vevent('b', 'Elternabend', soon.add(const Duration(days: 1))),
    ]);
    app = FamioServerApp.inMemory(
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.headers['if-none-match'] == '"v1"' && remoteStatus == 200) {
          return http.Response('', 304);
        }
        return http.Response.bytes(
          utf8.encode(remote),
          remoteStatus,
          headers: {'etag': '"v1"', 'content-type': 'text/calendar'},
        );
      }),
    );
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final login = await http.post(
      base.resolve('api/auth/setup'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': 'mama', 'password': 'geheim123'}),
    );
    final body = jsonDecode(login.body) as Map;
    token = body['token'] as String;
    memberId = (body['member'] as Map)['id'] as String;
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

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
    return {
      '_status': response.statusCode,
      ...(jsonDecode(response.body) as Map).cast(),
    };
  }

  Future<SyncResponse> sync(List<SyncRecord> changes, {int since = 0}) async =>
      SyncResponse.fromJson(
        await call(
          'POST',
          'api/sync',
          SyncRequest(since: since, changes: changes).toJson(),
        ),
      );

  SyncRecord event(String id, String title, {List<String> members = const []}) {
    final start = DateTime.now().add(const Duration(days: 1));
    return SyncRecord(
      collection: Collections.events,
      id: id,
      data: CalendarEvent(
        id: id,
        title: title,
        start: start,
        end: start.add(const Duration(hours: 1)),
        memberIds: members,
      ).toData(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  test('feeds publish events and can be revoked', () async {
    await sync([
      event('e1', 'Familienessen'),
      event('e2', 'Papas Termin', members: ['someone-else']),
    ]);

    final all = await call('POST', 'api/calendar/feeds', {
      'name': 'Famio',
      'scope': 'all',
    });
    final mine = await call('POST', 'api/calendar/feeds', {
      'name': 'Meine',
      'scope': 'mine',
    });
    expect(all['_status'], 201);
    expect(
      ((await call('GET', 'api/calendar/feeds'))['feeds'] as List),
      hasLength(2),
    );

    // Calendar apps fetch without any login.
    final allIcs = await http.get(base.resolve(all['path'] as String));
    expect(allIcs.headers['content-type'], startsWith('text/calendar'));
    expect(allIcs.body, contains('SUMMARY:Familienessen'));
    expect(allIcs.body, contains('SUMMARY:Papas Termin'));
    expect(allIcs.body, contains('X-WR-CALNAME:Famio'));

    final mineIcs = await http.get(base.resolve(mine['path'] as String));
    expect(mineIcs.body, contains('SUMMARY:Familienessen'));
    expect(mineIcs.body, isNot(contains('Papas Termin')));

    await call('DELETE', 'api/calendar/feeds/${all['id']}');
    expect(
      (await http.get(base.resolve(all['path'] as String))).statusCode,
      404,
    );
    expect((await http.get(base.resolve('ical/guessed.ics'))).statusCode, 404);
  });

  test('subscriptions are imported, updated and removed', () async {
    final sub = SyncRecord(
      collection: Collections.calendarSubscriptions,
      id: 'sub1',
      data: const CalendarSubscription(
        id: 'sub1',
        name: 'Schule',
        url: 'webcal://calendar.google.com/secret/basic.ics',
      ).toData(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await sync([sub]);

    var status = await call('POST', 'api/calendar/subscriptions/sub1/refresh');
    expect(status['error'], isNull);
    expect(status['eventCount'], 2);
    expect(
      requests.single.url.toString(),
      'https://calendar.google.com/secret/basic.ics',
    );

    var pulled = await sync(const []);
    final imported = pulled.changes
        .where((r) => r.collection == Collections.externalEvents)
        .map(CalendarEvent.fromRecord)
        .toList();
    expect(
      imported.map((e) => e.title),
      unorderedEquals(['Schwimmkurs', 'Elternabend']),
    );
    expect(imported.every((e) => e.sourceId == 'sub1'), isTrue);
    final rev = pulled.rev;

    // Clients cannot modify imported data.
    final hacked = imported.first.copyWith(title: 'Gehackt');
    final tampered = await sync([
      SyncRecord(
        collection: Collections.externalEvents,
        id: hacked.id,
        data: hacked.toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch + 60000,
      ),
    ], since: rev);
    expect(tampered.rejected.single.data['title'], isNot('Gehackt'));

    // One event disappears at the source.
    remote = feed([
      vevent('a', 'Schwimmkurs', DateTime.now().add(const Duration(days: 2))),
    ]);
    remoteStatus = 200;
    status = await call('POST', 'api/calendar/subscriptions/sub1/refresh');
    expect(status['eventCount'], 1);
    pulled = await sync(const [], since: rev);
    expect(
      pulled.changes.where(
        (r) => r.collection == Collections.externalEvents && r.deleted,
      ),
      hasLength(1),
    );

    // Errors are reported, existing events stay.
    remoteStatus = 404;
    status = await call('POST', 'api/calendar/subscriptions/sub1/refresh');
    expect(status['error'], contains('404'));
    expect(status['eventCount'], 1);

    // Deleting the subscription removes its events.
    await sync([
      SyncRecord(
        collection: Collections.calendarSubscriptions,
        id: 'sub1',
        data: const {},
        deleted: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch + 1000,
      ),
    ]);
    await app.importer.refreshAll();
    expect(app.records.all(Collections.externalEvents), isEmpty);
    expect(app.records.all(Collections.calendarSyncStatus), isEmpty);
    expect(memberId, isNotEmpty);
  });

  test('unchanged feeds are not re-imported (ETag)', () async {
    await sync([
      SyncRecord(
        collection: Collections.calendarSubscriptions,
        id: 's',
        data: const CalendarSubscription(
          id: 's',
          name: 'x',
          url: 'https://example.org/a.ics',
        ).toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    await app.importer.refreshAll();
    await app.importer.refreshAll();
    expect(requests, hasLength(2));
    expect(requests.last.headers['if-none-match'], '"v1"');
    expect(app.records.all(Collections.externalEvents), hasLength(2));
  });

  test('invalid addresses produce a readable error', () async {
    await sync([
      SyncRecord(
        collection: Collections.calendarSubscriptions,
        id: 'bad',
        data: const CalendarSubscription(
          id: 'bad',
          name: 'x',
          url: 'ftp://nope',
        ).toData(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    final status = await call('POST', 'api/calendar/subscriptions/bad/refresh');
    expect(status['error'], contains('https://'));
    expect(requests, isEmpty);
  });
}

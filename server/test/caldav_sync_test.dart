import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// A Famio server with one member, reachable over HTTP.
class Node {
  Node._(this.app, this.server, this.base, this.token, this.memberId);

  static Future<Node> start(String username) async {
    final app = FamioServerApp.inMemory();
    final server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    final base = Uri.parse('http://localhost:${server.port}/');
    final login = await http.post(
      base.resolve('api/auth/setup'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': 'geheim123',
        'setupCode': app.setupCode,
      }),
    );
    final body = jsonDecode(login.body) as Map;
    return Node._(
      app,
      server,
      base,
      body['token'] as String,
      (body['member'] as Map)['id'] as String,
    );
  }

  final FamioServerApp app;
  final HttpServer server;
  final Uri base;
  final String token;
  final String memberId;

  Future<Object?> call(String method, String path, [Object? body]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $token'
      ..headers['content-type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode >= 300) {
      throw StateError('${response.statusCode}: ${response.body}');
    }
    return jsonDecode(response.body);
  }

  void save(CalendarEvent e, {int? updatedAt, bool deleted = false}) {
    app.records.writeAs(memberId, [
      SyncRecord(
        collection: Collections.events,
        id: e.id,
        data: deleted ? const {} : e.toData(),
        deleted: deleted,
        updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
  }

  Map<String, CalendarEvent> get events => {
    for (final r in app.records.all(Collections.events))
      r.id: CalendarEvent.fromRecord(r),
  };

  Future<void> close() async {
    await server.close(force: true);
    await app.close();
  }
}

CalendarEvent event(String id, String title, {int days = 3}) {
  final start = DateTime.now().add(Duration(days: days));
  final at = DateTime(start.year, start.month, start.day, 10);
  return CalendarEvent(
    id: id,
    title: title,
    start: at,
    end: at.add(const Duration(hours: 1)),
  );
}

void main() {
  late Node remote; // Plays iCloud: another Famio via its CalDAV server.
  late Node famio;
  late String secret;
  late CalDavAccount account;

  Future<CalDavAccount> sync() async => CalDavAccount.fromJson(
    (await famio.call('POST', 'api/calendar/caldav/${account.id}/sync') as Map)
        .cast(),
  );

  setUp(() async {
    remote = await Node.start('oma');
    famio = await Node.start('mama');
    secret =
        (await remote.call('POST', 'api/me/app-passwords', {
                  'name': 'Famio von Mama',
                })
                as Map)['secret']
            as String;
    remote.save(event('r1', 'Omas Geburtstag', days: 5));
    famio.save(event('f1', 'Elternabend'));
    famio.save(event('secret', 'Kinderarzt').copyWith(confidential: true));
    famio.save(event('old', 'Längst vorbei', days: -200));

    final found =
        await famio.call('POST', 'api/calendar/caldav/discover', {
              // Only the server address: found via /.well-known/caldav.
              'url': remote.base.toString(),
              'username': 'oma',
              'password': secret,
            })
            as Map;
    final calendars = [
      for (final c in found['calendars'] as List)
        CalDavCalendarInfo.fromJson((c as Map).cast()),
    ];
    expect(calendars.single.name, 'Famio');
    expect(calendars.single.readOnly, isFalse);

    account = CalDavAccount.fromJson(
      (await famio.call('POST', 'api/calendar/caldav', {
                'serverUrl': remote.base.toString(),
                'username': 'oma',
                'password': secret,
                'calendarUrl': calendars.single.url,
                'calendarName': calendars.single.name,
              })
              as Map)
          .cast(),
    );
  });

  tearDown(() async {
    await famio.close();
    await remote.close();
  });

  test('first sync brings both sides together', () async {
    expect(account.error, isNull);
    // Remote event arrived in Famio …
    expect(
      famio.events.values.map((e) => e.title),
      contains('Omas Geburtstag'),
    );
    // … and Famio's own went there, except the confidential and old one.
    final there = remote.events.values.map((e) => e.title).toSet();
    expect(there, containsAll(['Elternabend', 'Omas Geburtstag']));
    expect(there, isNot(contains('Kinderarzt')));
    expect(there, isNot(contains('Längst vorbei')));
    expect(account.linkedEvents, 2);

    // Nothing changed: a second sync is quiet.
    final revRemote = remote.app.records.currentRev;
    final revFamio = famio.app.records.currentRev;
    await sync();
    expect(remote.app.records.currentRev, revRemote);
    expect(famio.app.records.currentRev, revFamio);
  });

  test('edits and deletions travel both ways', () async {
    // Edited there.
    remote.save(remote.events['r1']!.copyWith(title: 'Omas 80.'));
    // Edited here (the event Famio pushed).
    famio.save(famio.events['f1']!.copyWith(title: 'Elternabend Kita'));
    await sync();
    expect(
      famio.events.values.map((e) => e.title),
      containsAll(['Omas 80.', 'Elternabend Kita']),
    );
    expect(
      remote.events.values.map((e) => e.title),
      containsAll(['Omas 80.', 'Elternabend Kita']),
    );

    // Deleted there, and deleted here.
    remote.save(remote.events['r1']!, deleted: true);
    famio.save(famio.events['f1']!, deleted: true);
    await sync();
    expect(
      famio.events.values.map((e) => e.title),
      isNot(contains('Omas 80.')),
    );
    expect(remote.events, isEmpty);
  });

  test('marking an event confidential removes it there', () async {
    famio.save(famio.events['f1']!.copyWith(confidential: true));
    await sync();
    expect(remote.events.values.map((e) => e.title), ['Omas Geburtstag']);
    // Famio keeps it.
    expect(famio.events['f1']!.confidential, isTrue);
  });

  test('when both sides changed, the newer change wins', () async {
    final pulledId = famio.events.values
        .firstWhere((e) => e.title == 'Omas Geburtstag')
        .id;
    final now = DateTime.now().millisecondsSinceEpoch;
    famio.save(
      famio.events[pulledId]!.copyWith(title: 'Älter (Famio)'),
      updatedAt: now - 60000,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    remote.save(remote.events['r1']!.copyWith(title: 'Neuer (dort)'));
    await sync();
    expect(famio.events[pulledId]!.title, 'Neuer (dort)');
    expect(remote.events['r1']!.title, 'Neuer (dort)');
  });

  test('removing the connection removes only imported events', () async {
    await famio.call('DELETE', 'api/calendar/caldav/${account.id}');
    expect(
      famio.events.values.map((e) => e.title),
      isNot(contains('Omas Geburtstag')),
    );
    expect(famio.events.values.map((e) => e.title), contains('Elternabend'));
    // The other calendar keeps everything.
    expect(remote.events.length, 2);
    final list = await famio.call('GET', 'api/calendar/caldav') as Map;
    expect(list['accounts'], isEmpty);
  });

  test('a wrong password is reported, not thrown', () async {
    await famio.call('PATCH', 'api/calendar/caldav/${account.id}', {
      'password': 'falsch',
    });
    final state = await sync();
    expect(state.error, contains('Anmeldung'));
  });

  test('a resource renamed on the other side stays the same event', () async {
    // Like Google: the event Famio pushed shows up under another address,
    // still with its UID.
    final pushed = remote.events['f1']!;
    remote.save(pushed, deleted: true);
    remote.app.records.writeAs(remote.memberId, [
      SyncRecord(
        collection: Collections.events,
        id: 'renamed-by-server',
        data: {...pushed.toData(), 'icalUid': 'f1@famio'},
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    final state = await sync();
    expect(state.error, isNull);
    // Neither deleted nor duplicated in Famio.
    expect(
      famio.events.values.where((e) => e.title == 'Elternabend'),
      hasLength(1),
    );
    expect(famio.events['f1'], isNotNull);
    // Edits keep going to the new address.
    famio.save(famio.events['f1']!.copyWith(title: 'Elternabend neu'));
    await sync();
    expect(remote.events['renamed-by-server']!.title, 'Elternabend neu');
    expect(remote.events.containsKey('f1'), isFalse);
  });
}

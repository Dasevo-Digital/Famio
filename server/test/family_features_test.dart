import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/push/push_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

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

  final seen = <String, SyncRecord>{};

  Future<SyncResponse> sync([List<SyncRecord> changes = const []]) async {
    final response = SyncResponse.fromJson(
      await call(
        'POST',
        'api/sync',
        SyncRequest(since: rev, changes: changes).toJson(),
      ),
    );
    for (final r in [...response.changes, ...response.rejected]) {
      r.deleted
          ? seen.remove('${r.collection}/${r.id}')
          : seen['${r.collection}/${r.id}'] = r;
    }
    rev = response.rev;
    return response;
  }

  Set<String> collections() => {for (final r in seen.values) r.collection};
}

SyncRecord _record(String collection, String id, Map<String, Object?> data) =>
    SyncRecord(
      collection: collection,
      id: id,
      data: data,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

void main() {
  late HttpServer server;
  late FamioServerApp app;
  late Uri base;
  late _Member mama; // admin, adult
  late _Member kind;
  late _Member oma;
  final pushed = <Map<String, Object?>>[];

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

  Future<_Member> addMember(String username, MemberRole role) async {
    final created = await mama.call('POST', 'api/admin/users', {
      'username': username,
      'displayName': username,
      'password': 'geheim123',
      'role': role.name,
    });
    expect(created['role'], role.name);
    return login(username);
  }

  setUp(() async {
    pushed.clear();
    app = FamioServerApp.inMemory(
      httpClient: MockClient((request) async {
        pushed.add({
          'url': request.url.toString(),
          'auth': request.headers['authorization'],
          ...(jsonDecode(request.body) as Map).cast<String, Object?>(),
        });
        return http.Response('{}', 200);
      }),
    );
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final setup = await http.post(
      base.resolve('api/auth/setup'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': 'mama',
        'password': 'geheim123',
        'setupCode': app.setupCode,
      }),
    );
    final body = jsonDecode(setup.body) as Map;
    mama = _Member(
      base,
      body['token'] as String,
      (body['member'] as Map)['id'] as String,
    );
    kind = await addMember('kind', MemberRole.child);
    oma = await addMember('oma', MemberRole.guest);
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  group('guests', () {
    test('receive only calendar, chat, shopping and tasks', () async {
      await mama.sync([
        _record(Collections.documents, 'd1', {'title': 'Pass'}),
        _record(Collections.budgetEntries, 'b1', {'cents': 100}),
        _record(Collections.events, 'e1', {'title': 'Fest'}),
        _record(Collections.shoppingItems, 's1', {'name': 'Milch'}),
      ]);
      await oma.sync();
      expect(oma.collections(), {
        Collections.events,
        Collections.shoppingItems,
      });
    });

    test('may chat and tick off, but not change events', () async {
      await mama.sync([
        _record(Collections.events, 'e1', {'title': 'Fest'}),
      ]);
      await oma.sync();
      final response = await oma.sync([
        _record(Collections.events, 'e1', {'title': 'Geändert'}),
        _record(Collections.documents, 'd2', {'title': 'Neu'}),
        _record(Collections.chatMessages, 'm1', {'text': 'Hallo'}),
      ]);
      // The event is set back, the document removed again.
      expect(oma.seen['events/e1']!.data['title'], 'Fest');
      expect(
        response.rejected.where((r) => r.id == 'd2').single.deleted,
        isTrue,
      );
      await mama.sync();
      expect(mama.seen['events/e1']!.data['title'], 'Fest');
      expect(mama.seen.containsKey('documents/d2'), isFalse);
      expect(mama.seen['chat_messages/m1']!.data['text'], 'Hallo');
    });

    test('have no location sharing and cannot become admin', () async {
      final report = await oma.call('POST', 'api/location/report', {
        'fixes': [],
      });
      expect(report['_status'], 403);
      final promote = await mama.call('PATCH', 'api/admin/users/${oma.id}', {
        'isAdmin': true,
      });
      expect(promote['_status'], 400);
    });
  });

  group('service accounts', () {
    test('read and write like adults, but never become admin', () async {
      final ha = await addMember('homeassistant', MemberRole.service);
      await mama.sync([
        _record(Collections.documents, 'd1', {'title': 'Pass'}),
      ]);
      await ha.sync([
        _record(Collections.shoppingItems, 's1', {'name': 'Milch'}),
      ]);
      expect(ha.seen.containsKey('documents/d1'), isTrue);
      await mama.sync();
      expect(mama.seen['shopping_items/s1']!.data['name'], 'Milch');
      final promote = await mama.call('PATCH', 'api/admin/users/${ha.id}', {
        'isAdmin': true,
      });
      expect(promote['_status'], 400);
      expect(promote['error'], 'service_admin');
    });

    test('"Abhaken und Einkauf" ticks off and shops, nothing else', () async {
      final ha = await addMember('homeassistant', MemberRole.service);
      final set = await mama.call('PATCH', 'api/admin/users/${ha.id}', {
        'serviceAccess': 'everyday',
      });
      expect(set['serviceAccess'], 'everyday');
      await mama.sync([
        _record(Collections.tasks, 't1', {'title': 'Müll', 'done': false}),
        _record(Collections.events, 'e1', {'title': 'Fest'}),
      ]);
      await ha.sync();
      final response = await ha.sync([
        _record(Collections.tasks, 't1', {'title': 'Müll', 'done': true}),
        _record(Collections.tasks, 't2', {'title': 'Neu'}),
        _record(Collections.events, 'e1', {'title': 'Geändert'}),
        _record(Collections.shoppingItems, 's1', {'name': 'Milch'}),
      ]);
      expect(response.rejected.map((r) => r.id).toSet(), {'t2', 'e1'});
      await mama.sync();
      expect(mama.seen['tasks/t1']!.data['done'], true);
      expect(mama.seen['events/e1']!.data['title'], 'Fest');
      expect(mama.seen['shopping_items/s1']!.data['name'], 'Milch');
      // Renaming is more than ticking off.
      final rename = await ha.sync([
        _record(Collections.tasks, 't1', {'title': 'Anders', 'done': true}),
      ]);
      expect(rename.rejected.single.id, 't1');
    });

    test('"Nur lesen" changes nothing', () async {
      final ha = await addMember('homeassistant', MemberRole.service);
      await mama.call('PATCH', 'api/admin/users/${ha.id}', {
        'serviceAccess': 'readOnly',
      });
      final me = await ha.call('GET', 'api/me');
      expect((me['member'] as Map? ?? me)['serviceAccess'], 'readOnly');
      final response = await ha.sync([
        _record(Collections.shoppingItems, 's1', {'name': 'Milch'}),
      ]);
      expect(response.rejected.single.id, 's1');
      final feed = await ha.call('POST', 'api/calendar/feeds', {});
      expect(feed['_status'], 403);
      expect(feed['error'], 'read_only');
    });
  });

  group('children', () {
    SyncRecord points(
      String id,
      String member, {
      PointStatus status = PointStatus.pending,
      int value = 5,
    }) => _record(
      Collections.pointEntries,
      id,
      PointEntry(
        id: id,
        memberId: member,
        points: value,
        title: 'Zimmer aufgeräumt',
        kind: PointKind.chore,
        at: DateTime.now(),
        status: status,
      ).toData(),
    );

    test('ask for points, adults decide', () async {
      await kind.sync([points('p1', kind.id)]);
      await mama.sync();
      expect(mama.seen['point_entries/p1']!.data['status'], 'pending');

      // Approving themselves or granting points to others is undone.
      final self = await kind.sync([
        points('p1', kind.id, status: PointStatus.approved),
        points('p2', kind.id, status: PointStatus.approved, value: 999),
        points('p3', mama.id),
      ]);
      expect(self.rejected.map((r) => r.id).toSet(), {'p1', 'p2', 'p3'});
      expect(kind.seen['point_entries/p1']!.data['status'], 'pending');
      expect(kind.seen.containsKey('point_entries/p2'), isFalse);

      await mama.sync([points('p1', kind.id, status: PointStatus.approved)]);
      await kind.sync();
      expect(kind.seen['point_entries/p1']!.data['status'], 'approved');

      // Approved points stay, also against deleting.
      await kind.sync([
        SyncRecord(
          collection: Collections.pointEntries,
          id: 'p1',
          data: const {},
          deleted: true,
          updatedAt: DateTime.now().millisecondsSinceEpoch + 1000,
        ),
      ]);
      expect(kind.seen['point_entries/p1']!.data['status'], 'approved');
    });

    test('cannot manage chores, rewards or pocket money', () async {
      final response = await kind.sync([
        _record(Collections.chores, 'c1', {'title': 'Nichts tun'}),
        _record(Collections.rewards, 'r1', {'title': 'Pony', 'cost': 1}),
        _record(Collections.moneyEntries, 'm1', {
          'memberId': kind.id,
          'cents': 100000,
        }),
        _record(Collections.routineRuns, 'rr1', {'routineId': 'x'}),
      ]);
      expect(response.rejected.map((r) => r.id).toSet(), {'c1', 'r1', 'm1'});
      await mama.sync();
      expect(mama.collections(), {Collections.routineRuns});
    });
  });

  test('weekly pocket money is booked once per payday', () async {
    final since = DateTime.now().subtract(const Duration(days: 20));
    await mama.sync([
      _record(
        Collections.allowances,
        kind.id,
        Allowance(
          memberId: kind.id,
          weeklyCents: 250,
          payday: DateTime.now().weekday,
          since: since,
        ).toData(),
      ),
    ]);
    expect(app.allowances.run(), 3); // 2 weeks back and today
    expect(app.allowances.run(), 0);

    await kind.sync();
    final bookings = [
      for (final r in kind.seen.values)
        if (r.collection == Collections.moneyEntries) MoneyEntry.fromRecord(r),
    ];
    expect(bookings.map((b) => b.cents), [250, 250, 250]);

    // A booking an adult removed does not come back.
    await mama.sync();
    await mama.sync([
      SyncRecord(
        collection: Collections.moneyEntries,
        id: bookings.first.id,
        data: const {},
        deleted: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    expect(app.allowances.run(), 0);
  });

  group('push', () {
    test('rejects bad topic addresses', () async {
      for (final url in [
        'ntfy.sh/x',
        'ftp://ntfy.sh/x',
        'http://ntfy.sh/x',
        'https://127.0.0.1/famio',
        'https://ntfy.sh/',
        'https://u:p@ntfy.sh/x',
      ]) {
        final r = await mama.call('POST', 'api/me/push', {'url': url});
        expect(r['_status'], 400, reason: url);
      }
    });

    test(
      'chat messages reach the others, without details by default',
      () async {
        final added = await kind.call('POST', 'api/me/push', {
          'name': 'Handy',
          'url': 'https://push.example/famio-geheim',
          'token': 'tk_123',
        });
        expect(added['_status'], 201);
        expect(pushed.single['topic'], 'famio-geheim');
        expect(pushed.single['url'], 'https://push.example/');
        expect(pushed.single['auth'], 'Bearer tk_123');
        pushed.clear();

        await mama.sync([
          _record(Collections.chatMessages, 'm1', {
            'chatId': ChatIds.family,
            'authorId': mama.id,
            'text': 'Essen ist fertig',
          }),
        ]);
        await app.push.idle;
        expect(pushed.single['message'], 'Neue Nachricht');
        expect(pushed.single['title'], 'Famio');
        expect(jsonEncode(pushed), isNot(contains('Essen')));

        // With details, and never to the author.
        final targets = await kind.call('GET', 'api/me/push');
        final id = ((targets['targets'] as List).single as Map)['id'];
        await kind.call('DELETE', 'api/me/push/$id');
        await kind.call('POST', 'api/me/push', {
          'url': 'https://push.example/famio-geheim',
          'details': true,
        });
        pushed.clear();
        await kind.sync([
          _record(Collections.chatMessages, 'm2', {
            'chatId': ChatIds.family,
            'authorId': kind.id,
            'text': 'Komme gleich',
          }),
        ]);
        await mama.sync([
          _record(Collections.chatMessages, 'm3', {
            'chatId': ChatIds.family,
            'authorId': mama.id,
            'text': 'Beeil dich',
          }),
        ]);
        await app.push.idle;
        expect(pushed.single['message'], 'Beeil dich');
        expect(pushed.single['title'], 'mama · Familie');
      },
    );

    test('point requests go to the adults', () async {
      await mama.call('POST', 'api/me/push', {
        'url': 'https://push.example/eltern',
        'details': true,
      });
      pushed.clear();
      await kind.sync([
        _record(
          Collections.pointEntries,
          'p1',
          PointEntry(
            id: 'p1',
            memberId: kind.id,
            points: 3,
            title: 'Müll rausgebracht',
            kind: PointKind.chore,
            at: DateTime.now(),
            status: PointStatus.pending,
          ).toData(),
        ),
      ]);
      await app.push.idle;
      expect(pushed.single['message'], 'kind: Müll rausgebracht erledigt (+3)');
    });
  });

  group('emergency button', () {
    test(
      'a child raises an alarm the adults hear, also in quiet time',
      () async {
        // Mama sleeps: quiet hours around the clock.
        final now = tz.TZDateTime.now(app.settings.location);
        String at(int minutes) => QuietHours.format(
          (now.hour * 60 + now.minute + minutes) % (24 * 60),
        );
        await mama.call('PUT', 'api/me/quiet-hours', {
          'enabled': true,
          'start': at(-60),
          'end': at(60),
        });
        await mama.call('POST', 'api/me/push', {
          'url': 'https://push.example/famio-mama',
        });
        pushed.clear();

        expect((await oma.call('POST', 'api/sos', {}))['_status'], 403);
        final raised = await kind.call('POST', 'api/sos', {
          'latitude': 53.55,
          'longitude': 10.0,
          'accuracy': 8,
          'battery': 40,
        });
        expect(raised['_status'], 201);
        final id = raised['id'] as String;
        await app.push.idle;

        final notices = await mama.call('GET', 'api/notifications?after=0');
        final alarm = (notices['notices'] as List).last as Map;
        expect(alarm['alarm'], isTrue);
        expect(alarm['quiet'], isFalse);
        expect(alarm['title'], '🚨 SOS von kind');
        expect(pushed.single['priority'], 5);
        expect(pushed.single['title'], 'Famio');
        expect(pushed.single['message'], '🚨 SOS von kind');

        // The child and the adults see it; the guest does not.
        await mama.sync();
        await kind.sync();
        await oma.sync();
        final seen = SosAlert.fromRecord(mama.seen['sos_alerts/$id']!);
        expect(
          (seen.latitude, seen.battery, seen.state),
          (53.55, 40, SosState.active),
        );
        expect(kind.seen['sos_alerts/$id'], isNotNull);
        expect(oma.collections(), isNot(contains(Collections.sosAlerts)));

        // Pressing again within half an hour updates the same alert.
        final again = await kind.call('POST', 'api/sos', {});
        expect(again['id'], id);
        expect(again['latitude'], 53.55);
      },
    );

    test('position, "Ich komme" and the end', () async {
      final id = (await kind.call('POST', 'api/sos', {}))['id'] as String;
      final moved = await kind.call('POST', 'api/sos/$id/position', {
        'latitude': 48.1,
        'longitude': 11.5,
      });
      expect(moved['latitude'], 48.1);
      expect(
        (await mama.call('POST', 'api/sos/$id/position', {
          'latitude': 1,
          'longitude': 1,
        }))['_status'],
        404,
        reason: 'only the phone that raised it',
      );
      expect((await kind.call('POST', 'api/sos/$id/coming'))['_status'], 403);

      final kindLast =
          (await kind.call('GET', 'api/notifications'))['last'] as int;
      final coming = await mama.call('POST', 'api/sos/$id/coming');
      expect(coming['state'], 'coming');
      expect(coming['comingBy'], mama.id);
      final kindGot = await kind.call(
        'GET',
        'api/notifications?after=$kindLast',
      );
      expect(
        ((kindGot['notices'] as List).single as Map)['title'],
        'mama kommt',
      );

      final done = await kind.call('POST', 'api/sos/$id/resolve');
      expect(done['state'], 'resolved');
      expect(
        (await kind.call('POST', 'api/sos/$id/position', {
          'latitude': 1,
          'longitude': 1,
        }))['_status'],
        409,
      );
      // A new press after the end is a new alert.
      expect((await kind.call('POST', 'api/sos', {}))['id'], isNot(id));
    });

    test('only adults change the settings', () async {
      final settings = _record(Collections.sosSettings, SosSettings.recordId, {
        ...const SosSettings(phones: {'x': '0170 1'}).toData(),
      });
      final byKind = await kind.sync([settings]);
      expect(byKind.rejected, isNotEmpty);
      final byMama = await mama.sync([settings]);
      expect(byMama.rejected, isEmpty);
      await kind.sync();
      expect(
        SosSettings.fromRecord(
          kind.seen['sos_settings/${SosSettings.recordId}'],
        ).phones,
        {'x': '0170 1'},
      );
    });
  });

  group('own push', () {
    Map<String, Object?> chat(String id, String chatId, String text) => {
      'chatId': chatId,
      'authorId': mama.id,
      'text': text,
    };

    test('a device token only fetches notifications', () async {
      final created = await kind.call(
        'POST',
        'api/notifications/device-token',
        {'device': 'Handy'},
      );
      expect(created['_status'], 201);
      final device = _Member(base, created['token'] as String, kind.id);
      // A new device starts at the newest notification.
      final start = await device.call('GET', 'api/notifications');
      expect(start['notices'], isEmpty);
      final last = start['last'] as int;

      await mama.sync([
        _record(
          Collections.chatMessages,
          'n1',
          chat('n1', ChatIds.family, 'Essen ist fertig'),
        ),
      ]);
      await app.push.idle;
      final got = await device.call('GET', 'api/notifications?after=$last');
      final notices = (got['notices'] as List).cast<Map>();
      expect(notices.single['body'], 'Essen ist fertig');
      expect(notices.single['brief'], 'Neue Nachricht');
      expect(got['last'], notices.single['id']);
      // The author gets nothing, and the token can do nothing else.
      final author = await mama.call('GET', 'api/notifications?after=0');
      expect(author['notices'], isEmpty);
      expect((await device.call('POST', 'api/sync', {}))['_status'], 401);
      expect((await device.call('GET', 'api/me'))['_status'], 401);
    });

    test('in the quiet time notices arrive silently', () async {
      final now = tz.TZDateTime.now(app.settings.location);
      String at(int minutes) =>
          QuietHours.format((now.hour * 60 + now.minute + minutes) % (24 * 60));
      expect((await kind.call('GET', 'api/me/quiet-hours'))['enabled'], false);
      final saved = await kind.call('PUT', 'api/me/quiet-hours', {
        'enabled': true,
        'start': at(-60),
        'end': at(60),
        'placesLoud': true,
      });
      expect(saved['start'], at(-60));
      await kind.call('POST', 'api/me/push', {
        'url': 'https://push.example/famio-geheim',
      });
      pushed.clear();

      await mama.sync([
        _record(
          Collections.chatMessages,
          'q1',
          chat('q1', ChatIds.family, 'Gute Nacht'),
        ),
      ]);
      await app.push.idle;
      final kindGot = await kind.call('GET', 'api/notifications?after=0');
      expect((kindGot['notices'] as List).last['quiet'], isTrue);
      expect(pushed.single['priority'], 2);
      final mamaGot = await mama.call('GET', 'api/notifications?after=0');
      expect([
        for (final n in mamaGot['notices'] as List) n['quiet'],
      ], everyElement(isFalse));

      // Arrivals stay loud if wanted; outside the time everything is loud.
      const place = PushNotice(
        to: {},
        title: 'Famio',
        body: 'Mia ist angekommen',
        brief: 'Neue Ortsmeldung',
        place: true,
      );
      expect(app.push.isQuiet(kind.id, place), isFalse);
      await kind.call('PUT', 'api/me/quiet-hours', {
        ...saved,
        'placesLoud': false,
      });
      expect(app.push.isQuiet(kind.id, place), isTrue);
      expect(
        app.push.isQuiet(
          kind.id,
          place,
          now: DateTime.now().add(const Duration(hours: 3)),
        ),
        isFalse,
      );
    });

    test('a waiting request returns as soon as something arrives', () async {
      final last = (await kind.call('GET', 'api/notifications'))['last'] as int;
      final watch = Stopwatch()..start();
      final waiting = kind.call('GET', 'api/notifications?after=$last&wait=20');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(app.notices.waiting, 1);
      await mama.sync([
        _record(
          Collections.chatMessages,
          'n2',
          chat('n2', ChatIds.family, 'Kommst du?'),
        ),
      ]);
      final got = await waiting;
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect((got['notices'] as List).single['body'], 'Kommst du?');
      expect(app.notices.waiting, 0);
    });

    test('only members who may see the record get it', () async {
      final last = (await oma.call('GET', 'api/notifications'))['last'] as int;
      await mama.sync([
        _record(Collections.chatMessages, 'n3', {
          ...chat('n3', ChatIds.direct(mama.id, kind.id), 'Nur für dich'),
          'visibleTo': [mama.id, kind.id],
        }),
      ]);
      await app.push.idle;
      final kindGot = await kind.call('GET', 'api/notifications?after=0');
      expect(jsonEncode(kindGot), contains('Nur für dich'));
      final omaGot = await oma.call('GET', 'api/notifications?after=$last');
      expect(omaGot['notices'], isEmpty);
    });

    test('events for unknown members still sync', () async {
      final response = await mama.call('POST', 'api/sync', {
        'since': 0,
        'changes': [
          _record(Collections.events, 'e1', {
            'title': 'Für jemand Unbekanntes',
            'start': DateTime.now().toUtc().toIso8601String(),
            'end': DateTime.now().toUtc().toIso8601String(),
            'memberIds': ['someone-gone', kind.id],
          }).toJson(),
        ],
      });
      expect(response['_status'], 200);
      final got = await kind.call('GET', 'api/notifications?after=0');
      expect(jsonEncode(got), contains('Für jemand Unbekanntes'));
    });

    test('test message and wipe', () async {
      expect(
        (await kind.call('POST', 'api/notifications/test'))['_status'],
        200,
      );
      final got = await kind.call('GET', 'api/notifications?after=0');
      expect((got['notices'] as List).single['title'], 'Famio');
      app.notices.deleteAll();
      // Position beyond the newest (wiped): back to the start.
      final after = await kind.call(
        'GET',
        'api/notifications?after=${got['last']}&wait=5',
      );
      expect(after['last'], 0);
    });
  });
}

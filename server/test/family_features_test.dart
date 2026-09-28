import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

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
      body: jsonEncode({'username': 'mama', 'password': 'geheim123'}),
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
        'https://ntfy.sh/',
        'https://u:p@ntfy.sh/x',
      ]) {
        final r = await mama.call('POST', 'api/me/push', {'url': url});
        expect(r['_status'], 400, reason: url);
      }
    });

    test('chat messages reach the others, without details by default', () async {
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
    });

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
}

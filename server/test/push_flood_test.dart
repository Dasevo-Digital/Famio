import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/push/push_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Many changes in one sync do not become a notice each (#475): messages
/// of one chat are one notice, nobody gets more than ten for one sync, and
/// no more than a few go out at the same time; emergencies never wait.
void main() {
  late FamioServerApp app;
  late FamilyMember mama, papa, guest;
  late List<Map<String, Object?>> posts;
  var inFlight = 0;
  var maxInFlight = 0;

  Future<http.Response> ntfy(http.Request r) async {
    posts.add((jsonDecode(r.body) as Map).cast());
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    inFlight--;
    return http.Response('', 200);
  }

  setUp(() async {
    posts = [];
    inFlight = 0;
    maxInFlight = 0;
    app = FamioServerApp.inMemory(httpClient: MockClient(ntfy));
    mama = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
    guest = app.accounts.create(
      username: 'oma',
      displayName: 'Oma',
      role: MemberRole.guest,
    );
    await app.push.add(mama.id, name: 'Handy', url: 'https://ntfy.example/a');
    await app.push.add(papa.id, name: 'Handy', url: 'https://ntfy.example/b');
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  Future<void> sync(FamilyMember who, List<SyncRecord> changes) async {
    final response = await app.handler(
      Request(
        'POST',
        Uri.parse('http://famio.test/api/sync'),
        headers: {
          'authorization': 'Bearer ${app.accounts.createSession(who.id)}',
          'content-type': 'application/json',
        },
        body: jsonEncode(SyncRequest(since: 0, changes: changes).toJson()),
      ),
    );
    expect(response.statusCode, 200);
    await response.readAsString();
    await app.push.idle;
  }

  List<Map<String, Object?>> to(String topic) => [
    for (final p in posts)
      if (p['topic'] == topic) p,
  ];

  int boxed(String member) =>
      app.db.select('SELECT COUNT(*) AS n FROM notices WHERE member_id = ?', [
            member,
          ]).first['n']
          as int;

  test('messages of one chat in one sync are one notice', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(guest, [
      for (var i = 0; i < 40; i++)
        SyncRecord(
          collection: Collections.chatMessages,
          id: 'm$i',
          data: {
            'chatId': ChatIds.family,
            'authorId': guest.id,
            'text': 'Hallo $i',
            'sentAt': DateTime.now().toUtc().toIso8601String(),
          },
          updatedAt: now,
        ),
    ]);
    for (final (topic, member) in [('a', mama.id), ('b', papa.id)]) {
      expect(to(topic), hasLength(1));
      expect(to(topic).single['message'], '40 neue Nachrichten');
      expect(boxed(member), 1);
    }
    // One message stays a notice of its own.
    posts.clear();
    await sync(guest, [
      SyncRecord(
        collection: Collections.chatMessages,
        id: 'single',
        data: {
          'chatId': ChatIds.family,
          'authorId': guest.id,
          'text': 'Bis gleich',
          'sentAt': DateTime.now().toUtc().toIso8601String(),
        },
        updatedAt: now + 1000,
      ),
    ]);
    expect(to('a').single['message'], 'Neue Nachricht');
  });

  test('nobody gets more than ten for one sync; the rest in one', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await sync(mama, [
      for (var i = 0; i < 25; i++)
        SyncRecord(
          collection: Collections.tasks,
          id: 't$i',
          data: {'title': 'Aufgabe $i', 'done': false, 'assigneeId': papa.id},
          updatedAt: now,
        ),
    ]);
    final papas = to('b');
    expect(papas, hasLength(11));
    expect(papas.last['message'], 'Weitere Änderungen in Famio');
    expect(boxed(papa.id), 11);
    expect(to('a'), isEmpty, reason: 'nothing for the author');
    // The next sync starts again.
    posts.clear();
    await sync(mama, [
      SyncRecord(
        collection: Collections.tasks,
        id: 'later',
        data: {'title': 'Noch eine', 'done': false, 'assigneeId': papa.id},
        updatedAt: now + 1000,
      ),
    ]);
    expect(to('b'), hasLength(1));
  });

  group('sending', () {
    late PushService push;
    setUp(() async {
      push = PushService(
        db: app.db,
        records: app.records,
        accounts: app.accounts,
        location: () => app.location,
        client: MockClient(ntfy),
        urlPolicy: RemoteUrlPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
        retries: const [],
        maxSends: 3,
      );
    });

    PushNotice notice(String title, {bool urgent = false}) => PushNotice(
      to: {mama.id},
      title: title,
      body: title,
      brief: title,
      urgent: urgent,
    );

    test('a few at a time, an emergency at once', () async {
      for (var i = 0; i < 12; i++) {
        push.deliver(() => notice('Info $i'), null);
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      push.deliver(() => notice('Notfall', urgent: true), null);
      await push.idle;
      expect(posts, hasLength(13));
      // Three slots, and the emergency besides them.
      expect(maxInFlight, 4);
      final order = [for (final p in posts) p['message']];
      expect(order.indexOf('Notfall'), lessThan(4));
    });

    test('stopping drops what still waits', () async {
      for (var i = 0; i < 12; i++) {
        push.deliver(() => notice('Info $i'), null);
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      push.stop();
      await push.idle;
      expect(posts, hasLength(3));
    });
  });
}

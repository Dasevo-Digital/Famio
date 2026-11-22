// Notifications through ntfy say nothing about their entry (#578): their
// link carries a random key of the stored notification, not the id of a
// chat (made from the members' ids) or of an appointment (chosen by a
// calendar app). Only the member it was for learns from the server what it
// opens, while it is kept.
import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/push/push_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late FamilyMember mama;
  late FamilyMember papa;
  final pushed = <Map<String, Object?>>[];

  setUp(() async {
    pushed.clear();
    app = FamioServerApp.inMemory(
      httpClient: MockClient((request) async {
        pushed.add((jsonDecode(request.body) as Map).cast());
        return http.Response('{}', 200);
      }),
    );
    mama = app.accounts.create(username: 'mama', displayName: 'Mama');
    papa = app.accounts.create(username: 'papa', displayName: 'Papa');
    await app.push.add(
      mama.id,
      name: 'Handy',
      url: 'https://push.example/famio-mama',
    );
    await app.push.add(
      mama.id,
      name: 'Tablet',
      url: 'https://push.example/famio-mama-tablet',
      details: true,
    );
  });
  tearDown(() => app.close());

  Future<List<Uri>> send(NoticeTarget? target) async {
    pushed.clear();
    app.push.deliver(
      () => PushNotice(
        to: {mama.id},
        title: 'Papa',
        body: 'Hallo',
        brief: 'Neue Nachricht',
        tag: 'speech_balloon',
        target: target,
      ),
      null,
    );
    await app.push.idle;
    expect(pushed, hasLength(2));
    return [
      for (final body in pushed)
        if (body['click'] case final String click) Uri.parse(click),
    ];
  }

  Future<(int, Map<String, Object?>)> open(String key, FamilyMember as) async {
    final r = await app.handler(
      Request(
        'GET',
        Uri.parse('https://famio.local/api/notifications/link/$key'),
        headers: {
          'authorization': 'Bearer ${app.accounts.createSession(as.id)}',
        },
      ),
    );
    return (
      r.statusCode,
      (jsonDecode(await r.readAsString()) as Map).cast<String, Object?>(),
    );
  }

  test('a direct chat: the link names neither the chat nor the two', () async {
    final chat = ChatIds.direct(mama.id, papa.id);
    final links = await send(NoticeTarget.chat(chat));
    expect(links, hasLength(2), reason: 'with and without details');
    final keys = {for (final link in links) link.queryParameters['notice']};
    expect(keys, hasLength(1), reason: 'one notification, one key');
    for (final link in links) {
      expect(link.scheme, 'famio');
      expect(link.queryParameters.keys, ['notice']);
      for (final secret in [chat, ...chat.split('-').skip(1)]) {
        expect('$link', isNot(contains(secret)));
      }
    }
    final (status, body) = await open(keys.single!, mama);
    expect(status, 200);
    expect(NoticeTarget.decode(body['target'] as String?), isNotNull);
    expect(body['target'], NoticeTarget.chat(chat).encode());
  });

  test('an appointment named by a calendar app', () async {
    const target = NoticeTarget.event('kinderpsychiatrie-erstgespraech');
    final links = await send(target);
    for (final link in links) {
      expect('$link', isNot(contains('kinderpsychiatrie')));
    }
    final (status, body) = await open(
      links.first.queryParameters['notice']!,
      mama,
    );
    expect(status, 200);
    expect(body['target'], target.encode());
  });

  test('only for the member it was for, while it is kept', () async {
    final links = await send(const NoticeTarget.task('t1'));
    final key = links.first.queryParameters['notice']!;
    expect(key.length, greaterThanOrEqualTo(22));
    expect((await open(key, papa)).$1, 404);
    expect((await open('${key}x', mama)).$1, 404);
    expect((await open('nicht-vorhanden-123456', mama)).$1, 404);
    expect((await open(key, mama)).$1, 200);
    app.notices.deleteAll();
    expect((await open(key, mama)).$1, 404);
  });

  test('a new key for every notification and member', () async {
    final first = await send(const NoticeTarget.task('t1'));
    final second = await send(const NoticeTarget.task('t1'));
    expect(
      first.first.queryParameters['notice'],
      isNot(second.first.queryParameters['notice']),
    );
  });

  test('nothing to open, no link', () async {
    expect(await send(null), isEmpty);
  });
}

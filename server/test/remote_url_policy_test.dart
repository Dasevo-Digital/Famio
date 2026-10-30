import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/api_exception.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  Matcher refused(String code) =>
      throwsA(isA<ApiException>().having((e) => e.code, 'code', code));

  group('RemoteUrlPolicy', () {
    test('a name that resolves into the private network is refused', () {
      final asked = <String>[];
      final policy = RemoteUrlPolicy(
        lookup: (host) async {
          asked.add(host);
          return [InternetAddress('10.0.0.5')];
        },
      );
      expect(
        policy.check(Uri.parse('https://intern.example/x')),
        refused('unsafe_remote_url'),
      );
      expect(asked, ['intern.example']);
    });

    test('a name that does not resolve is left to the request itself', () {
      final policy = RemoteUrlPolicy(
        lookup: (host) async => throw const SocketException('unknown'),
      );
      expect(policy.check(Uri.parse('https://push.example/x')), completes);
    });

    test('literal addresses and localhost need no resolver', () async {
      final policy = RemoteUrlPolicy(lookup: (host) => fail('resolved $host'));
      for (final url in ['https://127.0.0.1/x', 'https://localhost/x']) {
        await expectLater(
          policy.check(Uri.parse(url)),
          refused('unsafe_remote_url'),
        );
      }
    });

    test('allowing the private network skips the resolver', () {
      final policy = RemoteUrlPolicy(
        allowPrivateNetwork: true,
        lookup: (host) => fail('resolved $host'),
      );
      expect(policy.check(Uri.parse('http://kalender.lan/x')), completes);
    });
  });

  group('test servers resolve no names', () {
    late FamioServerApp app;
    late String mama;
    tearDown(() => app.close());

    test('by default, push topics are added without a real resolver', () async {
      app = FamioServerApp.inMemory();
      mama = app.accounts.create(username: 'mama', displayName: 'Mama').id;
      final target = await app.push.add(
        mama,
        name: 'Handy',
        url: 'https://push.example/famio',
      );
      expect(target.url, 'https://push.example/famio');
    });

    test('push and the recipe page use the given lookup', () async {
      final asked = <String>[];
      app = FamioServerApp.inMemory(
        hostLookup: (host) async {
          asked.add(host);
          return [InternetAddress('192.168.1.5')];
        },
      );
      mama = app.accounts.create(username: 'mama', displayName: 'Mama').id;
      expect(
        app.push.add(mama, name: 'Handy', url: 'https://push.example/famio'),
        refused('unsafe_remote_url'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(asked, ['push.example']);
      final page = await app.handler(
        Request(
          'POST',
          Uri.parse('https://famio.local/api/web/page'),
          headers: {
            'authorization': 'Bearer ${app.accounts.createSession(mama)}',
            'content-type': 'application/json',
          },
          body: jsonEncode({'url': 'https://rezepte.example/kuchen'}),
        ),
      );
      expect(page.statusCode, 400);
      expect(await page.readAsString(), contains('unsafe_remote_url'));
      expect(asked, ['push.example', 'rezepte.example']);
    });
  });
}

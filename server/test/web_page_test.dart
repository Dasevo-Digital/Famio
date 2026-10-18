import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String token;
  final asked = <Uri>[];

  setUp(() {
    asked.clear();
    app = FamioServerApp.inMemory(
      httpClient: MockClient((request) async {
        asked.add(request.url);
        return switch (request.url.path) {
          '/rezept' => http.Response(
            '<html><script type="application/ld+json">{}</script></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
          '/weiter' => http.Response(
            '',
            302,
            headers: {'location': 'https://rezepte.test/rezept'},
          ),
          '/intern' => http.Response(
            '',
            302,
            headers: {'location': 'https://127.0.0.1/admin'},
          ),
          _ => http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        };
      }),
    );
    final mama = app.accounts.create(username: 'mama', displayName: 'Mama');
    token = app.accounts.createSession(mama.id);
  });
  tearDown(() => app.close());

  Future<(int, Map<String, Object?>)> page(String url) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('https://famio.local/api/web/page'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({'url': url}),
      ),
    );
    return (
      r.statusCode,
      (jsonDecode(await r.readAsString()) as Map).cast<String, Object?>(),
    );
  }

  test('the server reads a recipe page for the web app', () async {
    final (status, body) = await page('https://rezepte.test/weiter');
    expect(status, 200);
    expect(body['url'], 'https://rezepte.test/rezept');
    expect(body['html'], contains('ld+json'));
  });

  test(
    'never into the private network, not through a redirect either',
    () async {
      expect((await page('https://127.0.0.1/admin')).$1, 400);
      expect((await page('http://rezepte.test/rezept')).$1, 400);
      expect((await page('https://rezepte.test/intern')).$1, 400);
      expect(asked.map((u) => u.host), isNot(contains('127.0.0.1')));
      // Only web pages.
      expect((await page('https://rezepte.test/daten.json')).$1, 400);
    },
  );
}

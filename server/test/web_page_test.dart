import 'dart:convert';
import 'dart:typed_data';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String token;
  final asked = <Uri>[];
  final jpeg = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 2000, height: 1000)),
  );

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
          '/fotos/kuchen.jpg' => http.Response.bytes(
            jpeg,
            200,
            headers: {'content-type': 'image/jpeg; charset=binary'},
          ),
          '/umweg.jpg' => http.Response(
            '',
            302,
            headers: {'location': 'https://bilder.test/fotos/kuchen.jpg'},
          ),
          '/riesig.jpg' => http.Response.bytes(
            Uint8List(21 * 1024 * 1024),
            200,
            headers: {'content-type': 'image/jpeg'},
          ),
          '/bild.svg' => http.Response(
            '<svg/>',
            200,
            headers: {'content-type': 'image/svg+xml'},
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

  Future<(int, Map<String, Object?>)> image(String url, {String? as}) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('https://famio.local/api/web/image'),
        headers: {
          'authorization': 'Bearer ${as ?? token}',
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

  Future<Response> preview(String id, int size) async => app.handler(
    Request(
      'GET',
      Uri.parse('https://famio.local/api/files/$id?thumb=$size'),
      headers: {'authorization': 'Bearer $token'},
    ),
  );

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

  test('the photo of a recipe is kept like an upload', () async {
    final (status, body) = await image('https://rezepte.test/umweg.jpg');
    expect(status, 201);
    expect(body['name'], 'kuchen.jpg');
    expect(body['mime'], 'image/jpeg');
    expect(body['size'], jpeg.length);
    expect(app.files.get(body['id']! as String), isNotNull);
  });

  test('only pictures, within the limits, for members who may write', () async {
    expect((await image('https://rezepte.test/rezept')).$1, 400);
    expect((await image('https://rezepte.test/bild.svg')).$1, 400);
    expect((await image('https://rezepte.test/riesig.jpg')).$1, 413);
    expect((await image('https://127.0.0.1/a.jpg')).$1, 400);
    expect((await image('https://rezepte.test/intern')).$1, 400);
    final guest = app.accounts.create(
      username: 'gast',
      displayName: 'Gast',
      role: MemberRole.guest,
    );
    final session = app.accounts.createSession(guest.id);
    expect(
      (await image('https://rezepte.test/fotos/kuchen.jpg', as: session)).$1,
      403,
    );
    expect(app.files.usage().$1, 0);
  });

  test('a preview comes in every size the apps ask for', () async {
    final (_, body) = await image('https://rezepte.test/fotos/kuchen.jpg');
    final id = body['id']! as String;
    // Recipe page, memories, year review, slideshow and larger.
    for (final (size, width) in [
      (960, 1280),
      (240, 480),
      (640, 1280),
      (1920, 1920),
      (4000, 1920),
    ]) {
      final r = await preview(id, size);
      expect(r.statusCode, 200, reason: 'thumb=$size');
      expect(r.headers['content-type'], 'image/jpeg');
      final bytes = await r.read().expand((b) => b).toList();
      expect(img.decodeJpg(Uint8List.fromList(bytes))!.width, width);
    }
    expect((await preview(id, 0)).statusCode, 404);
  });
}

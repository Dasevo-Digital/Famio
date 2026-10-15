import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory web;
  final asked = <String>[];

  setUp(() {
    asked.clear();
    web = Directory.systemTemp.createTempSync('famio_web_fonts_');
    File('${web.path}/index.html').writeAsStringSync('<html>Famio</html>');
    // Shipped with the build: emoji; through the server: a CJK slice.
    File('${web.path}/fonts/notocoloremoji/v1/emoji.0.woff2')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    File(
      '${web.path}/fonts/remote.txt',
    ).writeAsStringSync('notosanssc/v1/hanzi.0.woff2\n');
  });

  tearDown(() => web.deleteSync(recursive: true));

  test('fonts come from the Famio server, never from Google', () async {
    final google = MockClient((request) async {
      asked.add(request.url.toString());
      return http.Response.bytes([7, 7, 7, 7], 200);
    });
    final app = FamioServerApp.inMemory(
      webApp: WebApp(web.path),
      httpClient: google,
    );
    addTearDown(app.close);
    Future<List<int>> bytes(Response r) async => [
      for (final chunk in await r.read().toList()) ...chunk,
    ];
    Future<Response> get(String path) async =>
        app.handler(Request('GET', Uri.parse('http://famio.test/app/$path')));

    final page = await get('');
    expect(page.headers['content-security-policy'], isNot(contains('gstatic')));
    await page.read().drain<void>();

    final emoji = await get('fonts/notocoloremoji/v1/emoji.0.woff2');
    expect(emoji.statusCode, 200);
    expect(await bytes(emoji), [1, 2, 3]);

    // A CJK slice: fetched once by the server, then from its cache.
    for (var i = 0; i < 2; i++) {
      final cjk = await get('fonts/notosanssc/v1/hanzi.0.woff2');
      expect(cjk.statusCode, 200);
      expect(cjk.headers['cache-control'], contains('immutable'));
      expect(await bytes(cjk), [7, 7, 7, 7]);
    }
    expect(asked, ['https://fonts.gstatic.com/s/notosanssc/v1/hanzi.0.woff2']);

    // Nothing that is not on the list: no open relay to Google.
    expect((await get('fonts/notosanssc/v1/other.woff2')).statusCode, 404);
    expect((await get('fonts/../index.html.woff2')).statusCode, 404);
    expect(asked, hasLength(1));
  });
}

import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late List<(String, bool)> lines;
  late DateTime now;

  Handler logged(
    Handler inner, {
    bool full = false,
    List<String> routes = const [],
  }) => RequestLog(
    write: (line, isError) => lines.add((line, isError)),
    full: full,
    slow: const Duration(milliseconds: 50),
    routes: routes,
    now: () => now,
  ).middleware(inner);

  Future<void> get(Handler h, String path, {String method = 'GET'}) =>
      Future.sync(() => h(Request(method, Uri.parse('http://famio/$path'))));

  setUp(() {
    lines = [];
    now = DateTime(2026, 10, 19, 8);
  });

  test('routine requests stay out of the log', () async {
    final h = logged(
      (r) => Response(switch (r.url.path) {
        'api/health' => 200,
        'dav/principals/mama/' => 401,
        'robots.txt' => 404,
        _ => 304,
      }),
    );
    for (final p in ['api/health', 'dav/principals/mama/', 'robots.txt', 'x']) {
      await get(h, p);
    }
    expect(lines, isEmpty);
  });

  test('errors, refusals and slow requests are logged', () async {
    final h = logged((r) async {
      if (r.url.path == 'slow') {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return Response.ok('');
      }
      if (r.url.path == 'api/notifications') {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return Response.ok('');
      }
      if (r.url.path == 'boom') throw StateError('kaputt');
      return Response(r.url.path == 'throttled' ? 429 : 500);
    });
    await get(h, 'throttled');
    await get(h, 'fails');
    await get(h, 'slow');
    await get(h, 'api/notifications'); // waits on purpose
    await expectLater(get(h, 'boom'), throwsStateError);
    expect(lines.map((l) => l.$1).toList(), [
      contains('[429] /throttled'),
      contains('[500] /fails'),
      allOf(contains('[200] /slow'), contains('langsam')),
      contains('ERROR /boom'),
      contains('kaputt'),
    ]);
    expect(lines.map((l) => l.$2), [false, true, false, true, true]);
  });

  test('a feed token never reaches the log', () async {
    final h = logged((r) => Response(500), routes: ['/ical/<file>']);
    await get(h, 'ical/geheimesToken123?file=Befund.pdf');
    expect(lines.single.$1, endsWith('/ical/<file>'));
    expect(lines.single.$1, isNot(contains('geheim')));
    expect(lines.single.$1, isNot(contains('Befund')));
  });

  test('paths appear as their route, never as requested', () async {
    final app = FamioServerApp.inMemory();
    addTearDown(app.close);
    final h = logged(
      (r) => Response(r.method == 'PUT' ? 412 : 500),
      routes: app.routes,
      full: true,
    );
    await get(h, 'dav/calendars/mama/famio/0f3a9c2e-geheim.ics', method: 'PUT');
    await get(h, 'dav/principals/mama/');
    await get(h, 'api/files/0f3a9c2e-geheim');
    await get(h, 'api/admin/users/u-geheim/sessions/s-geheim', method: 'PUT');
    await get(h, 'api/me/passkeys/options');
    await get(h, 'api/me/passkeys/pk-geheim');
    await get(h, 'app/assets/fonts/Nunito.ttf');
    await get(h, 'api/unbekannt/geheim/x');
    await get(h, 'wp-admin/geheim.php');
    await get(h, '');
    expect(lines.map((l) => l.$1.split(' ').last).toList(), [
      '/dav/calendars/<user>/<calendar>/<item>',
      '/dav/principals/<user>',
      '/api/files/<id>',
      '/api/admin/users/<id>/sessions/<sid>',
      '/api/me/passkeys/options',
      '/api/me/passkeys/<id>',
      '/app/<path>',
      '/api/unbekannt/…',
      '/wp-admin/…',
      '/',
    ]);
    expect(lines.first.$1, contains('[412]'));
    final text = lines.map((l) => l.$1).join('\n');
    expect(text, isNot(contains('geheim')));
    expect(text, isNot(contains('mama')));
  });

  test('full mode logs everything; a summary once a day', () async {
    final full = logged((r) => Response.ok(''), full: true);
    await get(full, 'api/health');
    expect(lines.single.$1, contains('[200] /api/health'));

    lines.clear();
    final quiet = logged((r) => Response(r.url.path == 'a' ? 200 : 401));
    await get(quiet, 'a');
    await get(quiet, 'b');
    await get(quiet, 'a');
    expect(lines, isEmpty);
    now = now.add(const Duration(hours: 25));
    await get(quiet, 'a');
    expect(lines.single.$1, contains('Anfragen seit'));
    expect(lines.single.$1, contains(': 3 (2xx 2, 4xx 1)'));
    expect(lines.single.$1, endsWith('; häufigste 401/404: 401 /b ×1'));
  });

  test(
    'the summary says where the 401 and 404 went, without secrets',
    () async {
      final h = logged(
        (r) => Response(r.url.path.startsWith('api/sync') ? 401 : 404),
      );
      for (var i = 0; i < 3; i++) {
        await get(h, 'wp-login.php');
      }
      await get(h, 'api/sync');
      await get(h, 'api/sync');
      await get(h, 'api/files/0f3a9c2e-geheim/Befund.pdf');
      await get(h, 'ical/geheimesToken123/kalender.ics');
      await get(h, 'dav/mama/calendars/familie');
      expect(lines, isEmpty);
      now = now.add(const Duration(hours: 25));
      await get(h, 'api/sync');
      final summary = lines.single.$1;
      expect(
        summary,
        endsWith(
          '; häufigste 401/404: 404 /wp-login.php ×3, 401 /api/sync ×2, '
          '404 /api/files/… ×1',
        ),
      );
      expect(summary, isNot(contains('geheim')));
      expect(summary, isNot(contains('Befund')));
      expect(summary, isNot(contains('mama')));
    },
  );
}

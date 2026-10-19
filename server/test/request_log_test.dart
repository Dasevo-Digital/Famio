import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late List<(String, bool)> lines;
  late DateTime now;

  Handler logged(Handler inner, {bool full = false}) => RequestLog(
    write: (line, isError) => lines.add((line, isError)),
    full: full,
    slow: const Duration(milliseconds: 50),
    now: () => now,
  ).middleware(inner);

  Future<void> get(Handler h, String path) =>
      Future.sync(() => h(Request('GET', Uri.parse('http://famio/$path'))));

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
    final h = logged((r) => Response(500));
    await get(h, 'ical/geheimesToken123?file=Befund.pdf');
    expect(lines.single.$1, contains('/ical/***'));
    expect(lines.single.$1, isNot(contains('geheim')));
    expect(lines.single.$1, isNot(contains('Befund')));
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
  });
}

// Recipe pages and pictures the server fetches for the apps (#575): a few
// at a time per member, at most twenty a minute, and what nobody reads (a
// redirect's body, an error page, the wrong type, a page announced too
// large) is not read to its end, however long it is.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _page =
    '<html><script type="application/ld+json">{"@type":"Recipe"}</script>'
    '</html>';

/// A body that never ends; counts what was read and whether the reader
/// gave up on it.
class _Endless {
  var delivered = 0;
  var cancelled = false;

  Stream<List<int>> get stream {
    late StreamController<List<int>> controller;
    final chunk = Uint8List(64 * 1024);
    controller = StreamController(
      onListen: () async {
        while (!cancelled) {
          if (!controller.isPaused) {
            controller.add(chunk);
            delivered += chunk.length;
          }
          await Future<void>.delayed(Duration.zero);
        }
      },
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }
}

http.StreamedResponse _html() => http.StreamedResponse(
  Stream.value(utf8.encode(_page)),
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

void main() {
  late FamioServerApp app;
  late String mama;
  late String papa;
  late Future<http.StreamedResponse> Function(http.BaseRequest) answer;

  setUp(() {
    answer = (_) async => _html();
    app = FamioServerApp.inMemory(
      httpClient: MockClient.streaming((request, _) => answer(request)),
    );
    String session(String name) => app.accounts.createSession(
      app.accounts.create(username: name, displayName: name).id,
    );
    mama = session('mama');
    papa = session('papa');
  });
  tearDown(() => app.close());

  Future<(int, Map<String, Object?>)> fetch(
    String token, {
    String path = 'page',
  }) async {
    final r = await app.handler(
      Request(
        'POST',
        Uri.parse('https://famio.local/api/web/$path'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({'url': 'https://rezepte.example/kuchen'}),
      ),
    );
    return (
      r.statusCode,
      (jsonDecode(await r.readAsString()) as Map).cast<String, Object?>(),
    );
  }

  test('two at a time per member; a third is turned down', () async {
    final waiting = <Completer<void>>[];
    answer = (_) async {
      final turn = Completer<void>();
      waiting.add(turn);
      await turn.future;
      return _html();
    };
    final page = fetch(mama);
    final picture = fetch(mama, path: 'image');
    await pumpEventQueue();
    expect(waiting, hasLength(2));
    final (status, body) = await fetch(
      mama,
    ).timeout(const Duration(seconds: 2));
    expect(status, 429);
    expect(body['error'], 'too_many_requests');
    // Someone else of the family is not held up.
    final others = fetch(papa);
    await pumpEventQueue();
    expect(waiting, hasLength(3));
    for (final turn in waiting) {
      turn.complete();
    }
    expect((await page).$1, 200);
    expect((await picture).$1, 400); // a web page, not a picture
    expect((await others).$1, 200);
    // Done: the next one runs.
    answer = (_) async => _html();
    expect((await fetch(mama)).$1, 200);
  });

  test('at most twenty a minute per member', () async {
    for (var i = 0; i < 20; i++) {
      expect((await fetch(mama)).$1, 200, reason: 'fetch ${i + 1}');
    }
    expect((await fetch(mama)).$1, 429);
    expect((await fetch(papa)).$1, 200);
  });

  test('what nobody reads is not read to its end', () async {
    late _Endless body;
    for (final (respond, status) in <(http.StreamedResponse Function(), int)>[
      // A redirect to the page itself, with a body that never ends.
      (
        () => http.StreamedResponse(
          body.stream,
          302,
          headers: {'location': 'https://rezepte.example/kuchen-neu'},
        ),
        200,
      ),
      (() => http.StreamedResponse(body.stream, 503), 502),
      (
        () => http.StreamedResponse(
          body.stream,
          200,
          headers: {'content-type': 'application/pdf'},
        ),
        400,
      ),
      (
        () => http.StreamedResponse(
          body.stream,
          200,
          contentLength: 50 * 1024 * 1024,
          headers: {'content-type': 'text/html'},
        ),
        413,
      ),
    ]) {
      body = _Endless();
      answer = (request) async =>
          request.url.path == '/kuchen-neu' ? _html() : respond();
      final (got, _) = await fetch(mama).timeout(const Duration(seconds: 5));
      expect(got, status);
      await pumpEventQueue();
      expect(body.cancelled, isTrue, reason: 'answer $status');
      expect(body.delivered, lessThan(1024 * 1024), reason: 'answer $status');
    }
  });

  test('a page is read up to 3 MB', () async {
    final body = _Endless();
    answer = (_) async => http.StreamedResponse(
      body.stream,
      200,
      headers: {'content-type': 'text/html'},
    );
    final (status, answered) = await fetch(
      mama,
    ).timeout(const Duration(seconds: 10));
    expect(status, 413);
    expect(answered['error'], 'too_large');
    await pumpEventQueue();
    expect(body.cancelled, isTrue);
    expect(body.delivered, lessThan(4 * 1024 * 1024));
  });
}

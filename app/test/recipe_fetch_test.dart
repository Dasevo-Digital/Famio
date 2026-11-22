// How a recipe page is fetched (#570): the device tries twice, then the
// server; a failure says why instead of always "no recipe".
import 'dart:async';
import 'dart:convert';

import 'package:famio/src/data/recipe_import.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _recipe = '''
<html><head><script type="application/ld+json">
{"@context":"https://schema.org","@type":"Recipe","name":"Blumenkohl-Bombe",
 "recipeIngredient":["1 Blumenkohl","200 g Hackfleisch"],
 "recipeInstructions":"Alles in den Ofen."}
</script></head></html>
''';
const _noRecipe = '<html><head><title>Einen Moment …</title></head></html>';

final _url = Uri.parse(
  'https://www.chefkoch.de/rezepte/1/Blumenkohl-Bombe.html?utm_source=app',
);

/// The page as the device sees it: one answer per request, in turn.
class _Site {
  _Site(this.answers);

  final List<FutureOr<http.Response> Function()> answers;
  var requests = 0;

  late final client = MockClient((request) async {
    expect(request.url, _url);
    expect(request.headers['user-agent'], contains('Famio'));
    return answers[requests++ % answers.length]();
  });
}

/// The Famio server's `/api/web/page`: one answer per request, in turn.
class _Server {
  _Server(this.answers);

  final List<http.Response Function()> answers;
  var requests = 0;

  late final api = FamioApiClient(
    'https://famio.test',
    token: 't',
    httpClient: MockClient((request) async {
      expect(request.url.path, '/api/web/page');
      expect(jsonDecode(request.body), {'url': '$_url'});
      return answers[requests++ % answers.length]();
    }),
  );

  static http.Response page(String html) => http.Response(
    jsonEncode({'url': '$_url', 'html': html}),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response error(int status, String code) => http.Response(
    jsonEncode({'error': code, 'message': 'Die Seite antwortet mit 403.'}),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

http.Response _answer(int status, [String body = '']) => http.Response(
  body,
  status,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

Future<ImportedRecipe> _import({
  _Site? site,
  _Server? server,
  bool direct = true,
}) => importRecipe(
  _url,
  id: 'r1',
  client: site?.client ?? MockClient((_) async => fail('no device fetch')),
  api: server?.api,
  direct: direct,
  retryAfter: Duration.zero,
);

Matcher _fails(
  RecipeImportProblem problem, {
  int? status,
  bool message = false,
}) => throwsA(
  isA<RecipeImportError>()
      .having((e) => e.problem, 'problem', problem)
      .having((e) => e.status, 'status', status)
      .having((e) => e.message != null, 'with the server words', message),
);

void main() {
  test('a page that turns the first request down gives the recipe on the '
      'second', () async {
    final site = _Site([() => _answer(403), () => _answer(200, _recipe)]);
    final server = _Server([() => fail('not needed')]);
    final imported = await _import(site: site, server: server);
    expect(imported.recipe.title, 'Blumenkohl-Bombe');
    expect(imported.recipe.source, '$_url');
    expect(site.requests, 2);
    expect(server.requests, 0);
  });

  test('turned down twice and no server: the reason with its status', () async {
    final site = _Site([() => _answer(429)]);
    await expectLater(
      _import(site: site),
      _fails(RecipeImportProblem.refused, status: 429),
    );
    expect(site.requests, 2);
  });

  test('a page that is gone is asked only once', () async {
    for (final status in [404, 410]) {
      final site = _Site([() => _answer(status)]);
      final server = _Server([() => fail('not asked')]);
      await expectLater(
        _import(site: site, server: server),
        throwsA(
          isA<RecipeImportError>()
              .having((e) => e.gone, 'gone', isTrue)
              .having((e) => e.status, 'status', status),
        ),
      );
      expect(site.requests, 1);
      expect(server.requests, 0);
    }
  });

  test('the server fetches what the device was turned down', () async {
    final site = _Site([() => _answer(403)]);
    final server = _Server([() => _Server.page(_recipe)]);
    final imported = await _import(site: site, server: server);
    expect(imported.recipe.title, 'Blumenkohl-Bombe');
    expect(imported.recipe.ingredients, hasLength(2));
    expect(site.requests, 2);
    expect(server.requests, 1);
  });

  test('a page without a recipe is tried again too', () async {
    // A page in between (a check against automated requests) at first.
    final site = _Site([
      () => _answer(200, _noRecipe),
      () => _answer(200, _recipe),
    ]);
    expect((await _import(site: site)).recipe.title, 'Blumenkohl-Bombe');
    expect(site.requests, 2);
  });

  test('the reason that tells the most is the one told', () async {
    // Turned down on the device, a page without a recipe at the server.
    await expectLater(
      _import(
        site: _Site([() => _answer(403)]),
        server: _Server([() => _Server.page(_noRecipe)]),
      ),
      _fails(RecipeImportProblem.refused, status: 403),
    );
    // Without a recipe on the device, the server offline.
    await expectLater(
      _import(
        site: _Site([() => _answer(200, _noRecipe)]),
        server: _Server([() => throw http.ClientException('offline')]),
      ),
      _fails(RecipeImportProblem.noRecipe),
    );
    // Out of reach on the device, turned down at the server.
    await expectLater(
      _import(
        site: _Site([() => throw http.ClientException('no route')]),
        server: _Server([() => _Server.error(502, 'page_unavailable')]),
      ),
      _fails(RecipeImportProblem.refused, message: true),
    );
    // Out of reach everywhere: the device's reason, the first.
    await expectLater(
      _import(
        site: _Site([() => throw http.ClientException('no route')]),
        server: _Server([() => _Server.error(403, 'forbidden')]),
      ),
      _fails(RecipeImportProblem.unreachable),
    );
  });

  test('no second try on the device after it waited in vain', () async {
    final site = _Site([() => throw TimeoutException('slow')]);
    final server = _Server([() => _Server.page(_recipe)]);
    expect(
      (await _import(site: site, server: server)).recipe.title,
      'Blumenkohl-Bombe',
    );
    expect(site.requests, 1);
    expect(server.requests, 1);
  });

  group('the device reads at most a page (#575)', () {
    /// A page of [size] bytes in parts of 64 KiB; counts what was read.
    ({MockClient client, int Function() read, int Function() requests}) site(
      int size, {
      String? type = 'text/html',
      bool announced = false,
    }) {
      var read = 0;
      var requests = 0;
      final client = MockClient.streaming((request, _) async {
        requests++;
        Stream<List<int>> parts() async* {
          const part = 64 * 1024;
          for (var sent = 0; sent < size; sent += part) {
            final bytes = List.filled(part, 0x61);
            read += bytes.length;
            yield bytes;
          }
        }

        return http.StreamedResponse(
          parts(),
          200,
          contentLength: announced ? size : null,
          headers: {'content-type': ?type},
        );
      });
      return (client: client, read: () => read, requests: () => requests);
    }

    Future<ImportedRecipe> import(MockClient client, _Server server) =>
        importRecipe(
          _url,
          id: 'r1',
          client: client,
          api: server.api,
          retryAfter: Duration.zero,
        );

    test('a page larger than the server would take is not read further '
        'nor asked again; the server still gets its turn', () async {
      final page = site(20 * 1024 * 1024);
      final server = _Server([() => _Server.page(_recipe)]);
      final imported = await import(page.client, server);
      expect(imported.recipe.title, 'Blumenkohl-Bombe');
      expect(page.requests(), 1);
      expect(page.read(), lessThanOrEqualTo(maxRecipePage + 64 * 1024));
      expect(server.requests, 1);
    });

    test('one that says it is too large is not read at all', () async {
      final page = site(20 * 1024 * 1024, announced: true);
      final server = _Server([() => _Server.page(_noRecipe)]);
      await expectLater(
        import(page.client, server),
        _fails(RecipeImportProblem.noRecipe),
      );
      expect(page.requests(), 1);
      expect(page.read(), lessThan(1024 * 1024));
    });

    test('only web pages', () async {
      final page = site(1024 * 1024, type: 'application/pdf');
      final server = _Server([() => _Server.page(_recipe)]);
      expect(
        (await import(page.client, server)).recipe.title,
        'Blumenkohl-Bombe',
      );
      expect(page.requests(), 1);
      expect(page.read(), lessThan(1024 * 1024));
    });

    test('a page that does not say what it is is still read', () async {
      final client = MockClient.streaming(
        (_, _) async =>
            http.StreamedResponse(Stream.value(utf8.encode(_recipe)), 200),
      );
      final server = _Server([() => fail('not needed')]);
      expect((await import(client, server)).recipe.title, 'Blumenkohl-Bombe');
    });
  });

  test('the web app asks the server a second time', () async {
    final server = _Server([
      () => _Server.error(502, 'page_unavailable'),
      () => _Server.page(_recipe),
    ]);
    final imported = await _import(server: server, direct: false);
    expect(imported.recipe.title, 'Blumenkohl-Bombe');
    expect(server.requests, 2);

    // An answer about Famio itself (a guest) stays the same next time.
    final guest = _Server([() => _Server.error(403, 'forbidden')]);
    await expectLater(
      _import(server: guest, direct: false),
      _fails(RecipeImportProblem.unreachable, message: true),
    );
    expect(guest.requests, 1);
  });
}

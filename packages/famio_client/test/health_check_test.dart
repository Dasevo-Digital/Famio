import 'package:famio_client/famio_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// What someone hears who types the address of another web server in the
/// house (a router, a NAS) instead of Famio's (GRU-008).
void main() {
  FamioApiClient serverAnswering(int status, String body, String type) =>
      FamioApiClient(
        'http://nas.example.test:8080',
        httpClient: MockClient(
          (r) async =>
              http.Response(body, status, headers: {'content-type': type}),
        ),
      );

  Matcher notFamio = throwsA(
    isA<ApiError>()
        .having((e) => e.code, 'code', 'not_famio')
        .having((e) => e.message, 'message', ClientTexts.notFamio),
  );

  test('a web page is no Famio server', () async {
    const page = '<html><body><h1>Not Found</h1></body></html>';
    await expectLater(
      serverAnswering(404, page, 'text/html').health(),
      notFamio,
    );
    await expectLater(
      serverAnswering(200, page, 'text/html').health(),
      notFamio,
    );
    // JSON, but no Famio.
    await expectLater(
      serverAnswering(
        404,
        '{"error":"not_found"}',
        'application/json',
      ).health(),
      notFamio,
    );
    await expectLater(
      serverAnswering(200, '{"name":"nas"}', 'application/json').health(),
      notFamio,
    );
  });

  test('a Famio server behind a proxy that fails is not called foreign', () {
    expect(
      serverAnswering(502, '<html>Bad Gateway</html>', 'text/html').health(),
      throwsA(
        isA<ApiError>()
            .having((e) => e.code, 'code', 'invalid_response')
            .having((e) => e.status, 'status', 502),
      ),
    );
  });

  test('Famio answers', () async {
    final info = await serverAnswering(
      200,
      '{"name":"famio","version":"2.0.53","setupRequired":false}',
      'application/json',
    ).health();
    expect(info.version, '2.0.53');
  });
}

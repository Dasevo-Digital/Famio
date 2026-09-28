import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;

  setUp(() => app = FamioServerApp.inMemory());
  tearDown(() => app.close());

  Future<String> page(String url, [Map<String, String>? headers]) async {
    final response = await app.handler(
      Request('GET', Uri.parse(url), headers: headers),
    );
    expect(response.statusCode, 200);
    return response.readAsString();
  }

  test('behind a TLS proxy the https address is shown', () async {
    final html = await page('http://famio.example.org/', {
      'x-forwarded-proto': 'https',
    });
    expect(html, contains('https://famio.example.org<'));
    expect(html, isNot(contains(':8765')));
    expect(html, isNot(contains('Add-on')));
  });

  test('the public address wins', () async {
    app.settings.update({'publicUrl': 'https://famio.example.org'});
    final html = await page('http://192.168.1.10:8765/');
    expect(html, contains('https://famio.example.org<'));
  });

  test('directly: the port that was used', () async {
    expect(
      await page('http://192.168.1.10:8765/'),
      contains('http://192.168.1.10:8765<'),
    );
    expect(
      await page('https://192.168.1.10:8766/'),
      contains('https://192.168.1.10:8766<'),
    );
  });
}

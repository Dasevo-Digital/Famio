import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/landing_page.dart';
import 'package:famio_shared/famio_shared.dart';
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

  test('security.txt names the private reporting channel', () async {
    final response = await app.handler(
      Request(
        'GET',
        Uri.parse('https://famio.example.org/.well-known/security.txt'),
      ),
    );
    expect(response.statusCode, 200);
    expect(response.mimeType, 'text/plain');
    final text = await response.readAsString();
    expect(text, contains('Contact: ${FamioApi.securityContact}\n'));
    final expires = DateTime.parse(
      RegExp(r'^Expires: (.+)$', multiLine: true).firstMatch(text)!.group(1)!,
    );
    expect(
      expires.isAfter(DateTime.now().add(const Duration(days: 150))),
      isTrue,
    );
    expect(
      expires.isBefore(DateTime.now().add(const Duration(days: 365))),
      isTrue,
    );
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

  test('only the password script may run, by its hash', () async {
    final response = await app.handler(
      Request('GET', Uri.parse('http://192.168.1.10:8765/')),
    );
    final policy = response.headers['content-security-policy']!;
    expect(policy, isNot(contains('unsafe-inline\'; frame')));
    expect(policy, isNot(contains("script-src 'self'")));
    expect(response.headers['x-powered-by'], isNull);

    final html = landingPage(
      member: const FamilyMember(
        id: 'm',
        username: 'mama',
        displayName: 'Mama',
      ),
      hasPassword: true,
      address: 'https://famio.example.org',
      version: 'test',
    );
    final script = RegExp(
      r'<script>(.*)</script>',
      dotAll: true,
    ).firstMatch(html)!.group(1)!;
    final hash = base64.encode(sha256.convert(utf8.encode(script)).bytes);
    expect(policy, contains("script-src 'sha256-$hash'"));
  });
}

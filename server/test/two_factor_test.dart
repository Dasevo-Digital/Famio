import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// Answers of the server as a map plus `_status`.
Future<Map<String, Object?>> call(
  Uri base,
  String method,
  String path, {
  String? token,
  Object? body,
}) async {
  final request = http.Request(method, base.resolve(path))
    ..headers['content-type'] = 'application/json';
  if (token != null) request.headers['authorization'] = 'Bearer $token';
  if (body != null) request.body = jsonEncode(body);
  final response = await http.Response.fromStream(await request.send());
  final decoded = response.headers['content-type']!.contains('json')
      ? jsonDecode(response.body)
      : {'html': response.body};
  return {
    '_status': response.statusCode,
    if (decoded is Map) ...decoded.cast(),
  };
}

String jwt(Map<String, Object?> claims) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part(claims)}.c2lnbmF0dXJl';
}

void main() {
  group('TOTP', () {
    // RFC 6238, appendix B (SHA1, secret "12345678901234567890").
    final secret = Totp.base32Encode(utf8.encode('12345678901234567890'));

    test('matches the RFC test vectors', () {
      expect(secret, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
      expect(Totp.code(secret, 59 ~/ 30), '287082');
      expect(Totp.code(secret, 1111111109 ~/ 30), '081804');
      expect(Totp.code(secret, 1234567890 ~/ 30), '005924');
      expect(Totp.code(secret, 2000000000 ~/ 30), '279037');
    });

    test('allows one step of drift, never a used step', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1111111109 * 1000);
      final step = Totp.stepOf(now);
      expect(
        Totp.verify(secret, Totp.code(secret, step - 1), now: now),
        step - 1,
      );
      expect(
        Totp.verify(secret, Totp.code(secret, step - 2), now: now),
        isNull,
      );
      expect(
        Totp.verify(secret, Totp.code(secret, step), now: now, usedStep: step),
        isNull,
      );
      expect(Totp.verify(secret, 'abcdef', now: now), isNull);
    });

    test('link for authenticator apps', () {
      final uri = Totp.uri('ABC', account: 'mama', issuer: 'Famio');
      expect(
        uri.toString(),
        startsWith('otpauth://totp/Famio:mama?secret=ABC'),
      );
      expect(uri.queryParameters['issuer'], 'Famio');
    });
  });

  group('server', () {
    late HttpServer server;
    late FamioServerApp app;
    late Uri base;
    late String admin;
    // Fake OpenID provider.
    late String? nonce;
    var idpSubject = 'sub-1';
    var idpUsername = 'papa';

    Future<Map<String, Object?>> login(
      String user, [
      String pw = 'geheim123',
    ]) => call(
      base,
      'POST',
      'api/auth/login',
      body: {'username': user, 'password': pw},
    );

    String now([int offset = 0]) {
      final secret = app.db.select(
        'SELECT totp_secret, totp_pending FROM users WHERE username = ?',
        ['mama'],
      ).first;
      final s = (secret['totp_secret'] ?? secret['totp_pending']) as String;
      return Totp.code(s, Totp.stepOf(DateTime.now()) + offset);
    }

    Future<List<String>> enable(String token) async {
      final begun = await call(
        base,
        'POST',
        'api/me/two-factor/totp',
        token: token,
      );
      expect(begun['uri'], contains('otpauth://totp/Famio:mama'));
      final confirmed = await call(
        base,
        'POST',
        'api/me/two-factor/totp/confirm',
        token: token,
        body: {'code': now()},
      );
      expect(confirmed['_status'], 200);
      return (confirmed['recoveryCodes'] as List).cast();
    }

    setUp(() async {
      nonce = null;
      idpSubject = 'sub-1';
      idpUsername = 'papa';
      app = FamioServerApp.inMemory(
        httpClient: MockClient((request) async {
          final url = request.url.toString();
          if (url.endsWith('/.well-known/openid-configuration')) {
            return http.Response(
              jsonEncode({
                'issuer': 'https://idp.example/',
                'authorization_endpoint': 'https://idp.example/authorize',
                'token_endpoint': 'https://idp.example/token',
              }),
              200,
            );
          }
          if (url == 'https://idp.example/token') {
            final form = Uri.splitQueryString(request.body);
            if (form['code'] != 'good' || form['client_secret'] != 's3cret') {
              return http.Response('{"error":"invalid_grant"}', 400);
            }
            expect(form['code_verifier'], isNotEmpty);
            return http.Response(
              jsonEncode({
                'id_token': jwt({
                  'iss': 'https://idp.example/',
                  'aud': 'famio',
                  'sub': idpSubject,
                  'preferred_username': idpUsername,
                  'nonce': nonce,
                  'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
                }),
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );
      server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://localhost:${server.port}/');
      final setup = await call(
        base,
        'POST',
        'api/auth/setup',
        body: {
          'username': 'mama',
          'password': 'geheim123',
          'setupCode': app.setupCode,
        },
      );
      admin = setup['token'] as String;
      await call(
        base,
        'POST',
        'api/admin/users',
        token: admin,
        body: {'username': 'papa', 'password': 'geheim123'},
      );
    });

    tearDown(() async {
      await server.close(force: true);
      await app.close();
    });

    test('login asks for the code once two-factor is on', () async {
      final recovery = await enable(admin);
      expect(recovery, hasLength(10));

      final first = await login('mama');
      expect(first['twoFactorRequired'], isTrue);
      expect(first['token'], isNull);
      final wrong = await call(
        base,
        'POST',
        'api/auth/login/two-factor',
        body: {'challenge': first['challenge'], 'code': '000000'},
      );
      expect(wrong['_status'], 401);

      // The confirmation already used this step: the next one is needed.
      final ok = await call(
        base,
        'POST',
        'api/auth/login/two-factor',
        body: {'challenge': first['challenge'], 'code': now(1)},
      );
      expect(ok['_status'], 200, reason: '$ok');
      expect(ok['token'], isNotEmpty);

      // A recovery code works exactly once.
      for (final expected in [200, 401]) {
        final again = await login('mama');
        final result = await call(
          base,
          'POST',
          'api/auth/login/two-factor',
          body: {'challenge': again['challenge'], 'code': recovery.first},
        );
        expect(result['_status'], expected);
      }
      final status = await call(
        base,
        'GET',
        'api/me/two-factor',
        token: ok['token'] as String,
      );
      expect(status['twoFactor'], isTrue);
      expect(status['recoveryCodesLeft'], 9);
      expect(status['sessionVerified'], isTrue);
    });

    test('switching off needs password and code', () async {
      await enable(admin);
      final noPassword = await call(
        base,
        'POST',
        'api/me/two-factor/totp/disable',
        token: admin,
        body: {'code': now(1)},
      );
      expect(noPassword['_status'], 403);
      final off = await call(
        base,
        'POST',
        'api/me/two-factor/totp/disable',
        token: admin,
        body: {'password': 'geheim123', 'code': now(1)},
      );
      expect(off['_status'], 200);
      expect((await login('mama'))['token'], isNotEmpty);
    });

    test('mandatory for admins: set up first, then everything works', () async {
      await call(
        base,
        'PATCH',
        'api/admin/settings',
        token: admin,
        body: {'twoFactorRequired': 'admins'},
      );
      final token = (await login('mama'))['token'] as String;
      final blocked = await call(base, 'GET', 'api/members', token: token);
      expect(blocked['_status'], 403);
      expect(blocked['error'], 'two_factor_setup_required');
      // Papa is no admin.
      final papa = (await login('papa'))['token'] as String;
      expect(
        (await call(base, 'GET', 'api/members', token: papa))['_status'],
        200,
      );

      await enable(token);
      expect(
        (await call(base, 'GET', 'api/members', token: token))['_status'],
        200,
      );
      // The admin's first session (before the policy) must confirm a code.
      final old = await call(base, 'GET', 'api/members', token: admin);
      expect(old['error'], 'two_factor_required');
      await call(
        base,
        'POST',
        'api/me/two-factor/verify',
        token: admin,
        body: {'code': now(1)},
      );
      expect(
        (await call(base, 'GET', 'api/members', token: admin))['_status'],
        200,
      );
      // Mandatory: cannot be switched off by the member.
      final off = await call(
        base,
        'POST',
        'api/me/two-factor/totp/disable',
        token: admin,
        body: {'password': 'geheim123', 'code': now(1)},
      );
      expect(off['error'], 'two_factor_mandatory');
    });

    test('admins can reset a lost authenticator', () async {
      await enable(admin);
      final users = await call(base, 'GET', 'api/admin/users', token: admin);
      final mama = (users['users'] as List).cast<Map>().firstWhere(
        (u) => u['username'] == 'mama',
      );
      expect(mama['twoFactor'], isTrue);
      await call(
        base,
        'DELETE',
        'api/admin/users/${mama['id']}/two-factor',
        token: admin,
      );
      expect((await login('mama'))['token'], isNotEmpty);
    });

    group('single sign-on', () {
      Future<void> configure({bool matchUsername = false}) async {
        await call(
          base,
          'PATCH',
          'api/admin/settings',
          token: admin,
          body: {'publicUrl': 'https://famio.example.org'},
        );
        final saved = await call(
          base,
          'PUT',
          'api/admin/sso',
          token: admin,
          body: {
            'issuer': 'https://idp.example/',
            'clientId': 'famio',
            'clientSecret': 's3cret',
            'label': 'Authentik',
            'matchUsername': matchUsername,
          },
        );
        expect(saved['_status'], 200, reason: '$saved');
        expect(
          saved['redirectUri'],
          'https://famio.example.org/api/auth/sso/callback',
        );
        expect(saved['clientSecret'], isNull);
      }

      /// Runs the browser part and returns the poll result.
      Future<Map<String, Object?>> browser(
        Map<String, Object?> started, {
        String code = 'good',
      }) async {
        final url = Uri.parse(started['url'] as String);
        expect(url.queryParameters['code_challenge_method'], 'S256');
        nonce = url.queryParameters['nonce'];
        final page = await call(
          base,
          'GET',
          'api/auth/sso/callback?state=${url.queryParameters['state']}&code=$code',
        );
        expect(page['html'], isA<String>());
        return call(
          base,
          'POST',
          'api/auth/sso/poll',
          body: {'flow': started['flow'], 'secret': started['secret']},
        );
      }

      test('the login screen offers it once configured', () async {
        expect((await call(base, 'GET', 'api/health'))['sso'], isNull);
        await configure();
        expect((await call(base, 'GET', 'api/health'))['sso'], 'Authentik');
      });

      test('unknown accounts are refused, linked ones log in', () async {
        await configure();
        final unknown = await browser(
          await call(base, 'POST', 'api/auth/sso/start', body: {}),
        );
        expect(unknown['_status'], 403);
        expect(unknown['message'], contains('verknüpfen'));

        final papa = (await login('papa'))['token'] as String;
        final linked = await browser(
          await call(
            base,
            'POST',
            'api/auth/sso/start',
            token: papa,
            body: {'mode': 'link'},
          ),
        );
        expect(linked['status'], 'done');

        final pending = await call(
          base,
          'POST',
          'api/auth/sso/start',
          body: {'device': 'Handy'},
        );
        final waiting = await call(
          base,
          'POST',
          'api/auth/sso/poll',
          body: {'flow': pending['flow'], 'secret': pending['secret']},
        );
        expect(waiting['status'], 'pending');
        final done = await browser(pending);
        expect(done['status'], 'done');
        expect((done['member'] as Map)['username'], 'papa');
        final token = done['token'] as String;
        expect(
          (await call(base, 'GET', 'api/members', token: token))['_status'],
          200,
        );
        // Only once.
        final again = await call(
          base,
          'POST',
          'api/auth/sso/poll',
          body: {'flow': pending['flow'], 'secret': pending['secret']},
        );
        expect(again['_status'], 404);
      });

      test('a wrong code or secret gets nothing', () async {
        await configure(matchUsername: true);
        final started = await call(
          base,
          'POST',
          'api/auth/sso/start',
          body: {},
        );
        final bad = await browser(started, code: 'bad');
        expect(bad['_status'], 403);
        final stolen = await call(
          base,
          'POST',
          'api/auth/sso/poll',
          body: {'flow': started['flow'], 'secret': 'guess'},
        );
        expect(stolen['_status'], 404);
      });

      test('usernames can match without linking; SSO counts as 2FA', () async {
        await configure(matchUsername: true);
        await call(
          base,
          'PATCH',
          'api/admin/settings',
          token: admin,
          body: {'twoFactorRequired': 'all'},
        );
        final done = await browser(
          await call(base, 'POST', 'api/auth/sso/start', body: {}),
        );
        expect((done['member'] as Map)['username'], 'papa');
        expect(
          (await call(
            base,
            'GET',
            'api/members',
            token: done['token'] as String,
          ))['_status'],
          200,
        );
      });
    });
  });
}

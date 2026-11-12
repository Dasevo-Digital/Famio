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

/// The browser comes back from the provider: the page and the cookie that
/// ties the confirmation to this browser.
Future<({int status, String html, String? cookie, String? setCookie})> callback(
  Uri base,
  String query, {
  String? cookie,
}) async {
  final response = await http.get(
    base.resolve('api/auth/sso/callback?$query'),
    headers: {'cookie': ?cookie},
  );
  final set = response.headers['set-cookie'];
  return (
    status: response.statusCode,
    html: response.body,
    cookie: set == null ? cookie : set.split(';').first,
    setCookie: set,
  );
}

/// The browser's form on the confirmation page: state and code.
Future<({int status, String html})> confirm(
  Uri base,
  String state,
  String code, {
  String? cookie,
}) async {
  final response = await http.post(
    base.resolve('api/auth/sso/confirm'),
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'cookie': ?cookie,
    },
    body: {'state': state, 'code': code},
  );
  return (status: response.statusCode, html: response.body);
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
      String pw = 'tulpe-regal-7',
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
        body: {'password': 'tulpe-regal-7'},
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
          'password': 'tulpe-regal-7',
          'setupCode': app.setupCode,
        },
      );
      admin = setup['token'] as String;
      await call(
        base,
        'POST',
        'api/admin/users',
        token: admin,
        body: {'username': 'papa', 'password': 'tulpe-regal-7'},
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
        body: {'password': 'tulpe-regal-7', 'code': now(1)},
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
        body: {'password': 'tulpe-regal-7', 'code': now(1)},
      );
      expect(off['error'], 'two_factor_mandatory');
    });

    test('mandatory for adults: children are not asked', () async {
      await call(
        base,
        'POST',
        'api/admin/users',
        token: admin,
        body: {'username': 'mia', 'password': 'kind-wolke-5', 'role': 'child'},
      );
      await call(
        base,
        'PATCH',
        'api/admin/settings',
        token: admin,
        body: {'twoFactorRequired': 'adults'},
      );
      final papa = (await login('papa'))['token'] as String;
      expect(
        (await call(base, 'GET', 'api/members', token: papa))['error'],
        'two_factor_setup_required',
      );
      final mia = await call(
        base,
        'POST',
        'api/auth/login',
        body: {'username': 'mia', 'password': 'kind-wolke-5'},
      );
      expect(
        (await call(
          base,
          'GET',
          'api/members',
          token: mia['token'] as String,
        ))['_status'],
        200,
      );
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
        body: {'password': 'tulpe-regal-7'},
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

      /// Runs the browser part, with the code the app shows, and returns
      /// the poll result.
      Future<Map<String, Object?>> browser(
        Map<String, Object?> started, {
        String code = 'good',
      }) async {
        final url = Uri.parse(started['url'] as String);
        expect(url.queryParameters['code_challenge_method'], 'S256');
        nonce = url.queryParameters['nonce'];
        final state = url.queryParameters['state']!;
        final page = await callback(base, 'state=$state&code=$code');
        if (page.html.contains('name="code"')) {
          final confirmed = await confirm(
            base,
            state,
            started['code'] as String,
            cookie: page.cookie,
          );
          expect(confirmed.status, 200, reason: confirmed.html);
        }
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

      test(
        'a link someone else started signs nobody in without the code',
        () async {
          await configure(matchUsername: true);
          // Someone starts a sign-in and hands the link to a family member,
          // who completes it at the provider.
          final started = await call(
            base,
            'POST',
            'api/auth/sso/start',
            body: {'device': 'Fremdes Handy'},
          );
          expect(started['code'], matches(RegExp(r'^\d{6}$')));
          final url = Uri.parse(started['url'] as String);
          nonce = url.queryParameters['nonce'];
          final state = url.queryParameters['state']!;
          final page = await callback(base, 'state=$state&code=good');
          final cookie = page.cookie;
          final html = page.html;
          expect(html, contains('Fremdes Handy'));
          expect(html, contains('name="code"'));
          Future<Map<String, Object?>> poll() => call(
            base,
            'POST',
            'api/auth/sso/poll',
            body: {'flow': started['flow'], 'secret': started['secret']},
          );
          // Nothing yet, however often it asks.
          expect((await poll())['status'], 'pending');
          // Guessing the code ends the flow after a few tries.
          for (var i = 0; i < 4; i++) {
            final wrong = await confirm(base, state, '000000', cookie: cookie);
            expect(wrong.html, contains('stimmt nicht'));
            expect((await poll())['status'], 'pending');
          }
          final last = await confirm(base, state, '000000', cookie: cookie);
          expect(last.status, 400);
          expect((await poll())['_status'], 403);
          final late = await confirm(
            base,
            state,
            started['code'] as String,
            cookie: cookie,
          );
          expect(late.status, 400);
        },
      );

      test(
        'the confirmation page may not be framed and posts to itself',
        () async {
          await configure(matchUsername: true);
          final started = await call(
            base,
            'POST',
            'api/auth/sso/start',
            body: {},
          );
          final url = Uri.parse(started['url'] as String);
          nonce = url.queryParameters['nonce'];
          final response = await http.get(
            base.resolve(
              'api/auth/sso/callback?state=${url.queryParameters['state']}'
              '&code=good',
            ),
          );
          final policy = response.headers['content-security-policy']!;
          expect(policy, contains("form-action 'self'"));
          expect(policy, contains("frame-ancestors 'none'"));
        },
      );

      Future<Map<String, Object?>> poll(Map<String, Object?> started) => call(
        base,
        'POST',
        'api/auth/sso/poll',
        body: {'flow': started['flow'], 'secret': started['secret']},
      );

      test(
        'only the browser that came back from the provider confirms',
        () async {
          await configure();
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
          // Someone starts a sign-in: the link (with its state) and the code
          // are theirs.
          final started = await call(
            base,
            'POST',
            'api/auth/sso/start',
            body: {'device': 'Fremdes Handy'},
          );
          final url = Uri.parse(started['url'] as String);
          nonce = url.queryParameters['nonce'];
          final state = url.queryParameters['state']!;
          final code = started['code'] as String;
          // A family member opens the link, the provider vouches for them.
          final page = await callback(base, 'state=$state&code=good');
          expect(page.cookie, startsWith('famio_sso='));
          expect(page.setCookie, contains('HttpOnly'));
          expect(page.setCookie, contains('SameSite=Strict'));
          expect(page.setCookie, contains('Path=/api/auth/sso'));
          // State and code alone do nothing, nor does a made-up cookie.
          expect((await confirm(base, state, code)).status, 400);
          expect(
            (await confirm(base, state, code, cookie: 'famio_sso=x')).status,
            400,
          );
          final again = await callback(base, 'state=$state');
          expect(again.html, isNot(contains('name="code"')));
          expect((await poll(started))['status'], 'pending');
          // That browser may reload the form.
          expect(
            (await callback(base, 'state=$state', cookie: page.cookie)).html,
            contains('name="code"'),
          );
        },
      );

      test('a username match is checked again when confirming', () async {
        await configure(matchUsername: true);
        final started = await call(
          base,
          'POST',
          'api/auth/sso/start',
          body: {},
        );
        final url = Uri.parse(started['url'] as String);
        nonce = url.queryParameters['nonce'];
        final state = url.queryParameters['state']!;
        final page = await callback(base, 'state=$state&code=good');
        expect(page.html, contains('name="code"'));
        // Meanwhile papa links his own provider account.
        idpSubject = 'sub-2';
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
        final late = await confirm(
          base,
          state,
          started['code'] as String,
          cookie: page.cookie,
        );
        expect(late.status, 400);
        expect((await poll(started))['token'], isNull);
      });

      test('a member deleted before confirming is not linked', () async {
        await configure();
        final papa = (await login('papa'))['token'] as String;
        final started = await call(
          base,
          'POST',
          'api/auth/sso/start',
          token: papa,
          body: {'mode': 'link'},
        );
        final url = Uri.parse(started['url'] as String);
        nonce = url.queryParameters['nonce'];
        final state = url.queryParameters['state']!;
        final page = await callback(base, 'state=$state&code=good');
        final users = await call(base, 'GET', 'api/admin/users', token: admin);
        final papaId = (users['users'] as List).cast<Map>().firstWhere(
          (u) => u['username'] == 'papa',
        )['id'];
        final deleted = await call(
          base,
          'DELETE',
          'api/admin/users/$papaId',
          token: admin,
          body: {'password': 'tulpe-regal-7'},
        );
        expect(deleted['_status'], 200);
        final late = await confirm(
          base,
          state,
          started['code'] as String,
          cookie: page.cookie,
        );
        expect(late.status, 400);
        expect(app.db.select('SELECT * FROM sso_links'), isEmpty);
      });

      test('the confirmation reads only a few kilobytes', () async {
        // Chunked, without a length, and never finished.
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        addTearDown(socket.destroy);
        final chunk = 'state=${'x' * 8192}';
        socket.write(
          'POST /api/auth/sso/confirm HTTP/1.1\r\n'
          'Host: localhost\r\n'
          'Content-Type: application/x-www-form-urlencoded\r\n'
          'Transfer-Encoding: chunked\r\n\r\n'
          '${chunk.length.toRadixString(16)}\r\n$chunk\r\n',
        );
        // The server stops reading: it answers or drops the connection,
        // instead of waiting for the rest.
        final answer = await utf8.decoder
            .bind(socket)
            .join()
            .timeout(const Duration(seconds: 5));
        expect(answer, anyOf(isEmpty, startsWith('HTTP/1.1 413')));
      });

      test('one address cannot fill the table of open sign-ins', () async {
        await configure();
        for (var i = 0; i < 5; i++) {
          expect(
            (await call(
              base,
              'POST',
              'api/auth/sso/start',
              body: {},
            ))['_status'],
            200,
          );
        }
        expect(
          (await call(base, 'POST', 'api/auth/sso/start', body: {}))['_status'],
          429,
        );
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

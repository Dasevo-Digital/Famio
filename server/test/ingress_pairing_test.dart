import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

// The fixed service gateway of Home Assistant ingress, not a test device.
class _IngressConnection implements HttpConnectionInfo {
  @override
  InternetAddress get remoteAddress => InternetAddress('172.30.32.2');
  @override
  int get remotePort => 40000;
  @override
  int get localPort => 8080;
}

void main() {
  late FamioServerApp app;
  late Directory data;
  Future<(int, Map)> call(
    String method,
    String path, {
    bool ingress = false,
    bool assertedIdentity = false,
    Object? body,
    String? token,
  }) async {
    final r = await app.handler(
      Request(
        method,
        Uri.parse('http://famio.test/$path'),
        context: ingress
            ? {'shelf.io.connection_info': _IngressConnection()}
            : {},
        headers: {
          'content-type': 'application/json',
          'authorization': ?(token == null ? null : 'Bearer $token'),
          if (ingress || assertedIdentity) ...{
            'x-remote-user-id': 'fixture-ha-user',
            'x-remote-user-name': 'member',
            'x-remote-user-display-name': 'Member',
          },
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (r.statusCode, jsonDecode(await r.readAsString()) as Map);
  }

  setUp(() {
    FamioServerApp.initTimeZones();
    data = Directory.systemTemp.createTempSync('famio_ingress_pairing_');
    app = FamioServerApp(
      db: openFamioDatabase(':memory:'),
      dataDir: data.path,
      location: tz.getLocation('Europe/Berlin'),
      ingressAuth: true,
    );
  });
  tearDown(() async {
    await app.close();
    data.deleteSync(recursive: true);
  });

  test('a trusted ingress identity pairs once without a bearer', () async {
    final (status, me) = await call('GET', 'api/me', ingress: true);
    expect(status, 200);
    final (created, approval) = await call(
      'POST',
      'api/me/device-pairings',
      ingress: true,
    );
    expect(created, 201);
    final (paired, login) = await call(
      'POST',
      'api/auth/device-pair',
      body: {'secret': approval['secret']},
    );
    expect(paired, 200);
    expect((login['member'] as Map)['id'], me['id']);
    final (_, factors) = await call(
      'GET',
      'api/me/two-factor',
      token: login['token'] as String,
    );
    expect(factors['sessionVerified'], isFalse);
    expect(
      (await call(
        'POST',
        'api/auth/device-pair',
        body: {'secret': approval['secret']},
      )).$1,
      401,
    );
  });

  for (final action in ['revoke', 'password', 'logout', 'delete']) {
    test('ingress approvals are invalid after $action', () async {
      final (_, me) = await call('GET', 'api/me', ingress: true);
      final id = me['id'] as String;
      final (_, approval) = await call(
        'POST',
        'api/me/device-pairings',
        ingress: true,
        token: 'not-a-session',
      );
      switch (action) {
        case 'revoke':
          app.accounts.deleteSessions(id);
        case 'password':
          await app.accounts.setPassword(id, 'tulpe-regal-7');
        case 'logout':
          expect(
            (await call('POST', 'api/auth/logout', ingress: true)).$1,
            200,
          );
        case 'delete':
          app.accounts.delete(id);
      }
      expect(
        (await call(
          'POST',
          'api/auth/device-pair',
          body: {'secret': approval['secret']},
        )).$1,
        401,
      );
    });
  }
  test('untrusted headers cannot approve a pairing', () async {
    expect(
      (await call('POST', 'api/me/device-pairings', assertedIdentity: true)).$1,
      401,
    );
  });
  test(
    'an unrelated strong bearer does not verify the ingress identity',
    () async {
      final other = app.accounts.create(
        username: 'other',
        displayName: 'Other',
      );
      final strong = app.accounts.createSession(other.id, method: 'totp');
      final (_, me) = await call('GET', 'api/me', ingress: true);
      final (created, approval) = await call(
        'POST',
        'api/me/device-pairings',
        ingress: true,
        token: strong,
      );
      expect(created, 201);
      final (paired, login) = await call(
        'POST',
        'api/auth/device-pair',
        body: {'secret': approval['secret']},
      );
      expect(paired, 200);
      expect((login['member'] as Map)['id'], me['id']);
      expect((login['member'] as Map)['id'], isNot(other.id));
      final (_, factors) = await call(
        'GET',
        'api/me/two-factor',
        token: login['token'] as String,
      );
      expect(factors['sessionVerified'], isFalse);
    },
  );
}

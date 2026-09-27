import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// Protections for sensitive (health) data: transport of credentials,
/// session lifetime, file delivery, CSRF and resource limits.
void main() {
  late FamioServerApp app;
  late HttpServer server;
  late Uri base;
  late String token;
  final audit = <String>[];

  Future<http.Response> send(
    String method,
    String path, {
    Object? body,
    String? auth,
    Map<String, String> headers = const {'content-type': 'application/json'},
  }) async {
    final request = http.Request(method, base.resolve(path))
      ..headers.addAll(headers);
    if (auth != null) request.headers['authorization'] = 'Bearer $auth';
    if (body is List<int>) {
      request.bodyBytes = body;
    } else if (body is String) {
      request.body = body;
    } else if (body != null) {
      request.body = jsonEncode(body);
    }
    return http.Response.fromStream(await request.send());
  }

  Map<String, Object?> json(http.Response r) =>
      (jsonDecode(r.body) as Map).cast();

  Future<String> login(String user, String password) async {
    final r = await send(
      'POST',
      'api/auth/login',
      body: {'username': user, 'password': password},
    );
    expect(r.statusCode, 200, reason: r.body);
    return json(r)['token'] as String;
  }

  setUp(() async {
    audit.clear();
    FamioServerApp.initTimeZones();
    app = FamioServerApp(
      db: openFamioDatabase(':memory:'),
      location: tz.getLocation('Europe/Berlin'),
      dataDir: Directory.systemTemp.createTempSync('famio_hard_').path,
      auditLog: audit.add,
    );
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}/');
    final r = await send(
      'POST',
      'api/auth/setup',
      body: {'username': 'mama', 'password': 'geheim123'},
    );
    token = json(r)['token'] as String;
  });

  tearDown(() => server.close(force: true));

  test('tokens are only accepted in the Authorization header', () async {
    expect((await send('GET', 'api/me', auth: token)).statusCode, 200);
    expect((await send('GET', 'api/me?token=$token')).statusCode, 401);
  });

  test('JSON endpoints refuse other content types (CSRF)', () async {
    final r = await send(
      'PUT',
      'api/me/password',
      auth: token,
      headers: {'content-type': 'text/plain'},
      body: jsonEncode({'currentPassword': 'geheim123', 'newPassword': 'x'}),
    );
    expect(r.statusCode, 415);
  });

  test('oversized JSON bodies are refused', () async {
    final r = await send(
      'POST',
      'api/sync',
      auth: token,
      body: '{"x":"${'a' * (FamioApi.maxJsonBytes + 10)}"}',
    );
    expect(r.statusCode, 413);
  });

  test('security headers and no caching of API data', () async {
    final r = await send('GET', 'api/me', auth: token);
    expect(r.headers['x-content-type-options'], 'nosniff');
    expect(r.headers['referrer-policy'], 'no-referrer');
    expect(r.headers['cache-control'], 'no-store');
    expect(r.headers['strict-transport-security'], isNull);
  });

  test('uploaded HTML is never rendered by a browser', () async {
    Future<http.Response> upload(String name, String mime, List<int> data) =>
        send(
          'POST',
          'api/files?name=$name',
          auth: token,
          headers: {'content-type': mime},
          body: data,
        );
    final html = json(
      await upload(
        'x.html',
        'text/html',
        utf8.encode('<script>alert(1)</script>'),
      ),
    );
    final r = await send('GET', 'api/files/${html['id']}', auth: token);
    expect(r.headers['content-type'], 'application/octet-stream');
    expect(r.headers['content-disposition'], startsWith('attachment'));
    expect(r.headers['content-security-policy'], contains('sandbox'));

    final png = json(await upload('a.png', 'image/png', [137, 80, 78, 71]));
    final p = await send('GET', 'api/files/${png['id']}', auth: token);
    expect(p.headers['content-type'], 'image/png');
    expect(p.headers['content-disposition'], startsWith('inline'));
  });

  test('changing the own password signs out other devices', () async {
    final phone = await login('mama', 'geheim123');
    final r = await send(
      'PUT',
      'api/me/password',
      auth: token,
      body: {'currentPassword': 'geheim123', 'newPassword': 'neu-geheim-9'},
    );
    expect(json(r)['signedOut'], 1);
    expect((await send('GET', 'api/me', auth: phone)).statusCode, 401);
    expect((await send('GET', 'api/me', auth: token)).statusCode, 200);
  });

  test('guessing the current password with a session is throttled', () async {
    for (var i = 0; i < 5; i++) {
      await send(
        'PUT',
        'api/me/password',
        auth: token,
        body: {'currentPassword': 'falsch-$i', 'newPassword': 'neu-geheim-9'},
      );
    }
    final r = await send(
      'PUT',
      'api/me/password',
      auth: token,
      body: {'currentPassword': 'geheim123', 'newPassword': 'neu-geheim-9'},
    );
    expect(r.statusCode, 429);
  });

  test('idle sessions expire', () async {
    final old = DateTime.now()
        .subtract(Accounts.sessionIdleTimeout + const Duration(days: 1))
        .millisecondsSinceEpoch;
    app.db.execute('UPDATE sessions SET last_seen = ?', [old]);
    expect((await send('GET', 'api/me', auth: token)).statusCode, 401);
    expect(app.accounts.deleteExpiredSessions(), 1);
  });

  test('old password hashes are upgraded at login', () async {
    final stored =
        app.db.select('SELECT password_hash FROM users').first.columnAt(0)
            as String;
    expect(stored, contains('\$${Accounts.iterations}\$'));
    // Simulate a hash from an older version with fewer rounds.
    final id = app.accounts.members().single.id;
    app.db.execute('UPDATE users SET password_hash = ? WHERE id = ?', [
      _legacyHash,
      id,
    ]);
    await login('mama', 'geheim123');
    final upgraded =
        app.db.select('SELECT password_hash FROM users').first.columnAt(0)
            as String;
    expect(upgraded, contains('\$${Accounts.iterations}\$'));
    await login('mama', 'geheim123');
  });

  test('admin actions are audited', () async {
    final r = await send(
      'POST',
      'api/admin/users',
      auth: token,
      body: {'username': 'kind', 'password': 'kind12345'},
    );
    final id = json(r)['id'];
    await send(
      'PUT',
      'api/admin/users/$id/password',
      auth: token,
      body: {'password': 'kind-neu-123'},
    );
    await send('DELETE', 'api/admin/users/$id', auth: token);
    expect(audit.join('\n'), contains('@mama hat @kind angelegt'));
    expect(audit.join('\n'), contains('Passwort von @kind zurückgesetzt'));
    expect(audit.join('\n'), contains('@mama hat @kind entfernt'));
  });

  test('HSTS is sent behind a TLS-terminating proxy only', () async {
    final behindProxy = FamioServerApp(
      db: openFamioDatabase(':memory:'),
      location: app.location,
      dataDir: Directory.systemTemp.createTempSync('famio_hsts_').path,
      trustProxy: true,
    );
    final s = await io.serve(
      behindProxy.handler,
      InternetAddress.loopbackIPv4,
      0,
    );
    final r = await http.get(
      Uri.parse('http://localhost:${s.port}/api/health'),
      headers: {'x-forwarded-proto': 'https'},
    );
    expect(r.headers['strict-transport-security'], contains('max-age'));
    await s.close(force: true);
  });
}

/// "geheim123" hashed with 120 000 rounds (Famio 0.4).
const _legacyHash =
    r'pbkdf2_sha256$120000$AAAAAAAAAAAAAAAAAAAAAA==$0AEeuWOKiPUP5Fk9iH+E/3qaV5m8+vXEkhxF1rW30UE=';

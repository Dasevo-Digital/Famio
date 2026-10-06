import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String token;

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final response = await app.handler(
      Request(
        method,
        Uri.parse('http://localhost/$path'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (
      response.statusCode,
      (jsonDecode(await response.readAsString()) as Map)
          .cast<String, Object?>(),
    );
  }

  setUp(() async {
    app = FamioServerApp.inMemory();
    final admin = app.accounts.create(
      username: 'mama',
      displayName: 'Mama',
      passwordHash: await app.accounts.hashPassword('geheim123'),
      isAdmin: true,
    );
    token = app.accounts.createSession(admin.id, method: 'password');
  });
  tearDown(() => app.close());

  test('admins switch areas off for every app', () async {
    expect((await call('GET', 'api/config')).$2['hiddenModules'], isEmpty);
    final (status, _) = await call('PATCH', 'api/admin/settings', {
      'hiddenModules': ['budget', 'meals', 'budget'],
    });
    expect(status, 200);
    expect((await call('GET', 'api/config')).$2['hiddenModules'], [
      'budget',
      'meals',
    ]);
    // Start and settings cannot be switched off; unknown names neither.
    for (final bad in [
      ['home'],
      ['settings'],
      ['finanzen'],
      'budget',
    ]) {
      final (code, body) = await call('PATCH', 'api/admin/settings', {
        'hiddenModules': bad,
      });
      expect(code, 400, reason: '$bad');
      expect(body['error'], 'invalid_modules');
    }
    // An empty list shows everything again.
    await call('PATCH', 'api/admin/settings', {'hiddenModules': <String>[]});
    expect((await call('GET', 'api/config')).$2['hiddenModules'], isEmpty);
  });

  test('the federal state for public holidays', () async {
    expect((await call('GET', 'api/config')).$2['holidayRegion'], isNull);
    final (bad, body) = await call('PATCH', 'api/admin/settings', {
      'holidayRegion': 'Bayern',
    });
    expect((bad, body['error']), (400, 'invalid_region'));
    await call('PATCH', 'api/admin/settings', {'holidayRegion': 'BY'});
    expect((await call('GET', 'api/config')).$2['holidayRegion'], 'BY');
    await call('PATCH', 'api/admin/settings', {'holidayRegion': null});
    expect((await call('GET', 'api/config')).$2['holidayRegion'], isNull);
  });
}

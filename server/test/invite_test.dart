import 'dart:convert';

import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late String admin;

  Future<(int, Map)> call(
    String method,
    String path, {
    String? token,
    Object? body,
  }) async {
    final r = await app.handler(
      Request(
        method,
        Uri.parse('http://famio.test/$path'),
        headers: {
          'authorization': ?(token == null ? null : 'Bearer $token'),
          'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final text = await r.readAsString();
    return (r.statusCode, text.isEmpty ? {} : jsonDecode(text) as Map);
  }

  setUp(() async {
    app = FamioServerApp.inMemory();
    final (_, setup) = await call(
      'POST',
      'api/auth/setup',
      body: {
        'username': 'mama',
        'password': 'geheim123',
        'setupCode': app.setupCode,
      },
    );
    admin = setup['token'] as String;
  });

  tearDown(() => app.close());

  test('a child joins with a code and chooses the password', () async {
    final (created, invite) = await call(
      'POST',
      'api/admin/invites',
      token: admin,
      body: {'role': 'child', 'displayName': 'Mia'},
    );
    expect(created, 201);
    final code = invite['code'] as String;
    expect(code, matches(RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}$')));
    final (_, open) = await call('GET', 'api/admin/invites', token: admin);
    expect((open['invites'] as List).single['role'], 'child');
    expect(jsonEncode(open), isNot(contains(code)), reason: 'only a hash');

    final (checked, info) = await call(
      'POST',
      'api/auth/invite/check',
      body: {'code': code.toLowerCase().replaceAll('-', ' ')},
    );
    expect((checked, info['displayName']), (200, 'Mia'));

    final (weak, _) = await call(
      'POST',
      'api/auth/invite',
      body: {'code': code, 'username': 'mia', 'password': 'kurz'},
    );
    expect(weak, 400, reason: 'the code stays valid');
    final (joined, session) = await call(
      'POST',
      'api/auth/invite',
      body: {
        'code': code,
        'username': 'mia',
        'password': 'mias-geheimnis',
        'device': 'Handy',
      },
    );
    expect(joined, 200);
    expect((session['member'] as Map)['role'], 'child');
    expect((session['member'] as Map)['displayName'], 'Mia');
    expect((session['member'] as Map)['isAdmin'], false);
    final (again, _) = await call(
      'POST',
      'api/auth/invite',
      body: {'code': code, 'username': 'mia2', 'password': 'mias-geheimnis'},
    );
    expect(again, 404, reason: 'used up');
    final (_, after) = await call('GET', 'api/admin/invites', token: admin);
    expect(after['invites'], isEmpty);
  });

  test('only admins invite; guessing is throttled', () async {
    final (created, invite) = await call(
      'POST',
      'api/admin/invites',
      token: admin,
      body: {'role': 'guest'},
    );
    expect(created, 201);
    final (revoked, _) = await call(
      'DELETE',
      'api/admin/invites/${invite['id']}',
      token: admin,
    );
    expect(revoked, 200);
    final (gone, _) = await call(
      'POST',
      'api/auth/invite/check',
      body: {'code': invite['code']},
    );
    expect(gone, 404);
    expect(
      (await call('POST', 'api/admin/invites', body: {'role': 'adult'})).$1,
      401,
    );
    var status = 0;
    for (var i = 0; i < 30 && status != 429; i++) {
      (status, _) = await call(
        'POST',
        'api/auth/invite/check',
        body: {'code': 'XXXX-XXX$i'},
      );
    }
    expect(status, 429);
  });
}

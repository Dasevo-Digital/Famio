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
        'password': 'tulpe-regal-7',
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

  test('an invitation ends with the admin rights of whoever made it', () async {
    Future<String> inviteBy(String token) async {
      final (created, invite) = await call(
        'POST',
        'api/admin/invites',
        token: token,
        body: {'role': 'adult'},
      );
      expect(created, 201);
      return invite['code'] as String;
    }

    Future<int> check(String code) async =>
        (await call('POST', 'api/auth/invite/check', body: {'code': code})).$1;

    final papa = app.accounts.create(
      username: 'papa',
      displayName: 'Papa',
      isAdmin: true,
    );
    final oma = app.accounts.create(
      username: 'oma',
      displayName: 'Oma',
      isAdmin: true,
    );
    final opa = app.accounts.create(
      username: 'opa',
      displayName: 'Opa',
      isAdmin: true,
    );
    final byMama = await inviteBy(admin);
    final byPapa = await inviteBy(app.accounts.createSession(papa.id));
    final byOma = await inviteBy(app.accounts.createSession(oma.id));
    final byOpa = await inviteBy(app.accounts.createSession(opa.id));

    final (demoted, _) = await call(
      'PATCH',
      'api/admin/users/${papa.id}',
      token: admin,
      body: {'isAdmin': false},
    );
    expect(demoted, 200);
    expect(await check(byPapa), 404);
    final (deleted, _) = await call(
      'DELETE',
      'api/admin/users/${oma.id}',
      token: admin,
    );
    expect(deleted, 200);
    expect(await check(byOma), 404);
    // Also when the rights go some other way.
    app.accounts.update(opa.id, isAdmin: false);
    expect(await check(byOpa), 404);
    final (joined, _) = await call(
      'POST',
      'api/auth/invite',
      body: {'code': byOpa, 'username': 'neu', 'password': 'tulpe-regal-8'},
    );
    expect(joined, 404);
    expect(await check(byMama), 200);
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

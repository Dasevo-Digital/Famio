import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

void main() {
  late FamioServerApp app;
  late HttpServer server;
  late Uri base;

  setUp(() async {
    app = FamioServerApp.inMemory();
    server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://localhost:${server.port}');
  });

  tearDown(() => server.close(force: true));

  Future<(int, Map<String, Object?>)> call(
    String method,
    String path, {
    Object? body,
    String? token,
  }) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['content-type'] = 'application/json';
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await request.send());
    return (
      response.statusCode,
      (jsonDecode(response.body) as Map).cast<String, Object?>(),
    );
  }

  Future<String> login(
    String username,
    String password, [
    String? device,
  ]) async {
    final (status, body) = await call(
      'POST',
      '/api/auth/login',
      body: {'username': username, 'password': password, 'device': device},
    );
    expect(status, 200, reason: '$body');
    return body['token'] as String;
  }

  /// Admin "mama" and member "kind"; returns (adminToken, kindToken, kindId).
  Future<(String, String, String)> family() async {
    final (_, setup) = await call(
      'POST',
      '/api/auth/setup',
      body: {
        'username': 'mama',
        'displayName': 'Mama',
        'password': 'tulpe-regal-7',
        'setupCode': app.setupCode,
      },
    );
    final admin = setup['token'] as String;
    final (status, kind) = await call(
      'POST',
      '/api/admin/users',
      token: admin,
      body: {
        'username': 'kind',
        'displayName': 'Kind',
        'password': 'kind-wolke-5',
      },
    );
    expect(status, 201);
    return (
      admin,
      await login('kind', 'kind-wolke-5', 'Tablet'),
      kind['id'] as String,
    );
  }

  test('only admins reach the admin API', () async {
    final (admin, kind, kindId) = await family();
    for (final (method, path) in [
      ('GET', '/api/admin/overview'),
      ('GET', '/api/admin/users'),
      ('PATCH', '/api/admin/settings'),
      ('PATCH', '/api/admin/users/$kindId'),
      ('DELETE', '/api/admin/users/$kindId/sessions'),
    ]) {
      expect((await call(method, path, token: kind, body: {})).$1, 403);
      expect((await call(method, path, body: {})).$1, 401);
    }
    expect((await call('GET', '/api/admin/overview', token: admin)).$1, 200);
  });

  test('apps send their version; older ones are marked for admins', () async {
    final (admin, kind, _) = await family();
    Future<void> use(String token, String version) async {
      final request = http.Request('GET', base.resolve('/api/me/sessions'))
        ..headers['authorization'] = 'Bearer $token'
        ..headers[appVersionHeader] = version;
      expect((await request.send()).statusCode, 200);
    }

    await use(admin, '$serverVersion macos');
    await use(kind, '1.0.16 ios');
    final (_, overview) = await call(
      'GET',
      '/api/admin/overview',
      token: admin,
    );
    expect(ServerOverview.fromJson(overview).outdatedApps, [
      (member: 'Kind', device: 'Tablet', version: '1.0.16'),
    ]);
    DeviceSession mine(Map<String, Object?> body) => DeviceSession.fromJson(
      ((body['sessions'] as List).single as Map).cast(),
    );
    final kindSession = mine(
      (await call('GET', '/api/me/sessions', token: kind)).$2,
    );
    expect(kindSession.appVersion, '1.0.16 ios');
    expect(kindSession.outdated, isTrue);

    // Anything but a version is not stored; an update clears the mark.
    await use(admin, '<script>');
    await use(kind, '$serverVersion ios');
    final adminSession = mine(
      (await call('GET', '/api/me/sessions', token: admin)).$2,
    );
    expect(adminSession.appVersion, '$serverVersion macos');
    expect(adminSession.outdated, isFalse);
    expect(
      ServerOverview.fromJson(
        (await call('GET', '/api/admin/overview', token: admin)).$2,
      ).outdatedApps,
      isEmpty,
    );
    expect(DeviceSession.parseAppHeader('2.0.1 android'), '2.0.1 android');
    expect(DeviceSession.parseAppHeader('2.0.1'), '2.0.1');
    expect(DeviceSession.parseAppHeader('2.0.1 Android; DROP'), isNull);
  });

  test('admins control bounded location-history retention', () async {
    final (admin, kind, _) = await family();
    var (status, body) = await call(
      'PATCH',
      '/api/admin/settings',
      token: admin,
      body: {'locationHistoryDays': 30},
    );
    expect(status, 200, reason: '$body');
    expect((body['effective'] as Map)['locationHistoryDays'], 30);

    (status, body) = await call(
      'PATCH',
      '/api/admin/settings',
      token: kind,
      body: {'locationHistoryDays': 30},
    );
    expect(status, 403, reason: '$body');
    (status, body) = await call(
      'PATCH',
      '/api/admin/settings',
      token: admin,
      body: {'locationHistoryDays': 0},
    );
    expect(status, 400, reason: '$body');
  });

  test('user list shows devices; admin edits a member', () async {
    final (admin, kind, kindId) = await family();
    final (_, list) = await call('GET', '/api/admin/users', token: admin);
    final users = [
      for (final u in list['users'] as List)
        AdminUser.fromJson((u as Map).cast()),
    ];
    final child = users.firstWhere((u) => u.member.id == kindId);
    expect(child.sessions.single.device, 'Tablet');
    expect(child.hasPassword, isTrue);
    expect(
      users.firstWhere((u) => u.member.isAdmin).sessions.single.current,
      isTrue,
    );

    final (status, updated) = await call(
      'PATCH',
      '/api/admin/users/$kindId',
      token: admin,
      body: {'displayName': 'Lina', 'username': 'lina', 'isAdmin': true},
    );
    expect(status, 200, reason: '$updated');
    expect(updated['displayName'], 'Lina');
    expect(updated['isAdmin'], isTrue);
    // Session stays valid, new username works.
    expect((await call('GET', '/api/me', token: kind)).$2['username'], 'lina');
    await login('lina', 'kind-wolke-5');

    expect(
      (await call(
        'PATCH',
        '/api/admin/users/$kindId',
        token: admin,
        body: {'username': 'MAMA'},
      )).$1,
      409,
    );
  });

  test('birthdays of members: own, by admin, cleared, validated', () async {
    final (admin, kind, kindId) = await family();
    var (status, body) = await call(
      'PATCH',
      '/api/me',
      body: {'birthday': '1985-06-12'},
      token: admin,
    );
    expect(status, 200, reason: '$body');
    expect(body['birthday'], '1985-06-12');
    (status, body) = await call(
      'PATCH',
      '/api/admin/users/$kindId',
      body: {'birthday': '--03-04'},
      token: admin,
    );
    expect(body['birthday'], '--03-04');
    // Other changes leave the birthday alone.
    (status, body) = await call(
      'PATCH',
      '/api/me',
      body: {'displayName': 'Mama'},
      token: admin,
    );
    expect(body['birthday'], '1985-06-12');
    (status, body) = await call(
      'PATCH',
      '/api/me',
      body: {'birthday': '12.6.1985'},
      token: kind,
    );
    expect(status, 400);
    (status, body) = await call(
      'PATCH',
      '/api/me',
      body: {'birthday': null},
      token: admin,
    );
    expect(body.containsKey('birthday'), isFalse);
    final members = FamilyMember.fromJson(
      ((await call('GET', '/api/members', token: kind)).$2['members'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((m) => m['id'] == kindId),
    );
    expect(members.birthday, const Birthday(3, 4));
  });

  test('the last admin cannot be demoted', () async {
    final (admin, _, kindId) = await family();
    final (_, me) = await call('GET', '/api/me', token: admin);
    final (status, body) = await call(
      'PATCH',
      '/api/admin/users/${me['id']}',
      token: admin,
      body: {'isAdmin': false},
    );
    expect(status, 400);
    expect(body['error'], 'last_admin');

    await call(
      'PATCH',
      '/api/admin/users/$kindId',
      token: admin,
      body: {'isAdmin': true},
    );
    expect(
      (await call(
        'PATCH',
        '/api/admin/users/${me['id']}',
        token: admin,
        body: {'isAdmin': false},
      )).$1,
      200,
    );
  });

  test('password reset signs the member out everywhere', () async {
    final (admin, kind, kindId) = await family();
    final (status, body) = await call(
      'PUT',
      '/api/admin/users/$kindId/password',
      token: admin,
      body: {'password': 'neu-geheim-1'},
    );
    expect(status, 200);
    expect(body['signedOut'], 1);
    expect((await call('GET', '/api/me', token: kind)).$1, 401);
    await login('kind', 'neu-geheim-1');
    expect(
      (await call(
        'PUT',
        '/api/admin/users/$kindId/password',
        token: admin,
        body: {'password': 'kurz'},
      )).$1,
      400,
    );
  });

  test('sign out single device and own other devices', () async {
    final (admin, kind, kindId) = await family();
    final phone = await login('kind', 'kind-wolke-5', 'Handy');
    final (_, list) = await call('GET', '/api/me/sessions', token: kind);
    final sessions = [
      for (final s in list['sessions'] as List)
        DeviceSession.fromJson((s as Map).cast()),
    ];
    expect(sessions, hasLength(2));
    final handy = sessions.firstWhere((s) => s.device == 'Handy');
    await call(
      'DELETE',
      '/api/admin/users/$kindId/sessions/${handy.id}',
      token: admin,
    );
    expect((await call('GET', '/api/me', token: phone)).$1, 401);
    expect((await call('GET', '/api/me', token: kind)).$1, 200);

    // "Everywhere" on yourself keeps the current device.
    final (_, me) = await call('GET', '/api/me', token: admin);
    final laptop = await login('mama', 'tulpe-regal-7', 'Laptop');
    await call('DELETE', '/api/admin/users/${me['id']}/sessions', token: admin);
    expect((await call('GET', '/api/me', token: laptop)).$1, 401);
    expect((await call('GET', '/api/me', token: admin)).$1, 200);
  });

  test('members edit their own profile, not their admin flag', () async {
    final (_, kind, _) = await family();
    final (status, body) = await call(
      'PATCH',
      '/api/me',
      token: kind,
      body: {'displayName': 'Lina', 'color': 0xFFAABBCC, 'isAdmin': true},
    );
    expect(status, 200);
    expect(body['displayName'], 'Lina');
    expect(body['color'], 0xFFAABBCC);
    expect(body['isAdmin'], isFalse);
  });

  test('settings apply at runtime and fall back to defaults', () async {
    final (admin, _, _) = await family();
    var (status, body) = await call(
      'PATCH',
      '/api/admin/settings',
      token: admin,
      body: {
        'publicUrl': 'https://famio.example.org',
        'timeZone': 'Europe/Vienna',
        'maxUploadMb': 5,
        'mapTileUrl': 'https://tiles.example.org/{z}/{x}/{y}.png',
        'mapProvider': 'martin',
      },
    );
    expect(status, 200, reason: '$body');
    // Every member's app learns where map tiles come from.
    final (_, config) = await call('GET', '/api/config', token: admin);
    expect(config['mapTileUrl'], 'https://tiles.example.org/{z}/{x}/{y}.png');
    expect(config['mapProvider'], 'martin');
    final (missingUrl, missingUrlBody) = await call(
      'PATCH',
      '/api/admin/settings',
      token: admin,
      body: {'mapProvider': 'custom', 'mapTileUrl': null},
    );
    expect(missingUrl, 400, reason: '$missingUrlBody');
    final (osm, osmBody) = await call(
      'PATCH',
      '/api/admin/settings',
      token: admin,
      body: {
        'mapProvider': 'osm',
        'mapTileUrl': 'https://ignored.example/{z}/{x}/{y}.png',
      },
    );
    expect(osm, 200, reason: '$osmBody');
    final (_, osmConfig) = await call('GET', '/api/config', token: admin);
    expect(osmConfig['mapProvider'], 'osm');
    expect(osmConfig['mapTileUrl'], isNull);
    var overview = ServerOverview.fromJson(body);
    // The admin's zone picker offers what the server knows, links included.
    expect(
      overview.timeZones,
      containsAll(['Africa/Accra', 'Europe/Berlin', 'Europe/Vienna']),
    );
    expect(overview.timeZones, isNot(contains('Etc/UTC')));
    expect(overview.effective.publicUrl, 'https://famio.example.org/');
    expect(overview.effective.maxUploadMb, 5);
    expect(app.location.name, 'Europe/Vienna');
    expect(app.files.maxBytes, 5 * 1024 * 1024);
    final (_, feeds) = await call('GET', '/api/calendar/feeds', token: admin);
    expect(feeds['publicUrl'], 'https://famio.example.org/');

    for (final bad in [
      {'timeZone': 'Mars/Olympus'},
      {'maxUploadMb': 0},
      {'publicUrl': 'ftp://x'},
      {'mapTileUrl': 'http://tiles.example.org/{z}/{x}/{y}.png'},
      {'mapTileUrl': 'https://tiles.example.org/tile.png'},
      {'trustProxy': true},
    ]) {
      expect(
        (await call(
          'PATCH',
          '/api/admin/settings',
          token: admin,
          body: bad,
        )).$1,
        400,
        reason: '$bad',
      );
    }

    (status, body) = await call(
      'PATCH',
      '/api/admin/settings',
      token: admin,
      body: {'publicUrl': null, 'timeZone': null, 'maxUploadMb': null},
    );
    overview = ServerOverview.fromJson(body);
    expect(overview.settings.publicUrl, isNull);
    expect(overview.effective.timeZone, 'Europe/Berlin');
    expect(overview.effective.maxUploadMb, 100);
    expect(overview.memberCount, 2);
    expect(overview.sessionCount, 2);
  });
}

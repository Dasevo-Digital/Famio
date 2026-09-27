import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    final app = FamioServerApp.inMemory();
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

  Future<String> setupAdmin() async {
    final (status, body) = await call(
      'POST',
      '/api/auth/setup',
      body: {
        'username': 'mama',
        'displayName': 'Mama',
        'password': 'geheim123',
      },
    );
    expect(status, 200);
    return body['token'] as String;
  }

  test('first setup creates admin, second is refused', () async {
    expect((await call('GET', '/api/health')).$2['setupRequired'], isTrue);
    final token = await setupAdmin();
    final (_, me) = await call('GET', '/api/me', token: token);
    expect(me['isAdmin'], isTrue);
    expect((await call('GET', '/api/health')).$2['setupRequired'], isFalse);
    final (status, _) = await call(
      'POST',
      '/api/auth/setup',
      body: {'username': 'eve', 'password': 'geheim123'},
    );
    expect(status, 409);
  });

  test('login, members and permissions', () async {
    final admin = await setupAdmin();
    expect(
      (await call(
        'POST',
        '/api/auth/login',
        body: {'username': 'mama', 'password': 'falsch!!'},
      )).$1,
      401,
    );

    final (created, _) = await call(
      'POST',
      '/api/members',
      token: admin,
      body: {
        'username': 'kind',
        'displayName': 'Kind',
        'password': 'kind12345',
      },
    );
    expect(created, 201);

    final (_, login) = await call(
      'POST',
      '/api/auth/login',
      body: {'username': 'KIND', 'password': 'kind12345'},
    );
    final child = login['token'] as String;
    final (_, members) = await call('GET', '/api/members', token: child);
    expect((members['members'] as List).length, 2);
    expect(
      (await call(
        'POST',
        '/api/members',
        token: child,
        body: {'username': 'x1', 'password': 'geheim123'},
      )).$1,
      403,
    );

    await call('POST', '/api/auth/logout', token: child);
    expect((await call('GET', '/api/me', token: child)).$1, 401);
  });

  test('sync pushes, pulls and resolves conflicts', () async {
    final token = await setupAdmin();
    SyncRecord task(String title, int at) => SyncRecord(
      collection: Collections.tasks,
      id: 'task-1',
      data: {'title': title},
      updatedAt: at,
    );
    final now = DateTime.now().millisecondsSinceEpoch;

    // Device A pushes.
    var (_, body) = await call(
      'POST',
      '/api/sync',
      token: token,
      body: SyncRequest(since: 0, changes: [task('A', now)]).toJson(),
    );
    var res = SyncResponse.fromJson(body);
    expect(res.rev, 1);
    expect(res.changes.single.data['title'], 'A');

    // Device B, offline with an older edit, loses and gets the server version.
    (_, body) = await call(
      'POST',
      '/api/sync',
      token: token,
      body: SyncRequest(since: 0, changes: [task('B', now - 1000)]).toJson(),
    );
    res = SyncResponse.fromJson(body);
    expect(res.rejected.single.data['title'], 'A');
    expect(res.rev, 1);

    // A newer edit wins; re-sending it is a no-op.
    final newer = SyncRequest(since: 1, changes: [task('C', now + 1000)]);
    (_, body) = await call(
      'POST',
      '/api/sync',
      token: token,
      body: newer.toJson(),
    );
    expect(SyncResponse.fromJson(body).rev, 2);
    (_, body) = await call(
      'POST',
      '/api/sync',
      token: token,
      body: newer.toJson(),
    );
    expect(SyncResponse.fromJson(body).rev, 2);

    // A client that knows a higher revision (server was reset) gets all.
    (_, body) = await call(
      'POST',
      '/api/sync',
      token: token,
      body: const SyncRequest(since: 99).toJson(),
    );
    res = SyncResponse.fromJson(body);
    expect(res.changes.single.data['title'], 'C');
    expect(res.rev, 2);

    // Unknown collections (from newer clients) are skipped and reported.
    final (status, unknown) = await call(
      'POST',
      '/api/sync',
      token: token,
      body: {
        'since': 0,
        'changes': [
          {'collection': 'nope', 'id': '1', 'data': {}, 'updatedAt': now},
        ],
      },
    );
    expect(status, 200);
    expect(unknown['unsupported'], ['nope']);
    expect(unknown['rev'], 2);
  });

  test('websocket announces new revisions', () async {
    final token = await setupAdmin();
    final ws = IOWebSocketChannel.connect(
      Uri.parse('ws://localhost:${server.port}/api/ws'),
      headers: {'authorization': 'Bearer $token'},
    );
    final messages = ws.stream
        .map((m) => jsonDecode(m as String))
        .take(2)
        .toList();
    await ws.ready;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await call(
      'POST',
      '/api/sync',
      token: token,
      body: SyncRequest(
        since: 0,
        changes: [
          SyncRecord(
            collection: Collections.shoppingLists,
            id: 'l1',
            data: {'name': 'Rewe'},
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ).toJson(),
    );
    expect(await messages, [
      {'type': 'rev', 'rev': 0},
      {'type': 'rev', 'rev': 1},
    ]);
    await ws.sink.close();
  });
}

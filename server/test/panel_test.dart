import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  late Directory web;

  setUp(() {
    web = Directory.systemTemp.createTempSync('famio_web_');
    File('${web.path}/index.html').writeAsStringSync('<html>Famio</html>');
    File('${web.path}/main.dart.js').writeAsStringSync('main();');
    File('${web.path}/secret.txt').writeAsStringSync('no');
  });
  tearDown(() => web.deleteSync(recursive: true));

  group('web app', () {
    test('served below /app/ with its own policy', () async {
      final app = FamioServerApp.inMemory(webApp: WebApp(web.path));
      addTearDown(app.close);
      Future<Response> get(String path) async =>
          app.handler(Request('GET', Uri.parse('http://famio.local$path')));

      expect((await get('/app')).headers['location'], 'app/');
      final index = await get('/app/');
      expect(index.statusCode, 200);
      expect(await index.readAsString(), contains('Famio'));
      expect(index.headers['content-security-policy'], WebApp.policy);
      expect(index.headers['cache-control'], 'no-cache');
      final js = await get('/app/main.dart.js');
      expect(js.headers['content-type'], startsWith('text/javascript'));
      // Unknown types and paths outside the folder are not served.
      expect((await get('/app/secret.txt')).statusCode, 404);
      expect((await get('/app/..%2F..%2Fetc%2Fpasswd')).statusCode, 404);
      // Outside Home Assistant the start page stays the landing page.
      final landing = await get('/');
      expect(landing.statusCode, 200);
      expect(landing.headers['content-security-policy'], isNot(WebApp.policy));
      final panel = await get('/api/panel');
      expect(jsonDecode(await panel.readAsString()), {'mode': 'browser'});
    });

    test('browsers open the WebSocket with a one-time ticket', () async {
      final app = FamioServerApp.inMemory();
      addTearDown(app.close);
      final mama = app.accounts.create(username: 'mama', displayName: 'Mama');
      final token = app.accounts.createSession(mama.id);
      final server = await io.serve(
        app.handler,
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      Future<String> ticket() async {
        final request = await http.postUrl(Uri.parse('$base/api/ws/ticket'));
        request.headers
          ..set('authorization', 'Bearer $token')
          ..contentType = ContentType.json;
        request.write('{}');
        final response = await request.close();
        return (jsonDecode(await utf8.decodeStream(response)) as Map)['ticket']
            as String;
      }

      final t = await ticket();
      final socket = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/api/ws?ticket=$t'),
      );
      await socket.ready;
      expect(
        (jsonDecode(await socket.stream.first as String) as Map)['type'],
        'rev',
      );
      // Used once: the same ticket does not work again, nor a made-up one.
      for (final bad in [t, 'erfunden']) {
        await expectLater(
          IOWebSocketChannel.connect(
            Uri.parse('ws://127.0.0.1:${server.port}/api/ws?ticket=$bad'),
          ).ready,
          throwsA(anything),
        );
      }
    });

    test('a server without web app says so', () async {
      final app = FamioServerApp.inMemory();
      addTearDown(app.close);
      final response = await app.handler(
        Request('GET', Uri.parse('http://famio.local/app/')),
      );
      expect(response.statusCode, 404);
    });
  });

  group('client mode (panel proxy)', () {
    late FamioServerApp family;
    late HttpServer upstream;
    late PanelProxy proxy;
    late HttpServer panel;
    late Directory data;
    late HttpClient http;

    setUp(() async {
      family = FamioServerApp.inMemory();
      final mama = family.accounts.create(
        username: 'mama',
        displayName: 'Mama',
        isAdmin: true,
      );
      await family.accounts.setPassword(mama.id, 'geheim-123');
      upstream = await io.serve(
        family.handler,
        InternetAddress.loopbackIPv4,
        0,
      );
      data = Directory.systemTemp.createTempSync('famio_panel_');
      // In the test, requests from this machine count as Home Assistant's.
      proxy = PanelProxy(
        upstream: Uri.parse('http://127.0.0.1:${upstream.port}'),
        dataDir: data.path,
        webApp: WebApp(web.path),
        ingressProxy: '127.0.0.1',
      );
      panel = await io.serve(proxy.handler, InternetAddress.loopbackIPv4, 0);
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await panel.close(force: true);
      proxy.close();
      await upstream.close(force: true);
      await family.close();
      data.deleteSync(recursive: true);
    });

    Future<(int, Object?)> call(
      String method,
      String path, {
      Object? body,
      String? haUser = 'ha-1',
    }) async {
      final request = await http.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${panel.port}/$path'),
      );
      if (haUser != null) {
        request.headers
          ..set('x-remote-user-id', haUser)
          ..set('x-remote-user-display-name', 'Marco');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    }

    test('signs in once per Home Assistant user, token stays here', () async {
      expect((await call('GET', 'api/panel')).$2, {'mode': 'client'});
      expect((await call('GET', 'api/me')).$1, 401);

      final (status, login) = await call(
        'POST',
        'api/auth/login',
        body: {'username': 'mama', 'password': 'geheim-123'},
      );
      expect(status, 200);
      expect((login as Map)['token'], 'panel');
      // Named after the Home Assistant user in the member's devices.
      final devices = family.db.select('SELECT device FROM sessions');
      expect(devices.single['device'], 'Home Assistant (Marco)');

      final (_, me) = await call('GET', 'api/me');
      expect((me as Map)['username'], 'mama');
      // Another Home Assistant user is not signed in by it.
      expect((await call('GET', 'api/me', haUser: 'ha-2')).$1, 401);
      // Without Home Assistant (e.g. the add-on's port directly): nothing.
      expect((await call('GET', 'api/me', haUser: null)).$1, 403);
      // Health checks work without, and tell whether the server answers.
      expect((await call('GET', 'api/health', haUser: null)).$1, 200);

      // Kept over a restart of the add-on, not readable by the browser.
      final stored = File('${data.path}/panel_sessions.json').readAsStringSync();
      expect(stored, contains('ha-1'));
      final again = PanelProxy(
        upstream: proxy.upstream,
        dataDir: data.path,
        ingressProxy: '127.0.0.1',
      );
      final restarted = await io.serve(
        again.handler,
        InternetAddress.loopbackIPv4,
        0,
      );
      final request = await http.getUrl(
        Uri.parse('http://127.0.0.1:${restarted.port}/api/me'),
      );
      request.headers.set('x-remote-user-id', 'ha-1');
      expect((await request.close()).statusCode, 200);
      await restarted.close(force: true);
      again.close();

      await call('POST', 'api/auth/logout', body: {});
      expect((await call('GET', 'api/me')).$1, 401);
      expect(family.db.select('SELECT * FROM sessions'), isEmpty);
    });

    test('a session ended elsewhere asks to sign in again', () async {
      await call(
        'POST',
        'api/auth/login',
        body: {'username': 'mama', 'password': 'geheim-123'},
      );
      family.db.execute('DELETE FROM sessions');
      expect((await call('GET', 'api/me')).$1, 401);
      expect(
        File('${data.path}/panel_sessions.json').readAsStringSync(),
        isNot(contains('ha-1')),
      );
    });

    test('change notifications come through the WebSocket', () async {
      await call(
        'POST',
        'api/auth/login',
        body: {'username': 'mama', 'password': 'geheim-123'},
      );
      final socket = IOWebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${panel.port}/api/ws'),
        headers: {'x-remote-user-id': 'ha-1'},
      );
      await socket.ready;
      final messages = socket.stream.map((m) => jsonDecode(m as String) as Map);
      final first = messages.first;
      expect((await first)['type'], 'rev');
      await socket.sink.close();
    });

    test('the web app and the start page', () async {
      final request = await http.getUrl(
        Uri.parse('http://127.0.0.1:${panel.port}/'),
      )..followRedirects = false;
      final response = await request.close();
      await response.drain<void>();
      expect(response.headers.value('location'), 'app/');
      final index = await http.getUrl(
        Uri.parse('http://127.0.0.1:${panel.port}/app/'),
      );
      final page = await index.close();
      expect(page.headers.value('content-security-policy'), WebApp.policy);
      expect(await utf8.decodeStream(page), contains('Famio'));
    });

    test('unreachable server: a clear message', () async {
      await upstream.close(force: true);
      final (status, body) = await call('GET', 'api/me');
      expect(status, 502);
      expect((body as Map)['error'], 'upstream_unreachable');
    });
  });
}

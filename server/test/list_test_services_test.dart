import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/lists/list_sync.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// `FAMIO_TEST_LIST_SERVICES` lets the app's end-to-end tests use a local
/// stand-in for Bring! and Microsoft To Do. It must never send what members
/// type in to another host: only an address on this computer counts.
void main() {
  group('testServicesBase', () {
    test('takes loopback addresses, with a slash at the end', () {
      for (final (text, base) in [
        ('http://127.0.0.1:4711/', 'http://127.0.0.1:4711/'),
        ('http://127.0.0.1:4711', 'http://127.0.0.1:4711/'),
        (' http://localhost:4711/fake ', 'http://localhost:4711/fake/'),
        ('http://LOCALHOST:4711/', 'http://localhost:4711/'),
        ('https://[::1]:4711/', 'https://[::1]:4711/'),
      ]) {
        expect(ListSync.testServicesBase(text), Uri.parse(base), reason: text);
      }
    });

    test('ignores everything else', () {
      for (final text in [
        null,
        '',
        '  ',
        'http://example.com/',
        'https://api.getbring.com/rest/v2/',
        'http://127.0.0.2:4711/',
        'http://192.168.1.5:4711/',
        'http://localhost.example.com/',
        'http://127.0.0.1.example.com/',
        'http://user:secret@127.0.0.1:4711/',
        'http://127.0.0.1:4711/?to=example.com',
        'http://127.0.0.1:4711/#x',
        'ftp://127.0.0.1/',
        'file:///tmp/fake',
        '127.0.0.1:4711',
        'localhost',
      ]) {
        expect(ListSync.testServicesBase(text), isNull, reason: text);
      }
    });
  });

  group('the server', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('famio_lists_'));
    tearDown(() => dir.deleteSync(recursive: true));

    FamioServerApp server(String? testServices, List<String> log) {
      FamioServerApp.initTimeZones();
      final app = FamioServerApp(
        db: openFamioDatabase(':memory:'),
        location: tz.getLocation('Europe/Berlin'),
        dataDir: dir.path,
        auditLog: log.add,
        testListServices: testServices,
      );
      addTearDown(app.close);
      return app;
    }

    test('without the setting talks to the real services', () {
      final log = <String>[];
      final app = server(null, log);
      expect(app.lists.bringBase, isNull);
      expect(app.lists.graphBase, isNull);
      expect(app.lists.loginBase, isNull);
      expect(log.where((l) => l.contains('FAMIO_TEST_LIST_SERVICES')), isEmpty);
    });

    test('ignores another host and says so in the log', () {
      final log = <String>[];
      final app = server('http://example.com:4711/', log);
      expect(app.lists.bringBase, isNull);
      expect(app.lists.graphBase, isNull);
      expect(app.lists.loginBase, isNull);
      expect(log, contains(contains('FAMIO_TEST_LIST_SERVICES ignoriert')));
    });

    test('sends a Bring! sign-in to the stand-in on this computer', () async {
      final requests = <String>[];
      final fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => fake.close(force: true));
      fake.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        final form = Uri.splitQueryString(
          await utf8.decoder.bind(request).join(),
        );
        request.response
          ..statusCode = form['password'] == 'richtig' ? 200 : 401
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'uuid': 'user-1',
              'access_token': 'tok',
              'refresh_token': 'ref',
              'expires_in': 3600,
            }),
          );
        await request.response.close();
      });

      final log = <String>[];
      final app = server('http://127.0.0.1:${fake.port}/', log);
      expect(
        app.lists.bringBase,
        Uri.parse('http://127.0.0.1:${fake.port}/bring/'),
      );
      expect(
        app.lists.graphBase,
        Uri.parse('http://127.0.0.1:${fake.port}/graph/'),
      );
      expect(
        app.lists.loginBase,
        Uri.parse('http://127.0.0.1:${fake.port}/login/'),
      );
      expect(log, contains(contains('Testbetrieb')));

      final setup = await app.handler(
        Request(
          'POST',
          Uri.parse('http://famio.test/api/auth/setup'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'username': 'mama',
            'password': 'tulpe-regal-7',
            'setupCode': app.setupCode,
          }),
        ),
      );
      final token =
          (jsonDecode(await setup.readAsString()) as Map)['token'] as String;
      final connected = await app.handler(
        Request(
          'POST',
          Uri.parse('http://famio.test/api/lists/bring'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'email': 'mama@example.com',
            'password': 'richtig',
          }),
        ),
      );
      expect(connected.statusCode, 201, reason: await connected.readAsString());
      expect(requests, ['POST /bring/bringauth']);
    });
  });
}

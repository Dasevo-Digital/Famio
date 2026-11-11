import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/family/sos.dart';
import 'package:famio_server/src/push/delivery.dart';
import 'package:famio_server/src/push/push_service.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Notices to ntfy: an alarm is tried again, a hanging service does not
/// keep connections, and the address is checked again before each notice.
void main() {
  late FamioServerApp app;
  late String mama;
  setUp(() {
    app = FamioServerApp.inMemory();
    mama = app.accounts
        .create(username: 'mama', displayName: 'Mama', isAdmin: true)
        .id;
  });
  tearDown(() async {
    await app.close();
    Directory(app.dataDir).deleteSync(recursive: true);
  });

  var public = true;
  Future<List<InternetAddress>> lookup(String host) async => [
    InternetAddress(public ? '93.184.216.34' : '192.168.10.65'),
  ];

  PushService service(http.Client client) => PushService(
    db: app.db,
    records: app.records,
    accounts: app.accounts,
    location: () => app.location,
    client: client,
    urlPolicy: RemoteUrlPolicy(lookup: lookup),
    retries: const [Duration(milliseconds: 10), Duration(milliseconds: 10)],
  );

  PushNotice notice({bool urgent = false}) => PushNotice(
    to: {mama},
    title: 'Notfall',
    body: 'Mia braucht Hilfe',
    brief: 'Notfall',
    urgent: urgent,
  );

  test('an alarm is tried again until it gets through', () async {
    public = true;
    var calls = 0;
    final push = service(
      MockClient((r) async => http.Response('', ++calls < 3 ? 503 : 200)),
    );
    await push.add(mama, name: 'Handy', url: 'https://ntfy.example/thema');
    push.deliver(() => notice(urgent: true), null);
    await push.idle;
    expect(calls, 3);
    expect(push.targets(mama).single.lastError, isNull);
  });

  test('other notices and refused ones are sent once', () async {
    public = true;
    var calls = 0;
    final push = service(
      MockClient((r) async => http.Response('', ++calls == 1 ? 503 : 400)),
    );
    await push.add(mama, name: 'Handy', url: 'https://ntfy.example/thema');
    push.deliver(notice, null);
    await push.idle;
    expect(calls, 1);
    push.deliver(() => notice(urgent: true), null);
    await push.idle;
    expect(calls, 2, reason: '400: the service refused it');
    expect(push.targets(mama).single.lastError, contains('400'));
  });

  test('the address is checked again before each notice', () async {
    public = true;
    var calls = 0;
    final push = service(
      MockClient((r) async {
        calls++;
        return http.Response('', 200);
      }),
    );
    await push.add(mama, name: 'Handy', url: 'https://ntfy.example/thema');
    public = false;
    push.deliver(() => notice(urgent: true), null);
    await push.idle;
    expect(calls, 0);
    expect(push.targets(mama).single.lastError, contains('privates Netzwerk'));
  });

  test('stopping ends the waiting for another try', () async {
    public = true;
    var calls = 0;
    final push = PushService(
      db: app.db,
      records: app.records,
      accounts: app.accounts,
      location: () => app.location,
      client: MockClient((r) async {
        calls++;
        return http.Response('', 503);
      }),
      urlPolicy: RemoteUrlPolicy(lookup: lookup),
      retries: const [Duration(hours: 1)],
    );
    await push.add(mama, name: 'Handy', url: 'https://ntfy.example/thema');
    push.deliver(() => notice(urgent: true), null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    push.stop();
    await push.idle.timeout(const Duration(seconds: 5));
    expect(calls, 1);
  });

  test('an alarm ended meanwhile is not sounded again (#396)', () async {
    public = true;
    final kind = app.accounts.create(
      username: 'mia',
      displayName: 'Mia',
      role: MemberRole.child,
    );
    final heard = <String>[];
    var calls = 0;
    final push = PushService(
      db: app.db,
      records: app.records,
      accounts: app.accounts,
      location: () => app.location,
      client: MockClient((r) async {
        // The first try of the alarm does not get through.
        if (++calls == 1) return http.Response('', 503);
        heard.add((jsonDecode(r.body) as Map)['title'] as String);
        return http.Response('', 200);
      }),
      urlPolicy: RemoteUrlPolicy(lookup: lookup),
      retries: const [Duration(milliseconds: 200)],
    );
    await push.add(
      mama,
      name: 'Handy',
      url: 'https://ntfy.example/thema',
      details: true,
    );
    final sos = SosService(
      records: app.records,
      accounts: app.accounts,
      push: push,
    );
    final alert = sos.raise(kind, latitude: 52.5, longitude: 13.4);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    sos.resolve(kind, alert.id);
    await push.idle;
    expect(heard, hasLength(1));
    expect(heard.single, isNot(startsWith('🚨')));

    // Still open: the alarm is tried again as before.
    calls = 0;
    heard.clear();
    sos.raise(kind, latitude: 52.5, longitude: 13.4);
    await push.idle;
    expect(heard, ['🚨 SOS von Mia']);
  });

  test('retries ask whether the notice still holds', () async {
    var tries = 0;
    var valid = true;
    final stop = Completer<void>();
    final result = withRetries(
      () async {
        tries++;
        valid = false;
        return ('x', (status: 503, failed: false));
      },
      urgent: true,
      retries: const [Duration.zero, Duration.zero],
      stopped: stop.future,
      stillValid: () => valid,
    );
    expect(await result, 'x');
    expect(tries, 1);
  });

  test('a name server that hangs does not hold up the notice', () async {
    var hang = false;
    final push = PushService(
      db: app.db,
      records: app.records,
      accounts: app.accounts,
      location: () => app.location,
      client: MockClient((r) async => http.Response('', 200)),
      urlPolicy: RemoteUrlPolicy(
        lookup: (host) =>
            hang ? Completer<List<InternetAddress>>().future : lookup(host),
      ),
      retries: const [],
      deadline: const Duration(milliseconds: 200),
    );
    await push.add(mama, name: 'Handy', url: 'https://ntfy.example/thema');
    hang = true;
    push.deliver(() => notice(urgent: true), null);
    await push.idle.timeout(const Duration(seconds: 3));
    expect(push.targets(mama).single.lastError, isNotNull);
  });

  test('a service that does not answer loses the connection', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // One connection only: a notice that kept it would block the next.
    final client = IOClient(HttpClient()..maxConnectionsPerHost = 1);
    addTearDown(() async {
      client.close();
      await server.close(force: true);
    });
    server.listen((request) async {
      if (request.uri.path == '/hang') {
        request.listen((_) {}); // Reads the notice, never answers.
        return;
      }
      request.response.statusCode = 200;
      await request.response.close();
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    Future<PushAttempt> post(String path) => postNotice(
      client,
      base.resolve(path),
      headers: const {'content-type': 'application/json'},
      body: '{}',
      timeout: const Duration(seconds: 2),
    );
    final hung = await postNotice(
      client,
      base.resolve('/hang'),
      headers: const {'content-type': 'application/json'},
      body: '{}',
      timeout: const Duration(milliseconds: 300),
    );
    expect(hung.failed, isTrue);
    expect(worthRetrying(hung), isTrue);
    final next = await post('/ok');
    expect((next.failed, next.status), (false, 200));
  });
}

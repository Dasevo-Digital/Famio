import 'dart:async';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:famio_server/famio_server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

/// HTTPS in the home network with the server's self-signed certificate,
/// pinned by the app on first use.
void main() {
  late HttpServer server;
  late TlsIdentity identity;
  late Uri url;
  late FamioServerApp app;

  setUp(() async {
    identity = TlsIdentity.loadOrCreate(
      Directory.systemTemp.createTempSync('famio_pin_').path,
    );
    app = FamioServerApp.inMemory();
    server = await io.serve(
      app.handler,
      InternetAddress.loopbackIPv4,
      0,
      securityContext: identity.context,
    );
    url = Uri.parse('https://localhost:${server.port}/');
  });

  tearDown(() async {
    await server.close(force: true);
    await app.close();
  });

  test('first contact shows the fingerprint the server prints', () async {
    expect(
      await FamioApiClient.untrustedCertificate(url),
      identity.fingerprint,
    );
  });

  test('without the pin the connection is refused', () async {
    await expectLater(
      FamioApiClient(url.toString()).health(),
      throwsA(isA<ApiError>().having((e) => e.isNetwork, 'network', isTrue)),
    );
    await expectLater(
      FamioApiClient(url.toString(), pinnedCertificate: 'AA:BB').health(),
      throwsA(isA<ApiError>()),
    );
  });

  test('pinned: login, sync and live updates over TLS', () async {
    final api = FamioApiClient(
      url.toString(),
      pinnedCertificate: identity.fingerprint,
    );
    final login = await api.setup(
      username: 'papa',
      displayName: 'Papa',
      password: 'geheim123',
      setupCode: app.setupCode,
    );
    SyncEngine device() => SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient(
        url.toString(),
        token: login.token,
        pinnedCertificate: identity.fingerprint,
      ),
      memberId: login.member.id,
    );
    final a = device(), b = device();
    b.start();
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });
    final got = b.changes.firstWhere((c) => c.contains(Collections.tasks));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    a.put(Collections.tasks, 't1', {'title': 'Impfpass mitnehmen'});
    await a.sync();
    await got.timeout(const Duration(seconds: 10));
    expect(
      b.records(Collections.tasks).single.data['title'],
      'Impfpass mitnehmen',
    );
  });
}

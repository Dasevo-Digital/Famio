// Fetches on a member's behalf go to the internet only (#574): every way of
// writing an address that leads back into the server or its networks is
// refused, a name that cannot be resolved too, and the connection goes to
// the very addresses that were checked, however the name answers later.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:famio_server/src/api_exception.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const _notPublic = [
  '0.0.0.0',
  '0.1.2.3',
  '127.0.0.1',
  '127.255.0.9',
  '10.1.2.3',
  '100.64.0.1',
  '100.127.255.254',
  '169.254.169.254',
  '172.16.0.1',
  '172.31.255.255',
  '192.0.0.8',
  '192.168.178.1',
  '198.18.0.1',
  '198.19.255.255',
  '224.0.0.251',
  '239.255.255.250',
  '240.0.0.1',
  '255.255.255.255',
  '::',
  '::1',
  '::ffff:0.0.0.0',
  '::ffff:0:0',
  '::ffff:127.0.0.1',
  '::ffff:7f00:1',
  '0:0:0:0:0:ffff:a00:1',
  '::127.0.0.1',
  '64:ff9b::7f00:1',
  '64:ff9b::10.0.0.1',
  '64:ff9b:1::1',
  '2002:7f00:1::1',
  '2002:c0a8:b201::1',
  '2001:0:4136:e378::1',
  '100::1',
  'fc00::1',
  'fd12:3456::1',
  'fe80::1',
  'fec0::1',
  'ff02::1',
];

const _public = [
  '1.1.1.1',
  '93.184.216.34',
  '100.63.255.255',
  '100.128.0.1',
  '172.32.0.1',
  '192.0.1.1',
  '198.20.0.1',
  '223.255.255.255',
  '::ffff:1.1.1.1',
  '64:ff9b::101:101',
  '2002:101:101::1',
  '2606:4700:4700::1111',
];

void main() {
  Matcher refused(String code) =>
      throwsA(isA<ApiException>().having((e) => e.code, 'code', code));

  group('addresses', () {
    test('written as a literal, none of these is fetched', () async {
      final policy = RemoteUrlPolicy(lookup: (host) => fail('resolved $host'));
      for (final address in _notPublic) {
        final host = address.contains(':') ? '[$address]' : address;
        await expectLater(
          policy.check(Uri.parse('https://$host:8443/x')),
          refused('unsafe_remote_url'),
          reason: address,
        );
      }
    });

    test('nor when a name resolves to one of them', () async {
      for (final address in _notPublic) {
        final policy = RemoteUrlPolicy(
          lookup: (host) async => [
            InternetAddress('93.184.216.34'),
            InternetAddress(address),
          ],
        );
        await expectLater(
          policy.check(Uri.parse('https://kalender.example/x')),
          refused('unsafe_remote_url'),
          reason: address,
        );
      }
    });

    test('addresses on the internet pass', () async {
      for (final address in _public) {
        final policy = RemoteUrlPolicy(
          lookup: (host) async => [InternetAddress(address)],
        );
        await expectLater(
          policy.check(Uri.parse('https://kalender.example/x')),
          completes,
          reason: address,
        );
      }
    });

    test('localhost in every spelling, without asking a resolver', () async {
      final policy = RemoteUrlPolicy(lookup: (host) => fail('resolved $host'));
      for (final host in ['localhost.', 'LOCALHOST', 'famio.localhost']) {
        await expectLater(
          policy.check(Uri.parse('https://$host/x')),
          refused('unsafe_remote_url'),
          reason: host,
        );
      }
    });

    test('a private network allowed by the server stays allowed', () async {
      final policy = RemoteUrlPolicy(
        allowPrivateNetwork: true,
        lookup: (host) => fail('resolved $host'),
      );
      await expectLater(
        policy.check(Uri.parse('http://10.0.0.5/kalender.ics')),
        completes,
      );
    });
  });

  group('the connection', () {
    late ServerSocket listener;
    late int connections;

    setUp(() async {
      connections = 0;
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      listener.listen((socket) {
        connections++;
        socket.destroy();
      });
    });
    tearDown(() => listener.close());

    test('goes to the address that was checked, not to what the name says '
        'a moment later', () async {
      var asked = 0;
      final policy = RemoteUrlPolicy(
        lookup: (host) async => [
          InternetAddress(asked++ == 0 ? '93.184.216.34' : '127.0.0.1'),
        ],
      );
      final url = Uri.parse('https://wechsel.example:${listener.port}/x');
      await policy.check(url);
      final client = policy.client();
      addTearDown(client.close);
      await expectLater(client.get(url), refused('unsafe_remote_url'));
      expect(asked, 2);
      expect(connections, 0);
    });

    test('a private network allowed by the server is connected to', () async {
      final client = const RemoteUrlPolicy(allowPrivateNetwork: true).client();
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:${listener.port}/x')),
        throwsA(isA<http.ClientException>()),
      );
      expect(connections, 1);
    });

    test('speaks TLS for the name of the address', () async {
      final dir = Directory.systemTemp.createTempSync('famio_tls_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final identity = TlsIdentity.loadOrCreate(
        dir.path,
        names: ['rezepte.example'],
      );
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        identity.context,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..write('host ${request.headers.host}')
          ..close();
      });
      final trusted = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(identity.caPem!));
      HttpClient pinnedTo(InternetAddress address) =>
          HttpClient()
            ..connectionFactory = (uri, _, _) =>
                connectToAddresses(uri, [address], context: trusted);

      final client = pinnedTo(InternetAddress.loopbackIPv4);
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('https://rezepte.example:${server.port}/'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(await utf8.decodeStream(response), 'host rezepte.example');

      // The certificate must name the host, as without pinning.
      await expectLater(
        client.getUrl(Uri.parse('https://anders.example:${server.port}/')),
        throwsA(isA<HandshakeException>()),
      );
    });
  });

  group('/api/web/page', () {
    late ServerSocket listener;
    late int connections;
    late FamioServerApp app;

    setUp(() async {
      connections = 0;
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      listener.listen((socket) {
        connections++;
        Timer(const Duration(milliseconds: 100), socket.destroy);
      });
    });
    tearDown(() async {
      await listener.close();
      await app.close();
    });

    Future<(int, Map<String, Object?>)> page(String url) async {
      final token = app.accounts.createSession(
        app.accounts.create(username: 'mama', displayName: 'Mama').id,
      );
      final r = await app.handler(
        Request(
          'POST',
          Uri.parse('https://famio.local/api/web/page'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: jsonEncode({'url': url}),
        ),
      );
      return (
        r.statusCode,
        (jsonDecode(await r.readAsString()) as Map).cast<String, Object?>(),
      );
    }

    for (final host in ['0.0.0.0', '[::ffff:0.0.0.0]', 'localhost.']) {
      test('never reaches the server itself through $host', () async {
        app = FamioServerApp.inMemory();
        final (status, body) = await page(
          'https://$host:${listener.port}/rezept',
        );
        expect(status, 400);
        expect(body['error'], 'unsafe_remote_url');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(connections, 0);
      });
    }

    test(
      'nor through a name that points there by the time it connects',
      () async {
        var asked = 0;
        app = FamioServerApp.inMemory(
          hostLookup: (host) async => [
            InternetAddress(asked++ == 0 ? '93.184.216.34' : '127.0.0.1'),
          ],
        );
        final (status, body) = await page(
          'https://wechsel.example:${listener.port}/rezept',
        );
        expect(status, 400);
        expect(body['error'], 'unsafe_remote_url');
        expect(connections, 0);
      },
    );

    test('a name that cannot be resolved is not fetched', () async {
      app = FamioServerApp.inMemory(
        hostLookup: (host) async => throw const SocketException('down'),
      );
      final (status, body) = await page('https://rezepte.example/kuchen');
      expect(status, 502);
      expect(body['error'], RemoteUrlPolicy.notFound);
    });

    test('a page out of reach is an answer, not a server error', () async {
      for (final (failure, status) in <(Object, int)>[
        (http.ClientException('Connection reset by peer'), 502),
        (const SocketException('Connection refused'), 502),
        (const HandshakeException('certificate expired'), 502),
        (TimeoutException('slow'), 504),
      ]) {
        app = FamioServerApp.inMemory(
          httpClient: MockClient((_) async => throw failure),
        );
        final (got, body) = await page('https://rezepte.example/kuchen');
        expect(got, status, reason: '$failure');
        expect(body['message'], isNotEmpty);
        await app.close();
      }
      // Broken off in the middle of the page.
      app = FamioServerApp.inMemory(
        httpClient: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('<html>'),
            ]).followedBy(http.ClientException('Connection reset')),
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      );
      final (got, body) = await page('https://rezepte.example/kuchen');
      expect(got, 502);
      expect(body['error'], 'page_unreachable');
    });
  });
}

extension<T> on Stream<T> {
  /// This stream, then [error].
  Stream<T> followedBy(Object error) async* {
    yield* this;
    throw error;
  }
}

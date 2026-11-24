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

      // Also when the winner is not the first address: TLS for the name
      // runs on the connection that answered (TEST-NET-1 never does).
      final second = HttpClient()
        ..connectionFactory = (uri, _, _) => connectToAddresses(uri, [
          InternetAddress('192.0.2.1'),
          InternetAddress.loopbackIPv4,
        ], context: trusted);
      addTearDown(second.close);
      final again = await (await second.getUrl(
        Uri.parse('https://rezepte.example:${server.port}/'),
      )).close().timeout(const Duration(seconds: 5));
      expect(await utf8.decodeStream(again), 'host rezepte.example');
      await expectLater(
        second.getUrl(Uri.parse('https://anders.example:${server.port}/')),
        throwsA(isA<HandshakeException>()),
      );
    });
  });

  // Several addresses (#574): one that does not answer must not use up the
  // time, as with the SDK's own connections, and nothing else is reached.
  group('several addresses', () {
    late ServerSocket listener;
    late List<Socket> accepted;
    late List<Future<void>> closed;

    setUp(() async {
      accepted = [];
      closed = [];
      listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      listener.listen((socket) {
        accepted.add(socket);
        final done = Completer<void>();
        closed.add(done.future);
        socket.listen(
          (_) {},
          onDone: done.complete,
          onError: (_) {
            if (!done.isCompleted) done.complete();
          },
        );
      });
    });
    tearDown(() async {
      for (final s in accepted) {
        s.destroy();
      }
      await listener.close();
    });

    Uri url() => Uri.parse('http://kalender.example:${listener.port}/x');
    final silentAddress = InternetAddress('192.0.2.1');
    final otherSilent = InternetAddress('192.0.2.2');

    test('a silent first address does not hold up the second', () async {
      final silent = _Silent();
      final started = <String>[];
      final clock = Stopwatch()..start();
      final task = await connectToAddresses(
        url(),
        [silentAddress, InternetAddress.loopbackIPv4],
        startConnect: (address, port) {
          started.add(address.address);
          return address == silentAddress
              ? Future.value(silent.task)
              : Socket.startConnect(address, port);
        },
      );
      final socket = await task.socket.timeout(const Duration(seconds: 2));
      clock.stop();
      addTearDown(socket.destroy);
      expect(socket.remotePort, listener.port);
      expect(started, ['192.0.2.1', '127.0.0.1']);
      // After the stagger, well before any connection timeout.
      expect(clock.elapsed, greaterThan(const Duration(milliseconds: 200)));
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(silent.cancelled, isTrue);
    });

    test('also with the system\'s connect and a real silent address', () async {
      // 192.0.2.1 (TEST-NET-1) either never answers or, without a route,
      // fails at once; both times the second address must connect quickly.
      final clock = Stopwatch()..start();
      final task = await connectToAddresses(url(), [
        silentAddress,
        InternetAddress.loopbackIPv4,
      ]);
      final socket = await task.socket.timeout(const Duration(seconds: 2));
      addTearDown(socket.destroy);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(socket.remotePort, listener.port);
    });

    test('an address that fails gives way at once', () async {
      final clock = Stopwatch()..start();
      final task = await connectToAddresses(
        url(),
        [silentAddress, otherSilent, InternetAddress.loopbackIPv4],
        // Far longer than the test may take.
        stagger: const Duration(seconds: 30),
        startConnect: (address, port) {
          if (address == silentAddress) {
            return Future.error(const SocketException('refused'));
          }
          if (address == otherSilent) {
            return Future.value(
              ConnectionTask.fromSocket(
                // Fails a moment after it started, as a real one does.
                Future<Socket>.delayed(
                  Duration.zero,
                  () => throw const SocketException('unreachable'),
                ),
                () {},
              ),
            );
          }
          return Socket.startConnect(address, port);
        },
      );
      final socket = await task.socket.timeout(const Duration(seconds: 2));
      addTearDown(socket.destroy);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('when every address fails, the first failure is thrown', () async {
      var n = 0;
      final task = await connectToAddresses(
        url(),
        [silentAddress, otherSilent],
        startConnect: (address, port) =>
            Future.error(SocketException('failure ${++n}')),
      );
      await expectLater(
        task.socket,
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'failure 1',
          ),
        ),
      );
      expect(n, 2);
      // A real refusal comes back as such.
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = free.port;
      await free.close();
      final refused = await connectToAddresses(
        Uri.parse('http://kalender.example:$port/x'),
        [InternetAddress.loopbackIPv4],
      );
      await expectLater(refused.socket, throwsA(isA<SocketException>()));
    });

    test('cancelling stops every attempt, also those to come', () async {
      final attempts = <_Silent>[];
      final task = await connectToAddresses(
        url(),
        [silentAddress, otherSilent, InternetAddress('192.0.2.3')],
        stagger: const Duration(milliseconds: 100),
        startConnect: (address, port) async =>
            (attempts..add(_Silent())).last.task,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(attempts, hasLength(2));
      task.cancel();
      await expectLater(
        task.socket.timeout(const Duration(seconds: 1)),
        throwsA(isA<SocketException>()),
      );
      expect([for (final a in attempts) a.cancelled], [true, true]);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(attempts, hasLength(2));
      expect(accepted, isEmpty);
    });

    test('a connection that answers after the winner is closed', () async {
      final task = await connectToAddresses(
        url(),
        [silentAddress, InternetAddress.loopbackIPv4],
        stagger: const Duration(milliseconds: 50),
        startConnect: (address, port) {
          if (address != silentAddress) {
            return Socket.startConnect(address, port);
          }
          // Connects late, whatever cancelling says.
          return Future.value(
            ConnectionTask.fromSocket(
              Future.delayed(
                const Duration(milliseconds: 300),
                () => Socket.connect(InternetAddress.loopbackIPv4, port),
              ),
              () {},
            ),
          );
        },
      );
      final socket = await task.socket.timeout(const Duration(seconds: 2));
      addTearDown(socket.destroy);
      Future<void> lateOneClosed() async {
        while (closed.length < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await closed[1];
      }

      await lateOneClosed().timeout(const Duration(seconds: 3));
      // The winner stays open.
      var winnerClosed = false;
      unawaited(closed[0].then((_) => winnerClosed = true));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(winnerClosed, isFalse);
      expect(accepted, hasLength(2));
    });

    test('only the given addresses are tried', () async {
      final started = <InternetAddress>[];
      final task = await connectToAddresses(
        url(),
        [silentAddress, otherSilent],
        stagger: Duration.zero,
        startConnect: (address, port) async {
          started.add(address);
          throw const SocketException('down');
        },
      );
      await expectLater(task.socket, throwsA(isA<SocketException>()));
      expect(started, [silentAddress, otherSilent]);
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

/// A connection attempt that never answers until it is cancelled, like a
/// route that swallows the packets.
class _Silent {
  final _socket = Completer<Socket>();
  var cancelled = false;

  late final task = ConnectionTask.fromSocket(_socket.future, () {
    cancelled = true;
    if (!_socket.isCompleted) {
      _socket.completeError(const SocketException('cancelled'));
    }
  });
}

extension<T> on Stream<T> {
  /// This stream, then [error].
  Stream<T> followedBy(Object error) async* {
    yield* this;
    throw error;
  }
}

import 'dart:io';

import 'package:famio_server/famio_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

/// Forwarded headers (`X-Forwarded-For`, `X-Forwarded-Proto`) count only
/// when they come from the reverse proxy, not from anyone who reaches the
/// port directly (#608).
void main() {
  Request from(String peer, Map<String, String> headers) => Request(
    'GET',
    Uri.parse('http://famio/'),
    headers: headers,
    context: {'shelf.io.connection_info': _Peer(peer)},
  );

  group('addresses and networks', () {
    AddressRange range(String text) => AddressRange.tryParse(text)!;
    bool inRange(String r, String a) => range(r).contains(InternetAddress(a));

    test('single addresses and CIDR networks', () {
      expect(inRange('192.168.10.50', '192.168.10.50'), isTrue);
      expect(inRange('192.168.10.50', '192.168.10.51'), isFalse);
      expect(inRange('172.16.0.0/12', '172.31.255.1'), isTrue);
      expect(inRange('172.16.0.0/12', '172.32.0.1'), isFalse);
      expect(inRange('10.0.0.0/8', '10.200.1.1'), isTrue);
      expect(inRange('192.168.10.48/29', '192.168.10.55'), isTrue);
      expect(inRange('192.168.10.48/29', '192.168.10.56'), isFalse);
      expect(inRange('0.0.0.0/0', '203.0.113.9'), isTrue);
      expect(inRange('fd00::/8', 'fd12:3456::1'), isTrue);
      expect(inRange('fd00::/8', 'fe80::1'), isFalse);
      expect(inRange('::1', '::1'), isTrue);
      // IPv4 and IPv6 are different families …
      expect(inRange('fd00::/8', '10.0.0.1'), isFalse);
      // … except an IPv4 peer on a dual-stack socket.
      expect(inRange('192.168.10.50', '::ffff:192.168.10.50'), isTrue);
    });

    test('a list with commas or spaces, wrong entries named', () {
      final (ranges, invalid) = AddressRange.parseList(
        ' 192.168.10.50, 172.16.0.0/12  fd00::/8,,nginx, 10.0.0.0/33 ',
      );
      expect(ranges.map((r) => '$r'), [
        '192.168.10.50',
        '172.16.0.0/12',
        'fd00::/8',
      ]);
      expect(invalid, ['nginx', '10.0.0.0/33']);
      for (final empty in [null, '  ']) {
        final (r, i) = AddressRange.parseList(empty);
        expect(r, isEmpty);
        expect(i, isEmpty);
      }
    });
  });

  group('which peer counts as the proxy', () {
    test('without a list: this computer and private networks', () {
      final ignored = <String>[];
      final address = ClientAddress(trustProxy: true, onIgnored: ignored.add);
      const headers = {'x-forwarded-for': '198.51.100.7'};
      // Docker, the home network, this computer, Tailscale.
      for (final proxy in ['172.18.0.2', '192.168.10.50', '127.0.0.1', '::1']) {
        expect(address.of(from(proxy, headers)), '198.51.100.7');
      }
      expect(address.of(from('100.101.102.103', headers)), '198.51.100.7');
      // Someone on the internet who reached the port directly: their own
      // address counts, whatever they claim.
      expect(address.of(from('203.0.113.9', headers)), '203.0.113.9');
      expect(
        address.viaProxy(from('203.0.113.9', {'x-forwarded-proto': 'https'})),
        isFalse,
      );
      expect(ignored, ['203.0.113.9', '203.0.113.9']);
      // A request from outside without forwarded headers is no hint.
      expect(address.of(from('203.0.113.10', const {})), '203.0.113.10');
      expect(ignored, hasLength(2));
    });

    test('with a list: only those, also in the home network', () {
      final ignored = <String>[];
      final address = ClientAddress(
        trustProxy: true,
        proxies: [AddressRange.tryParse('192.168.10.50')!],
        onIgnored: ignored.add,
      );
      const headers = {'x-forwarded-for': '198.51.100.7'};
      expect(address.of(from('192.168.10.50', headers)), '198.51.100.7');
      expect(address.of(from('192.168.10.60', headers)), '192.168.10.60');
      expect(address.of(from('127.0.0.1', headers)), '127.0.0.1');
      expect(ignored, ['192.168.10.60', '127.0.0.1']);
    });

    test('switched off, nobody is the proxy', () {
      const address = ClientAddress(trustProxy: false);
      final r = from('192.168.10.50', {'x-forwarded-proto': 'https'});
      expect(address.viaProxy(r), isFalse);
      expect(address.of(r), '192.168.10.50');
    });

    test('HTTPS from a proxy: without trust only the private network', () {
      const https = {'x-forwarded-proto': 'https'};
      // Home Assistant with the NPM add-on: no FAMIO_TRUST_PROXY.
      const off = ClientAddress(trustProxy: false);
      expect(off.forwardedHttps(from('172.30.32.5', https)), isTrue);
      expect(off.forwardedHttps(from('192.168.10.50', https)), isTrue);
      expect(off.forwardedHttps(from('203.0.113.9', https)), isFalse);
      expect(
        off.forwardedHttps(
          from('192.168.10.50', {'x-forwarded-proto': 'http'}),
        ),
        isFalse,
      );
      // Its addresses still count only with FAMIO_TRUST_PROXY.
      expect(
        off.of(from('172.30.32.5', {'x-forwarded-for': '198.51.100.7'})),
        '172.30.32.5',
      );
      final listed = ClientAddress(
        trustProxy: true,
        proxies: [AddressRange.tryParse('192.168.10.50')!],
      );
      expect(listed.forwardedHttps(from('192.168.10.50', https)), isTrue);
      expect(listed.forwardedHttps(from('192.168.10.60', https)), isFalse);
    });

    test('a request without a peer is none', () {
      const address = ClientAddress(trustProxy: true);
      final r = Request(
        'GET',
        Uri.parse('http://famio/'),
        headers: {'x-forwarded-for': '198.51.100.7'},
      );
      expect(address.viaProxy(r), isFalse);
      expect(address.of(r), 'unknown');
    });
  });

  test('the configuration: a list switches trust on, wrong entries are '
      'named', () {
    final (ranges, invalid) = AddressRange.parseList('192.168.10.50');
    final config = ServerConfig(
      trustProxy: ranges.isNotEmpty,
      trustedProxies: ranges,
      invalidProxies: invalid,
    );
    expect(config.trustProxy, isTrue);
    expect(config.invalidProxies, isEmpty);
  });

  group('plain HTTP from the internet', () {
    late FamioServerApp app;

    setUp(() {
      FamioServerApp.initTimeZones();
      app = FamioServerApp(
        db: openFamioDatabase(':memory:'),
        location: tz.getLocation('Europe/Berlin'),
        dataDir: Directory.systemTemp.createTempSync('famio_plain_').path,
        requireTls: true,
      );
    });
    tearDown(() => app.close());

    // As dart:io hands it over: the scheme from the client's own header.
    Future<Response> me(
      Map<String, String> headers, {
      bool tls = false,
    }) async => app.handler(
      Request(
        'GET',
        Uri.parse('https://famio.example.de/api/me'),
        headers: headers,
        context: {
          'shelf.io.connection_info': _Peer('203.0.113.9'),
          if (tls) tlsConnectionKey: true,
        },
      ),
    );

    test('is refused, even when it claims HTTPS', () async {
      final r = await me({'x-forwarded-proto': 'https'});
      expect(r.statusCode, 403);
      expect(await r.readAsString(), contains('tls_required'));
    });

    test(
      "Famio's own HTTPS port is encrypted whatever the headers say",
      () async {
        final r = await me({'x-forwarded-proto': 'http'}, tls: true);
        expect(r.statusCode, 401);
        expect(r.headers['strict-transport-security'], contains('max-age'));
      },
    );
  });

  group('over the network', () {
    late FamioServerApp app;
    late HttpServer server;

    Future<http.Response> health(Map<String, String> headers) => http.get(
      Uri.parse('http://localhost:${server.port}/api/health'),
      headers: headers,
    );

    Future<void> start(List<AddressRange> proxies) async {
      FamioServerApp.initTimeZones();
      app = FamioServerApp(
        db: openFamioDatabase(':memory:'),
        location: tz.getLocation('Europe/Berlin'),
        dataDir: Directory.systemTemp.createTempSync('famio_proxies_').path,
        trustProxy: true,
        trustedProxies: proxies,
      );
      server = await io.serve(app.handler, InternetAddress.loopbackIPv4, 0);
    }

    tearDown(() async {
      await server.close(force: true);
      await app.close();
    });

    test('HTTPS from the proxy counts (HSTS)', () async {
      await start([AddressRange.tryParse('127.0.0.1')!]);
      final r = await health({'x-forwarded-proto': 'https'});
      expect(r.headers['strict-transport-security'], contains('max-age'));
    });

    test('HTTPS claimed by another peer does not', () async {
      // Here the proxy is elsewhere; this test connects from 127.0.0.1.
      await start([AddressRange.tryParse('192.168.10.50')!]);
      final r = await health({'x-forwarded-proto': 'https'});
      expect(r.statusCode, 200);
      expect(r.headers['strict-transport-security'], isNull);
    });
  });
}

class _Peer implements HttpConnectionInfo {
  _Peer(String address) : remoteAddress = InternetAddress(address);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 40000;

  @override
  int get localPort => 8765;
}

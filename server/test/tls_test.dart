import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:famio_server/famio_server.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  test('own identity serves HTTPS and pins by key fingerprint', () async {
    final dir = Directory.systemTemp.createTempSync('famio_tls_');
    final identity = TlsIdentity.loadOrCreate(dir.path);
    // Stable across restarts.
    expect(
      TlsIdentity.loadOrCreate(dir.path).fingerprint,
      identity.fingerprint,
    );
    final server = await io.serve(
      (Request r) => Response.ok('ok'),
      InternetAddress.loopbackIPv4,
      0,
      securityContext: identity.context,
    );
    addTearDown(() => server.close(force: true));

    String? seen;
    final client = HttpClient()
      ..badCertificateCallback = (cert, host, port) {
        seen = formatFingerprint(
          sha256.convert(subjectPublicKeyInfo(cert.der)).bytes,
        );
        return seen == identity.fingerprint;
      };
    final request = await client.getUrl(
      Uri.parse('https://localhost:${server.port}/'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(seen, identity.fingerprint);

    // A client pinned to another certificate refuses the connection.
    final strict = HttpClient()..badCertificateCallback = (_, _, _) => false;
    expect(
      () async => (await strict.getUrl(
        Uri.parse('https://localhost:${server.port}/'),
      )).close(),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('renewal keeps the key, so pins stay valid', () async {
    final dir = Directory.systemTemp.createTempSync('famio_tls_');
    final first = TlsIdentity.loadOrCreate(dir.path);
    final cert = first.certPem;
    expect(first.caPem, isNotNull);

    // Unchanged while valid.
    expect(TlsIdentity.loadOrCreate(dir.path).certPem, cert);

    // New host name: new certificate, same key and authority.
    final named = TlsIdentity.loadOrCreate(dir.path, names: ['10.0.0.7']);
    expect(named.certPem, isNot(cert));
    expect(named.fingerprint, first.fingerprint);
    expect(named.caPem, first.caPem);

    // Shortly before expiry it is renewed.
    final later = TlsIdentity.loadOrCreate(
      dir.path,
      names: ['10.0.0.7'],
      now: DateTime.now().add(const Duration(days: TlsIdentity.certDays - 30)),
    );
    expect(later.certPem, isNot(named.certPem));
    expect(later.fingerprint, first.fingerprint);

    // Apple limits server certificates to 825 days and needs host names.
    final data = X509Utils.x509CertificateFromPem(later.certPem);
    final validity = data.tbsCertificate!.validity;
    expect(
      validity.notAfter.difference(validity.notBefore).inDays,
      lessThanOrEqualTo(825),
    );
    expect(
      data.tbsCertificate!.extensions!.subjectAlternativNames,
      contains('localhost'),
    );
  });

  test('an older self-signed certificate is replaced, keeping its key', () {
    final dir = Directory.systemTemp.createTempSync('famio_tls_');
    final first = TlsIdentity.loadOrCreate(dir.path);
    for (final f in ['tls-ca.pem', 'tls-ca-key.pem', 'tls-cert.json']) {
      File('${dir.path}/$f').deleteSync();
    }
    final migrated = TlsIdentity.loadOrCreate(dir.path);
    expect(migrated.fingerprint, first.fingerprint);
    expect(migrated.certPem, isNot(first.certPem));
  });

  test(
    'Apple profile trusts the own certificate for the used address',
    () async {
      FamioServerApp.initTimeZones();
      final dir = Directory.systemTemp.createTempSync('famio_tls_');
      final tls = ServerTls(dir.path);
      final renewals = <TlsIdentity>[];
      tls.renewed.listen(renewals.add);
      final app = FamioServerApp(
        db: openFamioDatabase(':memory:'),
        location: tz.getLocation('Europe/Berlin'),
        dataDir: dir.path,
        tls: tls,
        tlsPort: 8766,
      );
      addTearDown(app.close);
      final server = await io.serve(
        app.handler,
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      final client = HttpClient();
      Future<({int statusCode, String body})> send(
        String method,
        String path, {
        Object? body,
        Map<String, String> headers = const {},
      }) async {
        final request = await client.open(
          method,
          'localhost',
          server.port,
          path,
        );
        headers.forEach(request.headers.set);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        return (
          statusCode: response.statusCode,
          body: await utf8.decodeStream(response),
        );
      }

      Future<({int statusCode, String body})> post(
        String path,
        Object body, [
        String? token,
      ]) => send(
        'POST',
        path,
        body: body,
        headers: {'authorization': ?(token == null ? null : 'Bearer $token')},
      );
      final setup = await post('/api/auth/setup', {
        'username': 'mama',
        'password': 'geheim123',
      });
      final token = (jsonDecode(setup.body) as Map)['token'];

      final fingerprint = tls.fingerprint;
      expect(tls.covers('192.168.1.9'), isFalse);
      final response = await post('/api/me/apple-profile', {
        'url': 'http://192.168.1.9:8765/',
      }, token as String);
      expect(response.statusCode, 201);
      final profile = (jsonDecode(response.body) as Map)['profile'] as String;
      expect(
        profile,
        contains('https://192.168.1.9:8766/dav/principals/mama/'),
      );
      expect(profile, contains('com.apple.security.root'));
      expect(profile, contains('<integer>8766</integer>'));
      // The certificate now names the address; the key (pin) is unchanged.
      expect(tls.covers('192.168.1.9'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(renewals, hasLength(1));
      expect(tls.fingerprint, fingerprint);
      // Survives a restart.
      expect(ServerTls(dir.path).covers('192.168.1.9'), isTrue);

      // The password in the profile opens CalDAV.
      final secret = RegExp(
        r'<key>CalDAVPassword</key>\s*<string>([^<]+)</string>',
      ).firstMatch(profile)!.group(1)!;
      final dav = await send(
        'PROPFIND',
        '/dav/principals/mama/',
        headers: {
          'depth': '0',
          'authorization':
              'Basic ${base64.encode(utf8.encode('mama:$secret'))}',
        },
      );
      expect(dav.statusCode, 207);

      if (Platform.isMacOS) {
        final file = File('${dir.path}/p.mobileconfig')
          ..writeAsStringSync(profile);
        final lint = await Process.run('plutil', ['-lint', file.path]);
        expect(lint.exitCode, 0, reason: '${lint.stdout}');
      }
    },
  );
}

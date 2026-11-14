import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/device_pairing_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A pairing code carries the key of the server it is for. A server
/// answering with another key gets refused without asking, so the one-time
/// secret never reaches it (#513). The certificates are made for the test
/// (openssl) and only used on loopback.
late Directory _certs;

List<int> _der(String pem) => base64.decode(
  pem.split('\n').where((l) => l.isNotEmpty && !l.startsWith('-----')).join(),
);

String _pin(String name) => formatFingerprint(
  sha256
      .convert(
        subjectPublicKeyInfo(
          _der(File('${_certs.path}/$name.crt').readAsStringSync()),
        ),
      )
      .bytes,
);

bool _makeCertificates() {
  _certs = Directory.systemTemp.createTempSync('famio_pin_test_');
  for (final name in ['a', 'b']) {
    final made = Process.runSync('openssl', [
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:prime256v1',
      '-nodes',
      '-keyout',
      '${_certs.path}/$name.key',
      '-out',
      '${_certs.path}/$name.crt',
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
    ]);
    if (made.exitCode != 0) return false;
  }
  return true;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  bool available;
  try {
    available = _makeCertificates();
  } on ProcessException {
    available = false;
  }
  tearDownAll(() {
    if (_certs.existsSync()) _certs.deleteSync(recursive: true);
  });

  testWidgets('a code for another server key is refused', (tester) async {
    // flutter_test answers every HttpClient with 400; this needs the real
    // loopback connection.
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();

    final secrets = <String>[];
    final server = (await tester.runAsync(() async {
      final context = SecurityContext()
        ..useCertificateChain('${_certs.path}/b.crt')
        ..usePrivateKey('${_certs.path}/b.key');
      final s = await HttpServer.bindSecure('127.0.0.1', 0, context);
      s.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('api/health')) {
          request.response.write(
            jsonEncode({
              'name': 'famio',
              'version': '2.0.53',
              'setupRequired': false,
            }),
          );
        } else if (request.uri.path.endsWith('api/auth/device-pair')) {
          secrets.add((jsonDecode(body) as Map)['secret'] as String);
          request.response.statusCode = 401;
          request.response.write('{}');
        } else {
          request.response.statusCode = 404;
          request.response.write('{}');
        }
        await request.response.close();
      });
      return s;
    }))!;
    addTearDown(() => server.close(force: true));

    final link = DevicePairLink(
      server: 'https://127.0.0.1:${server.port}/',
      secret: 'synthetic-one-time-secret',
      pin: _pin('a'),
    ).encode();

    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const JoinPairedDeviceScreen(),
          ),
        );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), link);
    await tester.tap(find.text('Dieses Gerät koppeln').last);
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Zertifikat des Servers prüfen'), findsNothing);
    expect(
      find.textContaining('anderen Schlüssel als im Code'),
      findsOneWidget,
    );
    expect(secrets, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 11));
  }, skip: !available);
}

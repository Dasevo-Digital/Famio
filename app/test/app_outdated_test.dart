import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('an app older than the server says so on the start page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Famio',
      packageName: 'de.status403.famio',
      version: '1.0.16',
      buildNumber: '51',
      buildSignature: '',
    );
    final api = FamioApiClient(
      'https://famio.test',
      token: 't',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/health') {
          return http.Response(
            jsonEncode({
              'name': 'famio',
              'version': '2.0.1',
              'setupRequired': false,
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: api,
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();

    // This test runs on a desktop without packages from the server: the
    // notice asks to install the new version by hand.
    expect(find.text('Famio auf diesem Gerät ist veraltet'), findsOneWidget);
    expect(find.textContaining('Version 1.0.16'), findsOneWidget);
    await tester.tap(find.byTooltip('Später'));
    await tester.pumpAndSettle();
    expect(find.text('Famio auf diesem Gerät ist veraltet'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });
}

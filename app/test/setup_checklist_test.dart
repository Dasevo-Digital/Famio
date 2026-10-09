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
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('admins see what is left to set up, and can hide it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(
      id: 'm1',
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
    final state = AppState();
    await state.init();
    final api = FamioApiClient(
      'localhost:1',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/api/admin/setup')) {
          return http.Response(
            jsonEncode({
              'steps': [
                const SetupStep(
                  id: 'members',
                  title: 'Familie eingeladen',
                  done: true,
                  detail: '3 Mitglieder.',
                ).toJson(),
                const SetupStep(
                  id: 'region',
                  title: 'Bundesland für Feiertage',
                  done: false,
                  detail: 'Ohne Bundesland keine Feiertage.',
                  where: 'Server-Verwaltung → Einstellungen',
                ).toJson(),
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      }),
    );
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: api,
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final banner = find.text('Einrichtung abschließen (1 von 2)');
    expect(banner, findsOneWidget);
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.text('Bundesland für Feiertage'), findsOneWidget);
    expect(find.text('→ Server-Verwaltung → Einstellungen'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ausblenden'));
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('setup.hidden'), isTrue);
  });
}

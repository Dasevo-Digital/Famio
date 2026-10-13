import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/admin_screens.dart';
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

  testWidgets('connections show what is set up and offer "Ändern"', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    final overview = ServerOverview(
      version: '2.0.1',
      startedAt: DateTime(2026, 10, 12),
      settings: const ServerSettings(),
      defaults: const ServerSettings(),
      effective: const ServerSettings(),
    );
    final answers = <String, Object>{
      '/api/admin/users': {'users': <Object>[]},
      '/api/admin/overview': overview.toJson(),
      '/api/admin/sso': {'configured': false},
      '/api/admin/paperbuddy': {
        'connected': true,
        'url': 'https://paperbuddy.example/',
      },
      '/api/admin/app-updates': {
        'enabled': true,
        'version': '2.0.1',
        'packages': {'android': 1, 'windows': 2, 'linux': 3},
      },
    };
    final api = FamioApiClient(
      'https://famio.test',
      token: 't',
      httpClient: MockClient((request) async {
        final answer = answers[request.url.path];
        return answer == null
            ? http.Response('{}', 404)
            : http.Response(jsonEncode(answer), 200);
      }),
    );
    const me = FamilyMember(
      id: 'm1',
      username: 'mama',
      displayName: 'Mama',
      isAdmin: true,
    );
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
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AdminScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen').last);
    await tester.pumpAndSettle();
    // The check mark before the state is part of the rich text.
    expect(
      find.textContaining(
        'Eingeschaltet · Bereit für Version 2.0.1: Android, Windows, Linux',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Verbunden mit paperbuddy.example',
        findRichText: true,
      ),
      findsOneWidget,
    );
    Finder button(String tile, String label) => find.descendant(
      of: find.widgetWithText(ListTile, tile),
      matching: find.text(label),
    );
    expect(button('PaperBuddy', 'Ändern'), findsOneWidget);
    expect(button('App-Updates über den Server', 'Ändern'), findsOneWidget);
    expect(
      button('Single Sign-On (OpenID Connect)', 'Einrichten'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });
}

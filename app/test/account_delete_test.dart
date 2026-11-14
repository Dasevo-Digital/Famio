import 'dart:convert';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/screens/settings_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deleting one's own account (#500): the last administrator learns what to
/// do first, and an account without a password is not asked for one.
void main() {
  setUpAll(() => initializeDateFormatting('de'));

  Future<void> openDelete(
    WidgetTester tester, {
    required String members,
    bool hasPassword = true,
  }) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final client = MockClient((r) async {
      if (r.method == 'GET' && r.url.path.endsWith('api/me')) {
        return http.Response(
          jsonEncode({'hasPassword': hasPassword}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 503);
    });
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', members),
      api: FamioApiClient('localhost:1', httpClient: client),
      memberId: 'm1',
    );
    final state = AppState();
    await state.init();
    state
      ..me = engine.members.firstWhere((m) => m.id == 'm1')
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    Navigator.of(
      tester.element(find.byType(Scaffold).first),
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Mein Konto löschen'), 300);
    await tester.tap(find.text('Mein Konto löschen'));
    await tester.pumpAndSettle();
  }

  const mama =
      '{"id":"m1","username":"mama","displayName":"Mama","isAdmin":true}';

  testWidgets('the only administrator hands over first', (tester) async {
    await openDelete(
      tester,
      members: '[$mama,{"id":"p1","username":"papa","displayName":"Papa"}]',
    );
    expect(find.text('Du bist der einzige Administrator'), findsOneWidget);
    expect(find.textContaining('anderes erwachsenes Mitglied'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('alone, it says how Famio is wound up', (tester) async {
    await openDelete(tester, members: '[$mama]');
    expect(find.textContaining('Alle Daten löschen'), findsOneWidget);
  });

  testWidgets('no password field for an account without one', (tester) async {
    const papa =
        '{"id":"p1","username":"papa","displayName":"Papa","isAdmin":true}';
    await openDelete(tester, members: '[$mama,$papa]', hasPassword: false);
    expect(find.text('Konto wirklich löschen?'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'Passwort zur Bestätigung'),
      findsNothing,
    );
  });

  testWidgets('and one for an account with a password', (tester) async {
    const papa =
        '{"id":"p1","username":"papa","displayName":"Papa","isAdmin":true}';
    await openDelete(tester, members: '[$mama,$papa]');
    expect(
      find.widgetWithText(TextField, 'Passwort zur Bestätigung'),
      findsOneWidget,
    );
  });
}

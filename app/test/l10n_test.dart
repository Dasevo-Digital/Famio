import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('every German text has an English one', () {
    Map<String, Object?> keys(String f) => {
      for (final e
          in (jsonDecode(File('lib/l10n/$f').readAsStringSync()) as Map)
              .entries)
        if (!(e.key as String).startsWith('@')) e.key as String: e.value,
    };
    final de = keys('app_de.arb'), en = keys('app_en.arb');
    expect(en.keys.toSet(), de.keys.toSet());
    for (final e in en.entries) {
      expect(e.value, isNotEmpty, reason: e.key);
    }
  });

  testWidgets('German by default, English when chosen', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    state
      ..me = me
      ..engine = SyncEngine(
        store: LocalStore.open(':memory:'),
        api: FamioApiClient('localhost:1'),
        memberId: me.id,
      );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    expect(find.text('Aufgaben'), findsWidgets);
    await tester.tap(find.text('Einstellungen').first);
    await tester.pumpAndSettle();
    expect(find.text('Konto'), findsOneWidget);

    // A new language rebuilds the app; it starts on the home page again.
    await state.setLanguage('en');
    await tester.pumpAndSettle();
    expect(find.text('Tasks'), findsWidgets);
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Account'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Language'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Language'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('language'), 'en');
  });
}

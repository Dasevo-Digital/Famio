import 'dart:convert';
import 'dart:io';

import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/l10n.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, String> _texts(String file) => {
  for (final e
      in (jsonDecode(File('lib/l10n/$file').readAsStringSync()) as Map)
          .entries)
    if (!(e.key as String).startsWith('@')) e.key as String: e.value as String,
};

/// `{name}` placeholders, also the variable of a plural.
Set<String> _placeholders(String text) => {
  for (final m in RegExp(r'\{(\w+)(?=[},])').allMatches(text)) m[1]!,
}..remove('other');

void main() {
  setUpAll(initializeDateFormatting);

  final de = _texts('app_de.arb');
  for (final language in ['en', 'es']) {
    test('every German text has one in $language, with its placeholders', () {
      final other = _texts('app_$language.arb');
      expect(other.keys.toSet(), de.keys.toSet());
      for (final MapEntry(:key, :value) in other.entries) {
        expect(value, isNotEmpty, reason: key);
        expect(
          _placeholders(value).containsAll(_placeholders(de[key]!)),
          isTrue,
          reason: '$key: $value',
        );
      }
    });
  }

  test('the device language decides, English for unknown ones', () {
    final before = deviceLanguage;
    addTearDown(() => deviceLanguage = before);
    deviceLanguage = () => 'es';
    expect(resolveLanguage('system'), 'es');
    expect(resolveLanguage('de'), 'de');
    deviceLanguage = () => 'fr';
    expect(resolveLanguage('system'), 'en');
    expect(resolveLanguage(null), 'en');
  });

  testWidgets('German by default, English and Spanish when chosen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => useLanguage('de'));
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
    expect(FamioApiClient.language, 'en');
    expect(MemberRole.guest.label, 'Guest');
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();
    expect(find.text('Account'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Language'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Language'), findsOneWidget);

    await state.setLanguage('es');
    await tester.pumpAndSettle();
    expect(find.text('Tareas'), findsWidgets);
    expect(MemberRole.guest.label, 'Invitado');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('language'), 'es');
    await tester.pump(const Duration(seconds: 1));
  });
}

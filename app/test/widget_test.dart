import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/secure_vault.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('signed out shows the connect screen', (tester) async {
    final state = AppState();
    await state.init();
    await tester.pumpWidget(FamioApp(state: state));

    expect(find.text('Euer Familien-Organizer'), findsOneWidget);
    expect(find.text('Verbinden'), findsOneWidget);
  });

  testWidgets('plain secret storage needs explicit consent', (tester) async {
    final state = AppState();
    await state.init();
    state.insecureVaultConsentRequired = true;
    await tester.pumpWidget(FamioApp(state: state));

    expect(find.text('Kein System-Schlüsselbund verfügbar'), findsOneWidget);
    expect(find.text('Ungeschützte Speicherung erlauben'), findsOneWidget);

    await tester.tap(find.text('Ungeschützte Speicherung erlauben'));
    await tester.pumpAndSettle();
    expect(state.insecureVaultConsentRequired, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        SecureVault.insecureFallbackPreference,
      ),
      isTrue,
    );
  });

  testWidgets('tasks can be added and completed offline', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      // Unreachable: everything must work from the local store alone.
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;

    await tester.pumpWidget(FamioApp(state: state));
    // Starts on the dashboard; the side rail leads to the tasks.
    expect(
      find.textContaining('Hallo').evaluate().isNotEmpty ||
          find.textContaining('Guten').evaluate().isNotEmpty ||
          find.textContaining('Gute Nacht').evaluate().isNotEmpty,
      isTrue,
    );
    await tester.tap(find.text('Aufgaben').first);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Neue Aufgabe …'),
      'Müll rausbringen',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('Müll rausbringen'), findsOneWidget);
    expect(engine.tasks.single.title, 'Müll rausbringen');

    await tester.tap(find.byType(RoundCheck));
    await tester.pump();
    expect(engine.tasks.single.done, isTrue);
    expect(find.text('Müll rausbringen'), findsNothing); // Filter: open only.
    expect(engine.store.dirty, hasLength(1));

    await tester.pump(const Duration(seconds: 1)); // Let the debounce fire.
  });
}

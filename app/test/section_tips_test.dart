import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/widgets/section_tips.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('each area tells its tip once, until tips are switched off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
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
    Future<void> open(String area) async {
      await tester.tap(find.text(area).first);
      await tester.pumpAndSettle();
    }

    // No tip on the start page.
    expect(find.byType(SectionTipCard), findsNothing);
    await open('Aufgaben');
    expect(
      find.textContaining('Checklisten, Fotos und Dateien'),
      findsOneWidget,
    );
    await tester.tap(find.text('Verstanden'));
    await tester.pumpAndSettle();
    expect(find.byType(SectionTipCard), findsNothing);

    // Once is enough; another area has its own.
    await open('Start');
    await open('Aufgaben');
    expect(find.byType(SectionTipCard), findsNothing);
    await open('Einkauf');
    expect(find.textContaining('Gänge'), findsOneWidget);
    // Leaving an area takes its tip along.
    await open('Start');
    expect(find.byType(SectionTipCard), findsNothing);

    await open('Kalender');
    expect(find.textContaining('Termine erkennen'), findsOneWidget);
    await tester.tap(find.text('Keine Tipps mehr'));
    await tester.pumpAndSettle();
    await open('Kinder');
    expect(find.byType(SectionTipCard), findsNothing);

    // Switched on again in the settings: every tip once more.
    await SectionTips.setEnabled(true);
    await open('Start');
    await open('Aufgaben');
    expect(
      find.textContaining('Checklisten, Fotos und Dateien'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });
}

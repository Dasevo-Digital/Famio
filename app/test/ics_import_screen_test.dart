import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/ics_import_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  testWidgets('a calendar file: untick, take over, a re-import updates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'tour.offered': true});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: me.id,
    );
    state
      ..me = me
      ..engine = engine;
    final evening = CalendarEvent(
      id: 'a1',
      title: 'Elternabend',
      start: DateTime(2026, 10, 20, 19, 30),
      end: DateTime(2026, 10, 20, 21),
      location: 'Aula',
    );
    // Imported before: the file brings it again.
    engine.saveEvent(evening.copyWith(title: 'Elternabend (alt)'));
    final preview = IcsFilePreview(
      events: [
        evening,
        CalendarEvent(
          id: 'b2',
          title: 'Schwimmen',
          start: DateTime(2026, 10, 6, 8),
          end: DateTime(2026, 10, 6, 9, 30),
          recurrence: const Recurrence(RecurrenceFrequency.weekly),
        ),
        CalendarEvent(
          id: 'c3',
          title: 'Herbstferien',
          start: DateTime(2026, 10, 26),
          end: DateTime(2026, 10, 31),
          allDay: true,
        ),
      ],
      skipped: const [
        (title: 'Kaputt', reason: 'Kein Termin (VEVENT) enthalten'),
      ],
    );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    bool? result;
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (context) => Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                        builder: (_) => IcsImportScreen(preview: preview),
                      ),
                    ),
                child: const Text('öffnen'),
              ),
            ),
          ),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();

    expect(find.text('3 Termine in der Datei'), findsWidgets);
    expect(find.textContaining('wiederholt sich'), findsOneWidget);
    expect(find.text('Schon in Famio – wird aktualisiert'), findsOneWidget);
    expect(find.textContaining('Kaputt: Kein Termin'), findsOneWidget);
    expect(
      find.text('Mo., 26. Okt. 2026 – Fr., 30. Okt. 2026'),
      findsOneWidget,
    );

    // The holidays stay out.
    await tester.tap(find.text('Herbstferien'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 Termine übernehmen'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(engine.event('a1')?.title, 'Elternabend');
    expect(engine.event('b2')?.recurrence, isNotNull);
    expect(engine.event('c3'), isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}

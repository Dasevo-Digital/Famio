// A search hit of a subscribed calendar or a birthday opens the read-only
// view the calendar shows for it, and the calendar goes to its day.
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/calendar_screen.dart';
import 'package:famio/src/screens/search_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  tearDown(() => CalendarScreen.requestedDay.value = null);

  Future<SyncEngine> search(WidgetTester tester, String query) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    final engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"mama","displayName":"Mama"}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final next = DateTime.now().add(const Duration(days: 10));
    final day = DateTime(next.year, next.month, next.day);
    engine
      ..saveCalendarSubscription(
        const CalendarSubscription(
          id: 'sub',
          name: 'Schule',
          url: 'https://example.com/s.ics',
        ),
      )
      ..saveContact(
        FamilyContact(
          id: 'c1',
          name: 'Oma Inge',
          birthday: Birthday(day.month, day.day, 1950),
        ),
      );
    engine.store.put(
      SyncRecord(
        collection: Collections.externalEvents,
        id: 'x1',
        data: CalendarEvent(
          id: 'x1',
          title: 'Sportfest Klasse 3b',
          start: day.add(const Duration(hours: 9)),
          end: day.add(const Duration(hours: 12)),
          sourceId: 'sub',
        ).toData(),
        updatedAt: 1,
        rev: 1,
      ),
      dirty: false,
    );
    state
      ..me = const FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama')
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, query);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    return engine;
  }

  testWidgets('a subscribed calendar', (tester) async {
    await search(tester, 'sportfest');
    await tester.tap(find.text('Sportfest Klasse 3b'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Aus „Schule“ – nur lesbar. Änderungen im Originalkalender '
        'vornehmen.',
      ),
      findsOneWidget,
    );
    // No editor for it.
    expect(find.text('Speichern'), findsNothing);
    final next = DateTime.now().add(const Duration(days: 10));
    expect(
      DateUtils.dateOnly(CalendarScreen.requestedDay.value!),
      DateTime(next.year, next.month, next.day),
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a birthday', (tester) async {
    await search(tester, 'inge geburtstag');
    await tester.tap(find.text('🎂 Oma Inge'));
    await tester.pumpAndSettle();
    expect(find.text('Speichern'), findsNothing);
    expect(find.textContaining('Oma Inge wird'), findsOneWidget);
    final next = DateTime.now().add(const Duration(days: 10));
    expect(
      DateUtils.dateOnly(CalendarScreen.requestedDay.value!),
      DateTime(next.year, next.month, next.day),
    );
    await tester.pump(const Duration(seconds: 1));
  });
}

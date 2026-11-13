// The entry editor of the household book: older monthly entries open the
// date picker on their own date (#405), and on a phone the buttons below
// the form stay on screen (#406).
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/budget_month.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/design/components.dart';
import 'package:famio/src/screens/budget_screens.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  late SyncEngine engine;

  Future<void> openRent(WidgetTester tester, DateTime date) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final state = AppState();
    await state.init();
    engine = SyncEngine(
      store: LocalStore.open(':memory:')
        ..setMeta(
          'members',
          '[{"id":"m1","username":"mama","displayName":"Mama"}]',
        ),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    state
      ..me = const FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama')
      ..engine = engine;
    engine.saveBudgetEntry(
      BudgetEntry(
        id: 'rent',
        date: date,
        cents: 95000,
        category: 'Wohnen',
        note: 'Miete',
        monthly: true,
      ),
    );
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    Navigator.of(
      tester.element(find.byType(Scaffold).first),
    ).push(MaterialPageRoute<void>(builder: (_) => const BudgetScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Miete').first);
    await tester.pumpAndSettle();
  }

  test('the range always holds the date it opens on', () {
    final now = DateTime(2026, 11, 11);
    var (first, last) = datePickerRange(
      DateTime(2019, 1, 1, 9),
      DateTime(now.year - 5),
      DateTime(now.year + 5),
    );
    expect(first, DateTime(2019, 1, 1));
    expect(last, DateTime(2031));
    (first, last) = datePickerRange(
      DateTime(2040, 3, 2),
      DateTime(2021),
      DateTime(2031),
    );
    expect((first, last), (DateTime(2021), DateTime(2040, 3, 2)));
    // A start after the end (a due date still far away): only the end.
    (first, last) = datePickerRange(now, DateTime(2027, 4), now);
    expect((first, last), (now, now));
    // A range keeps its end inside as well.
    (first, last) = datePickerRange(
      DateTime(2024, 7, 1),
      DateTime(2025),
      DateTime(2029),
      DateTime(2030, 1, 3),
    );
    expect((first, last), (DateTime(2024, 7), DateTime(2030, 1, 3)));
  });

  testWidgets('a monthly entry from 2019 opens the picker on its date', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openRent(tester, DateTime(2019, 1, 1));
    await tester.tap(find.byType(InputChip).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.text('Januar 2019'), findsOneWidget);
  });

  testWidgets('phone with real fonts: Save stays on screen', (tester) async {
    await tester.runAsync(() async {
      Future<void> load(String family, List<String> assets) async {
        final loader = FontLoader(family);
        for (final a in assets) {
          loader.addFont(rootBundle.load(a));
        }
        await loader.load();
      }

      await load('Nunito', [
        for (final w in [400, 600, 700, 800]) 'assets/fonts/Nunito-$w.ttf',
      ]);
      await load('Fredoka', [
        'assets/fonts/Fredoka-500.ttf',
        'assets/fonts/Fredoka-600.ttf',
      ]);
      await load('Lucide', ['assets/fonts/Lucide.ttf']);
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    await openRent(tester, DateTime(now.year, now.month));
    expect(tester.takeException(), isNull);
    final save = tester.getRect(find.text('Speichern').last);
    expect(save.right, lessThanOrEqualTo(390));
    expect(find.text('Nach diesem Monat beenden'), findsOneWidget);
    expect(
      tester.getRect(find.text('Löschen').last).right,
      lessThanOrEqualTo(390),
    );
  });

  for (final fromNow in [true, false]) {
    testWidgets(
      'a new rent ${fromNow ? 'from this month' : 'for all months'}',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final now = DateTime.now();
        final thisMonth = DateTime(now.year, now.month);
        await openRent(tester, DateTime(now.year - 1, 1, 3));
        await tester.enterText(
          find.widgetWithText(TextField, 'Betrag'),
          '1000',
        );
        await tester.tap(find.text('Speichern').last);
        await tester.pumpAndSettle();
        expect(find.text('Ab wann gilt der neue Betrag?'), findsOneWidget);
        await tester.tap(
          find.text(
            fromNow
                ? 'Ab ${DateFormat.yMMMM('de').format(thisMonth)}'
                : 'Auch für die Monate davor',
          ),
        );
        await tester.pumpAndSettle();
        int rent(DateTime month) =>
            BudgetMonth(engine.budgetEntries, month).expenses;
        final january = DateTime(now.year - 1, 1);
        expect(rent(january), fromNow ? 95000 : 100000);
        expect(rent(thisMonth), 100000);
        expect(rent(DateTime(now.year + 1, now.month)), 100000);
        expect(engine.budgetEntries, hasLength(fromNow ? 2 : 1));
      },
    );
  }
}

// The children's tile on the start page says "Schule bis …" only on a
// school day: not on public holidays and not on the family's holidays, as
// the school bag.
import 'package:clock/clock.dart';
import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mama = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

/// The start page at 7 o'clock on [day], with a child that has lessons
/// every weekday; [vacation] a family holiday around it.
Future<void> _start(
  WidgetTester tester,
  DateTime day, {
  bool vacation = false,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Public holidays of Berlin, as the server setting leaves them.
  SharedPreferences.setMockInitialValues({'holidayRegion': 'BE'});
  FlutterSecureStorage.setMockInitialValues({});
  final state = AppState();
  await state.init();
  final engine = SyncEngine(
    store: LocalStore.open(':memory:')..setMeta('members', _members),
    api: FamioApiClient('localhost:1'),
    memberId: 'm1',
  );
  var timetable = Timetable(childId: 'c1');
  for (var weekday = 1; weekday <= 5; weekday++) {
    timetable = timetable.withLesson(weekday, 0, 'Deutsch');
  }
  engine
    ..saveChild(
      Child(
        id: 'c1',
        name: 'Mia',
        birthDate: DateTime(2018, 5, 4),
        guardianIds: const ['m1'],
      ),
    )
    ..saveTimetable(timetable);
  if (vacation) {
    engine.saveVacation(
      Vacation(
        id: 'v',
        from: day.subtract(const Duration(days: 1)),
        to: day.add(const Duration(days: 2)),
        title: 'Skiurlaub',
      ),
    );
  }
  state
    ..me = _mama
    ..engine = engine;
  await withClock(
    Clock.fixed(DateTime(day.year, day.month, day.day, 7)),
    () async {
      await tester.pumpWidget(FamioApp(state: state));
      await tester.tap(find.text('Start').first);
      await tester.pumpAndSettle();
    },
  );
}

final _school = find.textContaining('Schule bis');

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  tearDown(() => familyHolidayRegion = null);

  testWidgets('on a school day', (tester) async {
    await _start(tester, DateTime(2026, 12, 18));
    expect(_school, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('not on a public holiday', (tester) async {
    // Christmas Day 2026 is a Friday.
    await _start(tester, DateTime(2026, 12, 25));
    expect(_school, findsNothing);
    expect(find.textContaining('Mia ·'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('not on the family\'s holiday', (tester) async {
    await _start(tester, DateTime(2027, 2, 16), vacation: true);
    expect(_school, findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('not at the weekend', (tester) async {
    await _start(tester, DateTime(2026, 12, 19));
    expect(_school, findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });
}

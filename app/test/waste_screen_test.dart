import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/waste.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/waste_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

SyncEngine _engine(String memberId) => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: memberId,
);

CalendarEvent _bin(String id, String title, DateTime day) => CalendarEvent(
  id: id,
  title: title,
  start: day,
  end: DateTime(day.year, day.month, day.day + 1),
  allDay: true,
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('reminds whoever\'s turn it is, on the evening before', () {
    final now = DateTime(2026, 10, 8, 12);
    final mama = _engine('m1')
      ..saveEvent(_bin('a', 'Gelber Sack', DateTime(2026, 10, 13)))
      ..saveEvent(_bin('b', 'Restmüll', DateTime(2026, 10, 20)));
    List<DueReminder> bins(SyncEngine e) => [
      for (final r in familyReminders(
        e,
        from: now,
        to: now.add(const Duration(days: 14)),
      ))
        if (r.key.startsWith('waste:')) r,
    ];
    // Not set up yet: nobody is bothered.
    expect(bins(mama), isEmpty);
    mama.saveWasteSettings(
      const WasteSettings(memberIds: ['m1', 'm2'], rotate: true),
    );
    final papa = _engine('m2')
      ..saveEvent(_bin('a', 'Gelber Sack', DateTime(2026, 10, 13)))
      ..saveEvent(_bin('b', 'Restmüll', DateTime(2026, 10, 20)))
      ..saveWasteSettings(mama.wasteSettings);
    final mine = bins(mama);
    final his = bins(papa);
    // One each, as the weeks alternate.
    expect(mine, hasLength(1));
    expect(his, hasLength(1));
    expect(
      {mine.single.at, his.single.at},
      {DateTime(2026, 10, 12, 18), DateTime(2026, 10, 19, 18)},
    );
    expect(
      {mine.single.title, his.single.title},
      {'Morgen: 🟡 Gelbe Tonne', 'Morgen: ⚫ Restmüll'},
    );
    // The child is in charge of nothing.
    final mia = _engine('k1')
      ..saveEvent(_bin('a', 'Gelber Sack', DateTime(2026, 10, 13)))
      ..saveWasteSettings(mama.wasteSettings);
    expect(bins(mia), isEmpty);
  });

  testWidgets('start page tile and the settings', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = _engine('m1');
    final tomorrow = DateUtils.dateOnly(
      DateTime.now(),
    ).add(const Duration(days: 1));
    engine
      ..saveEvent(_bin('a', 'Altpapier', tomorrow))
      ..saveWasteSettings(const WasteSettings(memberIds: ['m1']));
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    await tester.pump();
    expect(find.text('Tonnen'), findsOneWidget);
    expect(find.text('Morgen: 🔵 Papier'), findsOneWidget);
    expect(find.text('Du bist dran'), findsOneWidget);

    await tester.tap(find.text('Tonnen'));
    await tester.pumpAndSettle();
    expect(find.byType(WasteScreen), findsOneWidget);
    expect(find.text('Automatisch erkennen'), findsOneWidget);
    // Papa joins, then they take turns.
    await tester.tap(find.widgetWithText(FilterChip, 'Papa'));
    await tester.pumpAndSettle();
    expect(engine.wasteSettings.memberIds, ['m1', 'm2']);
    await tester.tap(find.text('Wöchentlich abwechseln'));
    await tester.pumpAndSettle();
    expect(engine.wasteSettings.rotate, isTrue);
    expect(find.text('🔵 Papier'), findsOneWidget);
  });
}

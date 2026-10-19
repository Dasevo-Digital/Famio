import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/deadlines.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/screens/deadlines_screen.dart';
import 'package:famio/src/reminders/reminder_service.dart';
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

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('reminds the one in charge ahead of time and on the day', () {
    final now = DateTime(2026, 10, 8, 12);
    final tuev = Deadline(
      id: 't',
      title: 'HU/TÜV',
      subject: 'Golf',
      due: DateTime(2026, 10, 20),
      area: DeadlineArea.car,
      repeatMonths: 24,
      leadDays: 7,
      assigneeId: 'm2',
    );
    final boiler = Deadline(
      id: 'h',
      title: 'Heizungswartung',
      due: DateTime(2026, 10, 15),
      area: DeadlineArea.home,
    );
    List<String> titles(String member) => [
      for (final r in familyReminders(
        _engine(member)
          ..saveDeadline(tuev)
          ..saveDeadline(boiler),
        from: now,
        to: now.add(const Duration(days: 14)),
      ))
        if (r.key.startsWith('deadline:')) '${r.at.day}. ${r.title}',
    ];
    // The boiler's reminder 14 days ahead would have been on 1 October.
    expect(
      titles('m2'),
      unorderedEquals([
        '13. 🚗 HU/TÜV · Golf: in 7 Tagen',
        '20. 🚗 Heute fällig: HU/TÜV · Golf',
        '15. 🏠 Heute fällig: Heizungswartung',
      ]),
    );
    // Mama has no TÜV, but the boiler (nobody's) is hers too.
    expect(titles('m1'), ['15. 🏠 Heute fällig: Heizungswartung']);
    // Children are not bothered with the boiler.
    expect(titles('k1'), isEmpty);
  });

  testWidgets('start page tile, adding from a suggestion, done', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = _engine('m1');
    final today = DateUtils.dateOnly(DateTime.now());
    engine.saveDeadline(
      Deadline(
        id: 'r',
        title: 'Rauchmelder testen',
        due: today.add(const Duration(days: 3)),
        area: DeadlineArea.home,
        repeatMonths: 12,
      ),
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    await tester.pump();
    expect(find.text('Fristen'), findsOneWidget);
    expect(find.text('in 3 Tagen'), findsOneWidget);

    await tester.tap(find.text('Fristen'));
    await tester.pumpAndSettle();
    expect(find.text('Fristen & Wartung'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Erledigt'));
    await tester.pumpAndSettle();
    final next = engine.deadlines.single;
    expect(next.due, DateTime(today.year + 1, today.month, today.day));
    expect(next.lastDone, today);

    // The undo bar goes away by itself.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    // A new one from a suggestion.
    await tester.tap(find.byTooltip('Frist hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'HU/TÜV'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Welches Auto? (optional)'),
      'Golf',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final tuev = engine.deadlines.firstWhere((d) => d.title == 'HU/TÜV');
    expect(
      (tuev.subject, tuev.repeatMonths, tuev.area),
      ('Golf', 24, DeadlineArea.car),
    );
    await tester.pump(const Duration(seconds: 5));
  });

  test('a contract reminds before the last day to cancel', () {
    final now = DateTime(2026, 12, 1, 12);
    final phone = Deadline(
      id: 'c',
      title: 'Handyvertrag',
      due: DateTime(2027, 3, 31),
      area: DeadlineArea.contract,
      repeatMonths: 12,
      noticeMonths: 3,
      leadDays: 14,
    );
    final reminders = [
      for (final r in familyReminders(
        _engine('m1')..saveDeadline(phone),
        from: now,
        to: now.add(const Duration(days: 40)),
      ))
        if (r.key.startsWith('deadline:'))
          '${r.at.day}.${r.at.month}. ${r.title}',
    ];
    expect(reminders, [
      '17.12. 📄 Handyvertrag: noch 14 Tage zum Kündigen',
      '31.12. 📄 Heute letzter Tag zum Kündigen: Handyvertrag',
    ]);
  });

  testWidgets('a contract with notice period, in the budget, cancelled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = _engine('m1');
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    final context = tester.element(find.byType(Scaffold).first);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const DeadlinesScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Frist hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('📄 Verträge & Abos'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'Handyvertrag'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Keine'));
    await tester.tap(find.text('Keine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3 Monate').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Kosten pro Monat'),
      '19,99',
    );
    final budget = find.text('Im Haushaltsbuch als monatliche Ausgabe');
    await tester.ensureVisible(budget);
    await tester.tap(budget);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Speichern'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final contract = engine.deadlines.single;
    expect(contract.area, DeadlineArea.contract);
    expect((contract.noticeMonths, contract.monthlyCents), (3, 1999));
    var entry = engine.budgetEntries.single;
    expect(
      (entry.id, entry.cents, entry.monthly, entry.until),
      ('contract-${contract.id}', 1999, true, null),
    );
    expect(find.textContaining('Kündigen bis'), findsOneWidget);

    await tester.tap(find.widgetWithText(Chip, 'Erledigt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gekündigt').last);
    await tester.pumpAndSettle();
    expect(engine.deadlines.single.done, isTrue);
    entry = engine.budgetEntries.single;
    expect(entry.until, contract.due);
    await tester.pump(const Duration(seconds: 5));
  });
}

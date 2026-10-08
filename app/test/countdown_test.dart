import 'package:famio/src/app.dart';
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  SyncEngine newEngine() => SyncEngine(
    store: LocalStore.open(':memory:'),
    api: FamioApiClient('localhost:1'),
    memberId: 'm1',
  );

  CalendarEvent allDay(String id, String title, DateTime from, int days) =>
      CalendarEvent(
        id: id,
        title: title,
        start: from,
        end: DateTime(from.year, from.month, from.day + days),
        allDay: true,
        countdown: true,
      );

  test('counts calendar days to marked events, soonest first', () {
    final engine = newEngine();
    final now = DateTime(2026, 10, 8, 18);
    engine
      ..saveEvent(allDay('a', 'Urlaub', DateTime(2026, 10, 20), 7))
      ..saveEvent(allDay('b', 'Laternenfest', DateTime(2026, 10, 9), 1))
      ..saveEvent(
        allDay(
          'c',
          'Ohne',
          DateTime(2026, 10, 10),
          1,
        ).copyWith(countdown: false),
      )
      // A year ahead and more: not yet.
      ..saveEvent(allDay('d', 'Weit weg', DateTime(2027, 12, 1), 1));
    final counts = engine.countdowns(now);
    expect(
      [for (final c in counts) (c.occurrence.event.title, c.days)],
      [('Laternenfest', 1), ('Urlaub', 12)],
    );
    expect(
      countdownLabel(counts.first.occurrence, counts.first.days, now),
      'morgen',
    );
    expect(
      countdownLabel(counts.last.occurrence, counts.last.days, now),
      'noch 12 Tage',
    );
  });

  test('a running holiday counts as on, a yearly party comes back', () {
    final engine = newEngine();
    final now = DateTime(2026, 10, 22, 9);
    engine
      ..saveEvent(allDay('a', 'Urlaub', DateTime(2026, 10, 20), 7))
      ..saveEvent(
        allDay(
          'b',
          'Sommerfest',
          DateTime(2025, 7, 1),
          1,
        ).copyWith(recurrence: const Recurrence(RecurrenceFrequency.yearly)),
      )
      ..saveEvent(allDay('c', 'Heute', DateTime(2026, 10, 22), 1));
    final counts = engine.countdowns(now);
    final labels = {
      for (final c in counts)
        c.occurrence.event.title: countdownLabel(c.occurrence, c.days, now),
    };
    expect(labels['Urlaub'], 'läuft');
    expect(labels['Heute'], 'heute');
    expect(labels['Sommerfest'], 'noch 252 Tage');
  });

  test('the flag survives the record round trip', () {
    final e = allDay('a', 'Urlaub', DateTime(2026, 10, 20), 7);
    final back = CalendarEvent.fromRecord(
      SyncRecord(
        collection: Collections.events,
        id: e.id,
        data: e.toData(),
        updatedAt: 1,
        updatedBy: 'm1',
      ),
    );
    expect(back.countdown, isTrue);
    expect(
      e.copyWith(countdown: false).toData().containsKey('countdown'),
      isFalse,
    );
  });

  testWidgets('the start page shows the countdown', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    const me = FamilyMember(id: 'm1', username: 'mama', displayName: 'Mama');
    final state = AppState();
    await state.init();
    final engine = newEngine();
    final today = DateUtils.dateOnly(DateTime.now());
    engine.saveEvent(
      allDay('a', 'Urlaub', today.add(const Duration(days: 12)), 7),
    );
    state
      ..me = me
      ..engine = engine;
    await tester.pumpWidget(FamioApp(state: state));
    await tester.pump();
    await tester.pump();
    expect(find.text('Countdown'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('Tage bis Urlaub'), findsOneWidget);
    // Lets the sync debounce run out.
    await tester.pump(const Duration(seconds: 1));
  });
}

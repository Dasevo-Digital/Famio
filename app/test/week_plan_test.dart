import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/plain_text.dart';
import 'package:famio/src/data/waste.dart';
import 'package:famio/src/data/week_plan.dart';
import 'package:famio/src/screens/week_plan_pdf.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"},'
    '{"id":"k1","username":"mia","displayName":"Mia","role":"child"}]';

final _monday = DateTime(2026, 10, 19);

DateTime _day(int i, [int hour = 0]) =>
    DateTime(_monday.year, _monday.month, _monday.day + i, hour);

SyncEngine _family() {
  final e = SyncEngine(
    store: LocalStore.open(':memory:')..setMeta('members', _members),
    api: FamioApiClient('localhost:1'),
    memberId: 'm1',
  );
  e
    ..saveEvent(
      CalendarEvent(
        id: 'schwimmen',
        title: '🏊 Schwimmen',
        start: _day(1, 16),
        end: _day(1, 17),
        memberIds: const ['k1'],
        bringerId: 'm2',
      ),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'arzt',
        title: 'Zahnarzt',
        start: _day(1, 9),
        end: _day(1, 10),
      ),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'ausflug',
        title: 'Ausflug',
        start: _day(4),
        end: _day(7),
        allDay: true,
      ),
    )
    ..saveEvent(
      CalendarEvent(
        id: 'naechste',
        title: 'Nächste Woche',
        start: _day(7, 9),
        end: _day(7, 10),
      ),
    )
    ..saveCalendarSubscription(
      const CalendarSubscription(
        id: 'abfall',
        name: 'Abfall',
        url: 'https://example.org/a.ics',
      ),
    )
    ..saveWasteSettings(
      const WasteSettings(sourceId: 'abfall', memberIds: ['m2']),
    )
    ..saveRecipe(const Recipe(id: 'r1', title: 'Lasagne'))
    ..saveMeal(
      PlannedMeal(
        id: 'p1',
        date: _day(0),
        slot: MealSlot.dinner,
        title: 'Pizza',
      ),
    )
    ..saveMeal(
      PlannedMeal(
        id: 'p2',
        date: _day(2),
        slot: MealSlot.dinner,
        recipeId: 'r1',
      ),
    )
    ..saveMeal(
      PlannedMeal(
        id: 'p3',
        date: _day(2),
        slot: MealSlot.lunch,
        title: 'Suppe',
      ),
    )
    ..saveChore(
      Chore(
        id: 'tisch',
        title: 'Tisch decken',
        memberIds: const ['k1'],
        start: _day(-30),
      ),
    )
    ..saveChore(
      Chore(
        id: 'muell',
        title: 'Müll raus',
        memberIds: const ['k1', 'm2'],
        rotate: true,
        weekdays: const {DateTime.monday, DateTime.thursday},
        start: _day(-7),
      ),
    )
    ..saveChore(
      Chore(
        id: 'bad',
        title: 'Bad putzen',
        memberIds: const ['m1'],
        repeat: ChoreRepeat.weekly,
        start: _day(-30),
      ),
    )
    ..saveChore(
      Chore(id: 'pause', title: 'Pausiert', start: _day(-30), paused: true),
    );
  // The bin calendar as the server imports it.
  e.store.put(
    SyncRecord(
      collection: Collections.externalEvents,
      id: 'gelb',
      data: CalendarEvent(
        id: 'gelb',
        title: 'Gelber Sack',
        start: _day(3),
        end: _day(4),
        allDay: true,
        sourceId: 'abfall',
      ).toData(),
      updatedAt: 1,
    ),
    dirty: false,
  );
  return e;
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('the week by day: appointments, meals, chores and bins', () {
    final plan = buildWeekPlan(_family(), _monday);
    expect(plan.days.map((d) => d.day.day), [19, 20, 21, 22, 23, 24, 25]);
    String events(int i) => [
      for (final e in plan.days[i].events)
        [?e.time, e.title, if (e.people.isNotEmpty) e.people].join(' '),
    ].join(' | ');

    // Sorted by time; whose it is and who brings.
    expect(events(1), '09:00 Zahnarzt | 16:00 🏊 Schwimmen Mia · bringt: Papa');
    // A three-day trip on each of its days, without a time.
    expect(
      [events(4), events(5), events(6)],
      ['Ausflug', 'Ausflug', 'Ausflug'],
    );
    // The bins are not an appointment.
    expect(events(3), isEmpty);
    expect(
      [
        for (final w in plan.days[3].waste)
          '${w.kind.name}: ${w.who.join(', ')}',
      ],
      ['packaging: Papa'],
    );

    expect([for (final m in plan.days[0].meals) m.title], ['Pizza']);
    expect(
      [for (final m in plan.days[2].meals) (m.slot, m.title)],
      [(MealSlot.lunch, 'Suppe'), (MealSlot.dinner, 'Lasagne')],
    );

    // The same every day once; turns on their days; weekly ones apart.
    expect(
      [for (final c in plan.everyDay) '${c.title}: ${c.who.join(', ')}'],
      ['Tisch decken: Mia'],
    );
    expect(
      [for (final c in plan.weekly) '${c.title}: ${c.who.join(', ')}'],
      ['Bad putzen: Mama'],
    );
    expect(
      [for (final c in plan.days[0].chores) '${c.title}: ${c.who.join(', ')}'],
      ['Müll raus: Mia'],
    );
    expect(
      [for (final c in plan.days[3].chores) '${c.title}: ${c.who.join(', ')}'],
      ['Müll raus: Papa'],
    );
    expect(plan.days[1].chores, isEmpty);
    expect(plan.isEmpty, isFalse);
  });

  test('a holiday: named on its days, chores only before it', () {
    final engine = _family()
      ..saveVacation(
        Vacation(id: 'v', from: _day(5), to: _day(8), title: 'Oma'),
      );
    final plan = buildWeekPlan(engine, _monday);
    expect(
      [for (final d in plan.days) d.holiday],
      [null, null, null, null, null, 'Oma', 'Oma'],
    );
    // Not due every day any more: on the days it is due.
    expect(plan.everyDay, isEmpty);
    expect([for (final d in plan.days) d.chores.length], [2, 1, 1, 2, 1, 0, 0]);
  });

  test('an empty week is still a plan to write on', () {
    final empty = SyncEngine(
      store: LocalStore.open(':memory:')..setMeta('members', _members),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    final plan = buildWeekPlan(empty, _monday);
    expect(plan.days, hasLength(7));
    expect(plan.isEmpty, isTrue);
  });

  test('emoji are left out of the PDF texts', () {
    expect(withoutEmoji('🏊 Schwimmen'), 'Schwimmen');
    expect(withoutEmoji('Geburtstag 🎂🎉 Oma'), 'Geburtstag Oma');
    expect(withoutEmoji('❤️ Familie 👨‍👩‍👧'), 'Familie');
    expect(withoutEmoji('Müll – Straße 5 €'), 'Müll – Straße 5 €');
  });

  testWidgets('the PDF', (tester) async {
    final plan = buildWeekPlan(_family(), _monday);
    final bytes = await tester.runAsync(
      () => weekPlanPdf(plan, now: DateTime(2026, 10, 18)),
    );
    expect(String.fromCharCodes(bytes!.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
    // Lets the sync debounce run out.
    await tester.pump(const Duration(seconds: 1));
  });
}

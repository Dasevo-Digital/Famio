// Calendar days across the clock changes in Germany on 29.03.2026 (the
// night has 23 hours) and 25.10.2026 (25 hours). Stepping from local
// midnight in 24-hour steps lands at 23:00 the day before or at 01:00, so
// these tests only bite in a time zone with those changes, like the
// Europe/Berlin of the dev machines and the pre-push hook. Elsewhere (UTC
// in CI) they pass anyway.
import 'package:famio/src/app_state.dart';
import 'package:famio/src/data/birthdays.dart';
import 'package:famio/src/data/deadlines.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/family_extras.dart';
import 'package:famio/src/data/kids_logic.dart';
import 'package:famio/src/data/year_review.dart';
import 'package:famio/src/design/theme.dart';
import 'package:famio/src/format.dart';
import 'package:famio/src/reminders/reminder_service.dart';
import 'package:famio/src/screens/ics_import_screen.dart';
import 'package:famio/src/screens/meals_screens.dart';
import 'package:famio/src/screens/year_review_screen.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

const _members =
    '[{"id":"m1","username":"mama","displayName":"Mama"},'
    '{"id":"m2","username":"papa","displayName":"Papa"}]';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', _members),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

CalendarEvent _allDay(
  String id,
  String title,
  DateTime from,
  int days, {
  bool countdown = false,
}) => CalendarEvent(
  id: id,
  title: title,
  start: from,
  end: DateTime(from.year, from.month, from.day + days),
  allDay: true,
  countdown: countdown,
);

Future<void> _pump(WidgetTester tester, SyncEngine engine, Widget home) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      state: AppState()..engine = engine,
      child: MaterialApp(theme: famioTheme(Brightness.light), home: home),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('today, tomorrow and yesterday are calendar days', () {
    final spring = DateTime(2026, 3, 29, 10);
    expect(dayLabel(DateTime(2026, 3, 30, 8), now: spring), 'Morgen');
    expect(dayLabel(DateTime(2026, 3, 28), now: spring), 'Gestern');
    final monday = DateTime(2026, 3, 30, 10);
    expect(dayLabel(DateTime(2026, 3, 29, 18), now: monday), 'Gestern');
    expect(dayLabel(DateTime(2026, 3, 30), now: monday), 'Heute');
    expect(
      dayLabel(DateTime(2026, 3, 29), now: DateTime(2026, 3, 31)),
      'So., 29. März',
    );
    final autumn = DateTime(2026, 10, 25, 10);
    expect(dayLabel(DateTime(2026, 10, 26, 7), now: autumn), 'Morgen');
    expect(dayLabel(DateTime(2026, 10, 24), now: autumn), 'Gestern');
    expect(dayLabel(DateTime(2026, 10, 27), now: autumn), 'Di., 27. Okt.');
  });

  test('birthdays: a window of 30 days, entries one day long', () {
    final engine = _engine()
      ..saveChild(
        Child(id: 'a', name: 'Ella', birthDate: DateTime(2026, 10, 25)),
      )
      ..saveChild(Child(id: 'b', name: 'Mo', birthDate: DateTime(2026, 3, 29)))
      ..saveChild(Child(id: 'c', name: 'Ben', birthDate: DateTime(2020, 3, 31)))
      ..saveChild(
        Child(id: 'd', name: 'Lia', birthDate: DateTime(2019, 3, 30)),
      );
    // From 1 March: until 30 March, not 31 March at 01:00.
    expect(
      [
        for (final (b, day) in upcomingBirthdays(engine, DateTime(2026, 3, 1)))
          (b.name, day),
      ],
      [('Mo', DateTime(2026, 3, 29)), ('Lia', DateTime(2026, 3, 30))],
    );
    final events = {for (final e in birthdayEvents(engine)) e.title: e};
    expect(events['🎂 Ella']!.end, DateTime(2026, 10, 26));
    expect(events['🎂 Mo']!.end, DateTime(2026, 3, 30));
    // Every year a whole day, not 23 hours (or none at all).
    final ella = events['🎂 Ella']!
        .occurrencesBetween(DateTime(2027, 10, 1), DateTime(2027, 11, 1))
        .single;
    expect(
      (ella.start, ella.end),
      (DateTime(2027, 10, 25), DateTime(2027, 10, 26)),
    );
  });

  test('a countdown looks a year ahead, not a year and a day', () {
    final engine = _engine()
      ..saveEvent(
        _allDay('a', 'Ostern', DateTime(2027, 3, 29), 1, countdown: true),
      )
      ..saveEvent(
        _allDay('b', 'Zu weit', DateTime(2027, 3, 30), 1, countdown: true),
      );
    expect(
      [
        for (final c in engine.countdowns(DateTime(2026, 3, 29, 12)))
          (c.occurrence.event.title, c.days),
      ],
      [('Ostern', 365)],
    );
  });

  test('age in days and check-up windows count calendar days', () {
    final baby = Child(id: 'k', name: 'Lena', birthDate: DateTime(2026, 3, 26));
    expect(ageLabel(baby, DateTime(2026, 3, 30, 0, 30)), '4 Tage');
    expect(ageLabel(baby, DateTime(2026, 3, 29, 12)), '3 Tage');

    // U2: 3rd to 10th day of life, tolerated until the 14th.
    DueItem u2(Child c, DateTime at) =>
        checkupPlan(c, const [], at).firstWhere((d) => d.id == 'U2');
    final autumn = Child(id: 'a', name: 'A', birthDate: DateTime(2026, 10, 22));
    final window = u2(autumn, DateTime(2026, 10, 24));
    expect(
      (window.from, window.to),
      (DateTime(2026, 10, 24), DateTime(2026, 10, 31)),
    );
    expect(u2(autumn, DateTime(2026, 10, 31, 20)).state, DueState.due);
    expect(u2(autumn, DateTime(2026, 11, 4)).state, DueState.late);
    expect(u2(autumn, DateTime(2026, 11, 5)).state, DueState.missed);
    final spring = Child(id: 's', name: 'S', birthDate: DateTime(2026, 3, 28));
    expect(u2(spring, DateTime(2026, 3, 29)).state, DueState.upcoming);
    expect(u2(spring, DateTime(2026, 3, 30, 7)).state, DueState.due);
    expect(u2(spring, DateTime(2026, 3, 30)).from, DateTime(2026, 3, 30));

    // A vaccination counts as due for 31 days from its date.
    DueItem pneumo(DateTime at) => vaccinationPlan(
      Child(id: 'v', name: 'V', birthDate: DateTime(2026, 8, 1)),
      const [],
      at,
    ).firstWhere((d) => d.id == 'pneumo_1');
    expect(pneumo(DateTime(2026, 11, 1)).to, DateTime(2026, 11, 1));
    expect(pneumo(DateTime(2026, 11, 1, 18)).state, DueState.due);
    expect(pneumo(DateTime(2026, 11, 2)).state, DueState.missed);
  });

  test('reminders a few days ahead keep their day', () {
    final engine = _engine()
      ..saveDeadline(
        Deadline(
          id: 'd',
          title: 'HU/TÜV',
          due: DateTime(2026, 3, 30),
          area: DeadlineArea.car,
          leadDays: 7,
        ),
      )
      ..saveDocument(
        FamilyDocument(
          id: 'p',
          title: 'Reisepass',
          category: DocumentCategory.identity,
          file: const FileRef(
            id: 'f',
            name: 'pass.pdf',
            mime: 'application/pdf',
            size: 1,
          ),
          expiresAt: DateTime(2026, 4, 1),
        ),
      )
      ..saveChild(Child(id: 'k', name: 'Lena', birthDate: DateTime(2026, 3, 1)))
      ..saveChildEntry(
        ChildEntry(
          id: 'e',
          childId: 'k',
          kind: ChildEntryKind.checkup,
          refId: 'U3',
          date: DateTime(2026, 3, 30),
          planned: true,
        ),
      )
      ..saveMedication(
        Medication(
          id: 'm',
          name: 'Vitamin D',
          times: const ['08:00'],
          start: DateTime(2026, 3, 1),
          stock: 30,
          stockAt: DateTime(2026, 3, 20),
        ),
      );
    // Monday 08:30 to Monday 09:15 is less than 7 × 24 hours, yet next
    // Monday's 08:00 dose belongs in.
    final at = {
      for (final r in familyReminders(
        engine,
        from: DateTime(2026, 3, 23, 8, 30),
        to: DateTime(2026, 3, 30, 9, 15),
      ))
        r.key: r.at,
    };
    expect(at['deadline:d:2026-03-30:lead'], DateTime(2026, 3, 23, 9));
    expect(at['deadline:d:2026-03-30'], DateTime(2026, 3, 30, 9));
    expect(at['doc:p:7'], DateTime(2026, 3, 25, 9));
    expect(
      at.entries.where((e) => e.key.startsWith('kid:k:U3:appt:')).single.value,
      DateTime(2026, 3, 29, 18),
    );
    expect(
      [
        for (final e in at.entries)
          if (e.key.startsWith('med:')) e.value,
      ]..sort(),
      [for (var d = 24; d <= 30; d++) DateTime(2026, 3, d, 8)],
    );

    // Running low just after midnight on 25.10.: tomorrow is the 26th.
    engine.saveMedication(
      Medication(
        id: 'm',
        name: 'Vitamin D',
        times: const ['08:00'],
        start: DateTime(2026, 3, 1),
        stock: 3,
        stockAt: DateTime(2026, 10, 24, 20),
      ),
    );
    final now = DateTime(2026, 10, 25, 0, 30);
    expect(
      familyReminders(
        engine,
        from: now,
        to: now.add(const Duration(days: 14)),
      ).firstWhere((r) => r.key.startsWith('med-refill:')).at,
      DateTime(2026, 10, 26, 9),
    );
  });

  test('the year review counts the meals of 31 December', () {
    final engine = _engine();
    for (final (id, day) in [
      ('a', DateTime(2026, 1, 1)),
      ('b', DateTime(2026, 12, 31)),
      ('c', DateTime(2027, 1, 1)),
    ]) {
      engine.saveMeal(
        PlannedMeal(id: id, date: day, slot: MealSlot.values.first),
      );
    }
    expect(yearReview(engine, 2026).meals, 2);
  });

  testWidgets('the year review shows a trip until its last day', (
    tester,
  ) async {
    final engine = _engine()
      ..saveEvent(_allDay('a', 'Ostsee', DateTime(2026, 3, 27), 3))
      ..saveEvent(_allDay('b', 'Oma', DateTime(2026, 10, 23), 3));
    await _pump(tester, engine, const YearReviewScreen(year: 2026));
    expect(find.text('27. März – 29. März'), findsOneWidget);
    expect(find.text('23. Okt. – 25. Okt.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a calendar file shows the last day of all-day events', (
    tester,
  ) async {
    final preview = IcsFilePreview(
      events: [
        _allDay('a', 'Ostsee', DateTime(2026, 3, 27), 3),
        _allDay('b', 'Laternenfest', DateTime(2026, 10, 25), 1),
      ],
    );
    await _pump(tester, _engine(), IcsImportScreen(preview: preview));
    expect(
      find.text('Fr., 27. März 2026 – So., 29. März 2026'),
      findsOneWidget,
    );
    expect(find.text('So., 25. Okt. 2026, ganztägig'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the meal plan names Monday to Sunday of the week', (
    tester,
  ) async {
    await _pump(tester, _engine(), const MealsScreen());
    final now = DateTime.now();
    var shown = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    for (final (week, label) in [
      (DateTime(2026, 10, 19), '19. Okt. – 25. Okt.'),
      (DateTime(2026, 3, 23), '23. März – 29. März'),
    ]) {
      final back = daysBetween(week, shown) ~/ 7;
      for (var i = 0; i < back.abs(); i++) {
        await tester.tap(
          find.byTooltip(back > 0 ? 'Vorige Woche' : 'Nächste Woche'),
        );
        await tester.pump();
      }
      shown = week;
      expect(find.text(label), findsOneWidget);
    }
    await tester.pump(const Duration(seconds: 1));
  });
}

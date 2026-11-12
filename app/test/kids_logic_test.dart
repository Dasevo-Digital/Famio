import 'package:famio/src/data/kids_logic.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lena = Child(id: 'c', name: 'Lena', birthDate: DateTime(2025, 6, 15));

  test('age labels', () {
    expect(ageLabel(lena, DateTime(2025, 6, 20)), '5 Tage');
    expect(ageLabel(lena, DateTime(2025, 7, 20)), '5 Wochen');
    expect(ageLabel(lena, DateTime(2026, 1, 20)), '7 Monate');
    expect(ageLabel(lena, DateTime(2026, 6, 15)), '1 Jahr');
    expect(ageLabel(lena, DateTime(2026, 9, 26)), '1 Jahr und 3 Monate');
    expect(ageLabel(lena, DateTime(2029, 7, 1)), '4 Jahre');
  });

  test('check-up states follow the booklet windows', () {
    final at = DateTime(2025, 10, 1); // 3.5 months old
    final plan = {
      for (final d in checkupPlan(lena, const [], at)) d.id: d.state,
    };
    expect(plan['U2'], DueState.missed);
    expect(plan['U4'], DueState.due);
    expect(plan['U5'], DueState.upcoming);

    final done = [
      ChildEntry(
        id: 'e',
        childId: 'c',
        kind: ChildEntryKind.checkup,
        refId: 'U4',
        date: DateTime(2025, 9, 30),
      ),
    ];
    expect(
      checkupPlan(lena, done, at).firstWhere((d) => d.id == 'U4').state,
      DueState.done,
    );
  });

  test('check-up windows end on the last day the booklet allows', () {
    DueState state(DateTime birth, String id, DateTime at) => checkupPlan(
      Child(id: 'k', name: 'K', birthDate: birth),
      const [],
      at,
    ).firstWhere((d) => d.id == id).state;
    // U3, 4th–5th week of life, tolerance until the end of the 8th.
    final march = DateTime(2026, 3, 1);
    expect(state(march, 'U3', DateTime(2026, 4, 4)), DueState.due);
    expect(state(march, 'U3', DateTime(2026, 4, 5)), DueState.late);
    expect(state(march, 'U3', DateTime(2026, 4, 25)), DueState.late);
    expect(state(march, 'U3', DateTime(2026, 4, 26)), DueState.missed);
    // U4, 3rd–4th month of life: until 30 June for a child born 1 March.
    final u4 = checkupPlan(
      Child(id: 'k', name: 'K', birthDate: march),
      const [],
      DateTime(2026, 5, 10),
    ).firstWhere((d) => d.id == 'U4');
    expect(u4.from, DateTime(2026, 5));
    expect(u4.to, DateTime(2026, 6, 30));
    // U6 tolerance until the end of the 14th month: 28 February.
    final january = DateTime(2026, 1, 1);
    expect(state(january, 'U6', DateTime(2027, 2, 28)), DueState.late);
    expect(state(january, 'U6', DateTime(2027, 3, 1)), DueState.missed);
    // Born on the 31st: a month of life ending in a shorter month ends on
    // its last day (U5 window from 1 July, U4 until 30 May).
    final late = DateTime(2026, 1, 31);
    expect(state(late, 'U5', DateTime(2026, 6, 30)), DueState.upcoming);
    expect(state(late, 'U5', DateTime(2026, 7, 1)), DueState.due);
    expect(state(late, 'U4', DateTime(2026, 5, 30)), DueState.due);
    expect(state(late, 'U4', DateTime(2026, 5, 31)), DueState.late);
    // Born on 29 February: the 12th month ends on 28 February.
    final leap = DateTime(2024, 2, 29);
    expect(state(leap, 'U6', DateTime(2025, 2, 28)), DueState.due);
    expect(state(leap, 'U6', DateTime(2025, 3, 1)), DueState.late);
  });

  test('next due item prefers open check-ups, then vaccinations', () {
    final at = DateTime(2025, 10, 1);
    expect(nextDue(lena, const [], at)!.id, 'U4');
    final u4 = ChildEntry(
      id: 'e',
      childId: 'c',
      kind: ChildEntryKind.checkup,
      refId: 'U4',
      date: at,
    );
    final older = [
      for (final c in ['U1', 'U2', 'U3'])
        ChildEntry(
          id: c,
          childId: 'c',
          kind: ChildEntryKind.checkup,
          refId: c,
          date: at,
        ),
      u4,
    ];
    final next = nextDue(lena, older, at)!;
    expect(next.isCheckup, isFalse);
    expect(next.open, isTrue);
  });

  test('RSV antibodies follow the season, not the day of birth', () {
    DueState rsv(DateTime birth, DateTime at) => vaccinationPlan(
      Child(id: 'r', name: 'Baby', birthDate: birth),
      const [],
      at,
    ).firstWhere((d) => d.id == 'rsv').state;

    // Born in summer: in the autumn before the first season.
    final may = DateTime(2026, 5, 10);
    expect(rsv(may, DateTime(2026, 5, 12)), DueState.upcoming);
    expect(rsv(may, DateTime(2026, 8, 31)), DueState.upcoming);
    expect(rsv(may, DateTime(2026, 9, 15)), DueState.due);
    expect(rsv(may, DateTime(2026, 11, 12)), DueState.due);
    expect(rsv(may, DateTime(2027, 3, 31)), DueState.due);
    expect(rsv(may, DateTime(2027, 4, 1)), DueState.missed);

    // Born in the season: soon after birth, catch up until it ends.
    final december = DateTime(2025, 12, 3);
    expect(rsv(december, DateTime(2025, 12, 5)), DueState.due);
    expect(rsv(december, DateTime(2026, 1, 10)), DueState.due);
    expect(rsv(december, DateTime(2026, 4, 1)), DueState.missed);
    // Born January to March and missed: caught up in the next autumn,
    // until the first birthday.
    final february = DateTime(2026, 2, 20);
    expect(rsv(february, DateTime(2026, 3, 31)), DueState.due);
    expect(rsv(february, DateTime(2026, 4, 1)), DueState.upcoming);
    expect(rsv(february, DateTime(2026, 9, 1)), DueState.due);
    expect(rsv(february, DateTime(2027, 2, 19)), DueState.due);
    expect(rsv(february, DateTime(2027, 2, 20)), DueState.missed);
    // Born in December: the next autumn is already the second season.
    expect(rsv(december, DateTime(2026, 9, 15)), DueState.missed);

    // Born in September: from birth on.
    expect(rsv(DateTime(2026, 9, 20), DateTime(2026, 9, 21)), DueState.due);
  });

  test('a dose waits for the minimum interval after the one before', () {
    final baby = Child(id: 'v', name: 'Baby', birthDate: DateTime(2026, 9, 1));
    ChildEntry given(String id, DateTime date) => ChildEntry(
      id: id,
      childId: 'v',
      kind: ChildEntryKind.vaccination,
      refId: id,
      date: date,
    );
    DueItem item(String id, DateTime at, [List<ChildEntry> done = const []]) =>
        vaccinationPlan(baby, done, at).firstWhere((d) => d.id == id);

    // Rotavirus from 6 weeks (42 days), the 2nd dose 4 weeks after the 1st.
    expect(item('rota_1', DateTime(2026, 10, 12)).state, DueState.upcoming);
    expect(item('rota_1', DateTime(2026, 10, 13)).state, DueState.due);
    final rota = [given('rota_1', DateTime(2026, 10, 27))];
    expect(
      item('rota_2', DateTime(2026, 11, 1), rota).state,
      DueState.upcoming,
    );
    expect(item('rota_2', DateTime(2026, 11, 24), rota).state, DueState.due);
    // The last dose of the 2+1 schedule 6 months after the 2nd.
    final six = [given('six_2', DateTime(2027, 3, 1))];
    expect(item('six_3', DateTime(2027, 8, 1), six).state, DueState.upcoming);
    expect(item('six_3', DateTime(2027, 9, 1), six).state, DueState.due);
    // Without a date the age alone counts.
    final unknown = [
      ChildEntry(
        id: 'six_2',
        childId: 'v',
        kind: ChildEntryKind.vaccination,
        refId: 'six_2',
        date: DateTime(2027, 3, 1),
        dateUnknown: true,
      ),
    ];
    expect(item('six_3', DateTime(2027, 8, 1), unknown).state, DueState.due);
  });

  test('a rotavirus dose past its age limit is only recorded', () {
    final baby = Child(id: 'v', name: 'Baby', birthDate: DateTime(2026, 9, 1));
    final late = vaccinationPlan(
      baby,
      const [],
      DateTime(2026, 11, 25), // 12 weeks and a day
    ).firstWhere((d) => d.id == 'rota_1');
    expect(late.state, DueState.missed);
    expect(late.tooLate, isTrue);
    final inTime = vaccinationPlan(
      baby,
      const [],
      DateTime(2026, 10, 20),
    ).firstWhere((d) => d.id == 'rota_1');
    expect(inTime.tooLate, isFalse);
  });

  test('old unrecorded vaccinations and optional check-ups do not nag', () {
    final at = DateTime(2026, 9, 26); // 15 months old
    final vaccines = {
      for (final d in vaccinationPlan(lena, const [], at)) d.id: d,
    };
    expect(vaccines['rsv']!.state, DueState.missed);
    expect(vaccines['rsv']!.open, isFalse);
    expect(vaccines['mmrv_2']!.state, DueState.due);

    final older = Child(id: 'o', name: 'Ben', birthDate: DateTime(2018, 1, 10));
    final done = [
      for (final c in checkups.where((c) => !c.optional))
        ChildEntry(
          id: c.id,
          childId: 'o',
          kind: ChildEntryKind.checkup,
          refId: c.id,
          date: DateTime(2018),
        ),
    ];
    // U10 is due by age but optional: nextDue skips it.
    expect(nextDue(older, done, DateTime(2025, 6, 1))?.id, isNot('U10'));
  });

  test('a booked appointment is planned, not done, and comes first', () {
    final at = DateTime(2025, 10, 1); // U4 open, U5 ahead
    final u5 = ChildEntry(
      id: 'appt',
      childId: 'c',
      kind: ChildEntryKind.checkup,
      refId: 'U5',
      date: DateTime(2025, 12, 7),
      planned: true,
      time: '09:30',
    );
    final plan = checkupPlan(lena, [u5], at);
    final item = plan.firstWhere((d) => d.id == 'U5');
    expect(item.state, DueState.planned);
    expect(item.appointment, same(u5));
    expect(u5.appointmentAt, DateTime(2025, 12, 7, 9, 30));
    expect(nextDue(lena, [u5], at)!.id, 'U5');

    // A done entry wins over a leftover appointment.
    final done = ChildEntry(
      id: 'done',
      childId: 'c',
      kind: ChildEntryKind.checkup,
      refId: 'U5',
      date: DateTime(2025, 12, 7),
    );
    expect(
      checkupPlan(lena, [u5, done], at).firstWhere((d) => d.id == 'U5').state,
      DueState.done,
    );
  });

  test('appointments survive the record round trip', () {
    final e = ChildEntry(
      id: 'a',
      childId: 'c',
      kind: ChildEntryKind.vaccination,
      refId: 'v1',
      date: DateTime(2026, 9, 7),
      planned: true,
      time: '14:05',
    );
    final back = ChildEntry.fromRecord(
      SyncRecord(
        collection: Collections.childEntries,
        id: 'a',
        data: e.toData(),
        updatedAt: 0,
      ),
    );
    expect(back.planned, isTrue);
    expect(back.time, '14:05');
    expect(back.date, DateTime(2026, 9, 7));
    // Done entries carry neither flag nor time.
    expect(
      ChildEntry(
        id: 'b',
        childId: 'c',
        kind: ChildEntryKind.vaccination,
        date: DateTime(2026, 9, 7),
        time: '14:05',
      ).toData().containsKey('time'),
      isFalse,
    );
  });

  test('development phases: going on now or coming soon', () {
    final autonomy = developmentPhases.firstWhere((p) => p.id == 'autonomy');
    expect(phaseIsUpcoming(autonomy, 15), isTrue);
    expect(phaseIsUpcoming(autonomy, 10), isFalse);
    expect(phaseIsUpcoming(autonomy, 10, 12), isTrue);
    expect(phaseIsCurrent(autonomy, 15), isFalse);
    expect(phaseIsCurrent(autonomy, 24), isTrue);
    expect(phaseIsUpcoming(autonomy, 24), isFalse);
    expect(phaseIsCurrent(autonomy, 48), isFalse);
  });

  test('a two-year-old is not asked about baby milestones', () {
    final son = Child(id: 's', name: 'Ben', birthDate: DateTime(2024, 9, 20));
    final at = DateTime(2026, 10, 1);
    final months = son.ageInMonths(at);
    final age = months + at.difference(son.ageDate(months)).inDays / 30.4;
    final head = milestoneById('head_control')!;
    expect(milestoneIsRelevant(head, age), isFalse);
    expect(milestoneIsUpcoming(head, months), isFalse);
    for (final m in milestones.where((m) => m.toMonth <= 12)) {
      expect(milestoneIsRelevant(m, age), isFalse, reason: m.id);
      expect(milestoneIsUpcoming(m, months), isFalse, reason: m.id);
    }
    // First steps (window ends at 18 months) are a boundary step: they
    // stay in sight for a year, with a word about the check-up, and only
    // then are folded away. Crawling is folded away after three months.
    final walk = milestoneById('walk')!;
    final twoToday = Child(
      id: 't',
      name: 'Tom',
      birthDate: DateTime(2024, 10, 1),
    );
    final twoMonths = twoToday.ageInMonths(at).toDouble();
    expect(twoMonths, 24);
    expect(milestoneIsRelevant(walk, twoMonths), isTrue);
    expect(milestoneIsOverdue(walk, twoMonths), isTrue);
    expect(milestoneIsPast(walk, twoMonths), isFalse);
    expect(milestoneIsPast(walk, 31), isTrue);
    expect(milestoneIsUpcoming(walk, twoToday.ageInMonths(at)), isFalse);
    final crawl = milestoneById('crawl')!;
    expect(milestoneIsPast(crawl, twoMonths), isTrue);
    expect(milestoneIsOverdue(crawl, twoMonths), isFalse);
    // What is due now stays.
    expect(milestoneIsRelevant(milestoneById('jump')!, twoMonths), isTrue);
    // Shortly after the window a late walker is still asked.
    expect(milestoneIsRelevant(walk, 20), isTrue);
    expect(milestoneIsPast(walk, 20), isFalse);
    // A baby still sees it.
    final baby = Child(id: 'b', name: 'Emil', birthDate: DateTime(2026, 7, 18));
    expect(milestoneIsUpcoming(head, baby.ageInMonths(at)), isTrue);
  });
}

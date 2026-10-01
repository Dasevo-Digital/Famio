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
    // A baby still sees it.
    final baby = Child(id: 'b', name: 'Emil', birthDate: DateTime(2026, 7, 18));
    expect(milestoneIsUpcoming(head, baby.ageInMonths(at)), isTrue);
  });
}

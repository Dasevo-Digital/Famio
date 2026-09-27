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
}

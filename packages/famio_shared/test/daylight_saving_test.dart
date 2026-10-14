import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

// Clocks change in Germany on 29.03.2026 and 25.10.2026. Adding n × 24 h to
// a local midnight across them lands at 01:00 or at 23:00 the day before.
// These only bite in such a zone (e.g. Europe/Berlin); in UTC they pass
// anyway.
void main() {
  // Mondays in the week before each change.
  final mondays = [DateTime(2026, 3, 23), DateTime(2026, 10, 19)];

  for (final monday in mondays) {
    final label = dayKey(monday);
    DateTime plus(int days) =>
        DateTime(monday.year, monday.month, monday.day + days);

    test('school-day chore rotates in turn across the change ($label)', () {
      final chore = Chore(
        id: 'c',
        title: 'Tisch decken',
        memberIds: const ['a', 'b'],
        rotate: true,
        weekdays: const {1, 2, 3, 4, 5},
        start: monday,
      );
      final turns = [
        for (var d = 0; d < 21; d++)
          if (chore.dueOn(plus(d))) chore.assigneeOn(plus(d)),
      ];
      expect(turns, [for (var i = 0; i < 15; i++) i.isEven ? 'a' : 'b']);
    });

    test('paydays stay on the payday across the change ($label)', () {
      final sunday = plus(6);
      final saturdays = Allowance(
        memberId: 'k',
        weeklyCents: 300,
        since: sunday,
      ).paydays(sunday, plus(20)).toList();
      expect(saturdays, [plus(12), plus(19)]);

      final mondays = Allowance(
        memberId: 'k',
        weeklyCents: 300,
        payday: DateTime.monday,
        since: plus(1),
      ).paydays(plus(1), plus(14)).toList();
      expect(mondays, [plus(7), plus(14)]);
      expect(mondays.map(dayKey), [dayKey(plus(7)), dayKey(plus(14))]);
    });

    test('fractional age stays at midnight of the day ($label)', () {
      final child = Child(
        id: 'c',
        name: 'Lena',
        birthDate: DateTime(2025, monday.month, monday.day),
      );
      // 12 months reach the Monday, half a month adds 15 days.
      expect(child.ageDate(12), monday);
      expect(child.ageDate(12.5), plus(15));
    });
  }
}

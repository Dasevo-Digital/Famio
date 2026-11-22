import 'dart:io';

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

  // Israel puts its clocks forward on a Friday (26.03.2027): going back from
  // Saturday in days of 24 hours ends on Sunday 23:00, the week before. This
  // only bites in such a zone; the test after it runs it in one (#581).
  test('one key and one turn for each week', () {
    final chore = Chore(
      id: 'bins',
      title: 'Tonnen',
      repeat: ChoreRepeat.weekly,
      memberIds: const ['a', 'b'],
      rotate: true,
      start: DateTime(2027, 3, 1),
    );
    final days = [for (var d = 22; d <= 28; d++) DateTime(2027, 3, d)];
    expect({for (final d in days) weekStart(d)}, {DateTime(2027, 3, 22)});
    expect({for (final d in days) chore.periodKey(d)}, {'w2027-03-22'});
    expect({for (final d in days) chore.assigneeOn(d)}, hasLength(1));
    expect(
      chore.assigneeOn(DateTime(2027, 3, 29)),
      isNot(chore.assigneeOn(days.first)),
    );
  });

  test(
    'week keys where the clocks change on a Friday',
    () async {
      final r = await Process.run(
        'dart',
        [
          'test',
          'test/daylight_saving_test.dart',
          '--plain-name',
          'one key and one turn for each week',
        ],
        environment: {'TZ': 'Asia/Jerusalem', _nested: '1'},
      );
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    },
    testOn: '!windows',
    // Only from the outer run, never again from the one it starts.
    skip: Platform.environment.containsKey(_nested),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

const _nested = 'FAMIO_NESTED_ZONE_TEST';

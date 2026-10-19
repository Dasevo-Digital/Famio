import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  const bike = SavingsGoal(
    id: 'g',
    memberId: 'mia',
    title: 'Fahrrad',
    targetCents: 12000,
  );
  // Five euros every Saturday.
  final allowance = Allowance(
    memberId: 'mia',
    weeklyCents: 500,
    since: DateTime(2026),
  );
  // A Monday.
  final today = DateTime(2026, 10, 19, 15);

  test('progress between nothing and done', () {
    expect(bike.progress(0), 0);
    expect(bike.progress(3000), 0.25);
    expect(bike.progress(20000), 1);
  });

  test('reached on the payday that makes up the rest', () {
    // 30 € saved, 90 € missing = 18 Saturdays from 24 October on.
    expect(
      bike.reachedOn(balanceCents: 3000, allowance: allowance, today: today),
      DateTime(2026, 10, 24 + 7 * 17),
    );
    // One more payday is enough.
    expect(
      bike.reachedOn(balanceCents: 11600, allowance: allowance, today: today),
      DateTime(2026, 10, 24),
    );
    // On a Saturday that payday is booked already: the next one.
    expect(
      bike.reachedOn(
        balanceCents: 11600,
        allowance: allowance,
        today: DateTime(2026, 10, 24, 9),
      ),
      DateTime(2026, 10, 31),
    );
  });

  test('already there, or no weekly money', () {
    expect(
      bike.reachedOn(balanceCents: 12000, allowance: allowance, today: today),
      DateTime(2026, 10, 19),
    );
    expect(
      bike.reachedOn(balanceCents: 3000, allowance: null, today: today),
      isNull,
    );
  });
}

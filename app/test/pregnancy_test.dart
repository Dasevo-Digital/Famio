import 'package:famio/src/data/kids_logic.dart';
import 'package:famio/src/data/pregnancy_logic.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final p = Pregnancy(id: 'p', dueDate: DateTime(2027, 3, 15));

  test('weeks, trimester, days to go and maternity leave', () {
    final at = DateTime(2026, 11, 26);
    expect(weekLabel(p, at), '24+3');
    expect(trimester(p, at), 2);
    expect(daysToGo(p, at), 109);
    expect(maternityLeave(p), DateTime(2027, 2, 1));
  });

  test('task states follow the weeks and the done list', () {
    final us2 = pregnancyTasks.firstWhere((t) => t.id == 'us2');
    expect(taskState(p, us2, p.dayOf(18)), DueState.upcoming);
    expect(taskState(p, us2, p.dayOf(20, 2)), DueState.due);
    expect(taskState(p, us2, p.dayOf(24)), DueState.late);
    expect(
      taskState(p.copyWith(done: {'us2'}), us2, p.dayOf(24)),
      DueState.done,
    );
  });

  test('contraction stats and the 5-1-1 rule', () {
    final t0 = DateTime(2027, 3, 14, 2);
    // Every 4 minutes for an hour, 60 s each.
    final regular = [
      for (var i = 0; i < 16; i++)
        Contraction(
          t0.add(Duration(minutes: 4 * i)),
          t0.add(Duration(minutes: 4 * i, seconds: 60)),
        ),
    ];
    final at = t0.add(const Duration(minutes: 61));
    final s = contractionStats(regular, at: at);
    expect(s.interval, const Duration(minutes: 4));
    expect(s.length, const Duration(seconds: 60));
    expect(timeToCall(regular, at: at), isTrue);
    // Only 20 minutes so far: not yet.
    expect(
      timeToCall(
        regular.take(6).toList(),
        at: t0.add(const Duration(minutes: 21)),
      ),
      isFalse,
    );
    // Every 10 minutes: not yet.
    final slow = [
      for (var i = 0; i < 7; i++)
        Contraction(
          t0.add(Duration(minutes: 10 * i)),
          t0.add(Duration(minutes: 10 * i, seconds: 50)),
        ),
    ];
    expect(timeToCall(slow, at: at), isFalse);
  });
}

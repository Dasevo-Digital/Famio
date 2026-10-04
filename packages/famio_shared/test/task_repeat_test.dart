import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  final today = DateTime(2026, 10, 4);

  test('a one-off task is simply done', () {
    final t = const Task(
      id: 't',
      title: 'Pass verlängern',
    ).completed(today: today);
    expect(t.done, isTrue);
    expect(t.completedAt, today);
  });

  test('every other week, with the reminder moving along', () {
    final t = Task(
      id: 't',
      title: 'Gelbe Tonne',
      due: DateTime(2026, 10, 6),
      remindAt: DateTime(2026, 10, 5, 19),
      repeat: TaskRepeat.weekly,
      repeatEvery: 2,
    ).completed(today: today);
    expect(t.done, isFalse);
    expect(t.due, DateTime(2026, 10, 20));
    expect(t.remindAt, DateTime(2026, 10, 19, 19));
  });

  test('ticked off late: the next date from today on', () {
    final t = Task(
      id: 't',
      title: 'Blumen gießen',
      due: DateTime(2026, 9, 20),
      repeat: TaskRepeat.weekly,
    ).completed(today: today);
    expect(t.due, DateTime(2026, 10, 4));
  });

  test('month ends stay month ends, years keep the day', () {
    expect(
      TaskRepeat.monthly.after(DateTime(2026, 1, 31), 1),
      DateTime(2026, 2, 28),
    );
    expect(
      TaskRepeat.monthly.after(DateTime(2026, 11, 15), 3),
      DateTime(2027, 2, 15),
    );
    expect(
      TaskRepeat.yearly.after(DateTime(2028, 2, 29), 1),
      DateTime(2029, 2, 28),
    );
    expect(
      TaskRepeat.daily.after(DateTime(2026, 10, 25), 1),
      DateTime(2026, 10, 26),
    );
  });

  test('without a due date it starts from today', () {
    final t = const Task(
      id: 't',
      title: 'Zähne',
      repeat: TaskRepeat.daily,
    ).completed(today: today);
    expect(t.due, DateTime(2026, 10, 5));
  });

  test('the repetition survives a round trip', () {
    final t = Task(
      id: 't',
      title: 'Miete',
      due: DateTime(2026, 11, 1),
      repeat: TaskRepeat.monthly,
      repeatEvery: 1,
    );
    final back = Task.fromRecord(
      SyncRecord(
        collection: Collections.tasks,
        id: 't',
        data: t.toData(),
        updatedAt: 0,
      ),
    );
    expect(back.repeat, TaskRepeat.monthly);
    expect(back.repeatEvery, 1);
    expect(TaskRepeat.weekly.label(2), 'alle 2 Wochen');
    expect(const Task(id: 'x', title: 'x').toData()['repeat'], isNull);
  });
}

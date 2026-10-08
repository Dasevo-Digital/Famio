import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('a recurring deadline moves on from the day it was done', () {
    final tuev = Deadline(
      id: 't',
      title: 'HU/TÜV',
      subject: 'Golf',
      due: DateTime(2026, 11, 30),
      area: DeadlineArea.car,
      repeatMonths: 24,
    );
    expect(tuev.label, 'HU/TÜV · Golf');
    expect(tuev.daysLeft(DateTime(2026, 11, 20, 15)), 10);
    final next = tuev.completed(DateTime(2026, 11, 18, 9));
    expect(next.due, DateTime(2028, 11, 18));
    expect(next.lastDone, DateTime(2026, 11, 18));
    expect(next.done, isFalse);
    // 31 August plus six months: the end of February.
    final filter = Deadline(
      id: 'w',
      title: 'Wasserfilter',
      due: DateTime(2026, 8, 31),
      repeatMonths: 6,
    ).completed(DateTime(2026, 8, 31));
    expect(filter.due, DateTime(2027, 2, 28));
  });

  test('a one-off deadline is done; the record round trip', () {
    final kit = Deadline(
      id: 'k',
      title: 'Verbandkasten tauschen',
      due: DateTime(2027, 3, 1),
      area: DeadlineArea.car,
      assigneeId: 'papa',
      leadDays: 30,
    ).completed(DateTime(2026, 10, 8));
    expect((kit.done, kit.due), (true, DateTime(2027, 3, 1)));
    final back = Deadline.fromRecord(
      SyncRecord(
        collection: Collections.deadlines,
        id: kit.id,
        data: kit.toData(),
        updatedAt: 1,
      ),
    );
    expect(
      (back.title, back.area, back.assigneeId, back.leadDays, back.done),
      ('Verbandkasten tauschen', DeadlineArea.car, 'papa', 30, true),
    );
    expect(back.lastDone, DateTime(2026, 10, 8));
  });
}

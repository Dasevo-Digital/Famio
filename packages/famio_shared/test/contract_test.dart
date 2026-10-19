import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  final phone = Deadline(
    id: 'c1',
    title: 'Handyvertrag',
    area: DeadlineArea.contract,
    due: DateTime(2027, 3, 31),
    repeatMonths: 12,
    noticeMonths: 3,
    monthlyCents: 1999,
    inBudget: true,
    budgetCategory: 'Sonstiges',
  );

  test('the last day to give notice comes before the end of the term', () {
    expect(phone.cancelBy, DateTime(2026, 12, 31));
    expect(phone.actionDay, DateTime(2026, 12, 31));
    expect(phone.daysLeft(DateTime(2026, 12, 1)), 30);
    final weeks = Deadline(
      id: 'c2',
      title: 'Zeitschrift',
      area: DeadlineArea.contract,
      due: DateTime(2027, 1, 31),
      noticeWeeks: 6,
    );
    expect(weeks.cancelBy, DateTime(2026, 12, 20));
    // Not a contract, or no notice period: the due day itself.
    final car = Deadline(
      id: 'd1',
      title: 'HU/TÜV',
      due: DateTime(2027, 3, 31),
      noticeMonths: 3,
    );
    expect(car.cancelBy, isNull);
    expect(car.actionDay, DateTime(2027, 3, 31));
  });

  test('a contract not cancelled runs on from the end of its term', () {
    final renewed = phone.completed(DateTime(2026, 12, 10));
    expect(renewed.due, DateTime(2028, 3, 31));
    expect(renewed.done, isFalse);
    expect(renewed.monthlyCents, 1999);
    expect(renewed.cancelBy, DateTime(2027, 12, 31));
    // A car inspection moves on from the day it was done.
    final car = Deadline(
      id: 'd1',
      title: 'HU/TÜV',
      due: DateTime(2027, 3, 31),
      repeatMonths: 24,
    );
    expect(car.completed(DateTime(2027, 3, 2)).due, DateTime(2029, 3, 2));
  });

  test('cancelled: done, ending with the term', () {
    final c = phone.cancelled(DateTime(2026, 12, 10));
    expect(c.done, isTrue);
    expect(c.due, DateTime(2027, 3, 31));
    expect(c.lastDone, DateTime(2026, 12, 10));
  });

  test('stored and read back', () {
    final again = Deadline.fromRecord(
      SyncRecord(
        collection: Collections.deadlines,
        id: 'c1',
        data: phone.toData(),
        updatedAt: 0,
      ),
    );
    expect(again.area, DeadlineArea.contract);
    expect(again.noticeMonths, 3);
    expect(again.monthlyCents, 1999);
    expect(again.inBudget, isTrue);
    expect(again.budgetCategory, 'Sonstiges');
    expect(again.cancelBy, phone.cancelBy);
  });
}

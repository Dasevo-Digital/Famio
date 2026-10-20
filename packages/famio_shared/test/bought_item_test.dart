import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('a bought item survives the record and knows when it is due', () {
    final item = BoughtItem(
      key: 'windeln',
      name: 'Windeln',
      quantity: '1 Packung',
      count: 4,
      lastBought: DateTime.utc(2026, 10, 6, 17),
      listId: 'l',
      everyDays: 14,
    );
    final back = BoughtItem.fromRecord(
      SyncRecord(
        collection: Collections.shoppingHistory,
        id: 'windeln',
        data: item.toData(),
        updatedAt: 1,
      ),
    );
    expect(
      (back.name, back.quantity, back.count, back.listId, back.everyDays),
      ('Windeln', '1 Packung', 4, 'l', 14),
    );
    expect(back.lastBought, DateTime.utc(2026, 10, 6, 17));
    expect(back.nextDue, isNotNull);
    // Put back later than bought: counts from then.
    final added = back.copyWith(lastAdded: DateTime(2026, 10, 25, 9));
    expect(added.nextDue, DateTime(2026, 11, 8));
    expect(added.copyWith(everyDays: () => null).nextDue, isNull);
    expect(Collections.all, contains(Collections.shoppingHistory));
    expect(Collections.guestWritable, contains(Collections.shoppingHistory));
  });
}

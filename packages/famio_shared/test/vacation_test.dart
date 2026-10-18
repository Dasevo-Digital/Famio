import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('a holiday covers its first and last day, whatever the time', () {
    final v = Vacation(
      id: 'v',
      from: DateTime(2026, 10, 24),
      to: DateTime(2026, 10, 31),
    );
    expect(v.covers(DateTime(2026, 10, 23, 23, 59)), isFalse);
    expect(v.covers(DateTime(2026, 10, 24)), isTrue);
    // Across the clock change on the 25th.
    expect(v.covers(DateTime(2026, 10, 31, 23, 30)), isTrue);
    expect(v.covers(DateTime(2026, 11, 1)), isFalse);
    expect(vacationOn([v], DateTime(2026, 10, 27))?.id, 'v');
  });

  test('stored as days, read back the same', () {
    final v = Vacation(
      id: 'v',
      from: DateTime(2026, 12, 23),
      to: DateTime(2027, 1, 6),
      title: 'Weihnachten',
      allowance: true,
    );
    final back = Vacation.fromRecord(
      SyncRecord(
        collection: Collections.vacations,
        id: 'v',
        data: v.toData(),
        updatedAt: 1,
      ),
    );
    expect(back.toData(), v.toData());
    expect(back.from, DateTime(2026, 12, 23));
  });
}

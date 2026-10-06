import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/holidays.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => familyHolidayRegion = null);

  test('the calendar shows the state\'s public holidays', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    List<String> titles() => [
      for (final o in engine.occurrences(
        DateTime(2026, 10, 1),
        DateTime(2026, 11, 2),
      ))
        o.event.title,
    ];
    expect(titles(), isEmpty);

    familyHolidayRegion = GermanState.nw;
    expect(titles(), ['Tag der Deutschen Einheit', 'Allerheiligen']);
    final unity = engine
        .occurrences(DateTime(2026, 10, 3), DateTime(2026, 10, 4))
        .single;
    expect(unity.event.allDay, isTrue);
    expect(isHolidaySource(unity.event.sourceId), isTrue);

    familyHolidayRegion = GermanState.sn;
    expect(titles(), ['Tag der Deutschen Einheit', 'Reformationstag']);
  });
}

import 'package:famio/src/data/engine_memo.dart';
import 'package:famio/src/data/family_data.dart';
import 'package:famio/src/data/memories.dart';
import 'package:famio_client/famio_client.dart';
import 'package:flutter_test/flutter_test.dart';

SyncEngine _engine() => SyncEngine(
  store: LocalStore.open(':memory:')..setMeta('members', '[]'),
  api: FamioApiClient('localhost:1'),
  memberId: 'm1',
);

void main() {
  test('kept until one of its collections changes', () async {
    final e = _engine();
    var computed = 0;
    int value() => EngineMemo.of(e).get('k', {Collections.events}, () {
      return ++computed;
    });
    expect((value(), value()), (1, 1));

    // A location report (another collection): still the same.
    e.put(Collections.memberLocations, 'm1', const {'state': 'active'});
    await Future<void>.delayed(Duration.zero);
    expect(value(), 1);

    e.saveEvent(
      CalendarEvent(
        id: 'e1',
        title: 'Ausflug',
        start: DateTime(2025, 10, 26),
        end: DateTime(2025, 10, 29),
        allDay: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(value(), 2);
  });

  test('the start page sees new memories of the day', () async {
    final e = _engine();
    final now = DateTime(2026, 10, 26, 9);
    expect(memoriesToday(e, now).isEmpty, isTrue);
    e.saveEvent(
      CalendarEvent(
        id: 'e1',
        title: 'Ostsee',
        start: DateTime(2025, 10, 25),
        end: DateTime(2025, 10, 29),
        allDay: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(memoriesToday(e, now).lines.single.text, 'Ostsee');
    // Same day, later: the stored result.
    expect(
      identical(
        memoriesToday(e, now),
        memoriesToday(e, now.add(const Duration(hours: 3))),
      ),
      isTrue,
    );
  });
}

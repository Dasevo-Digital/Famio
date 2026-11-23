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

  test('Austria shows the state\'s school holidays too (#586)', () {
    final engine = SyncEngine(
      store: LocalStore.open(':memory:'),
      api: FamioApiClient('localhost:1'),
      memberId: 'm1',
    );
    familyHolidayRegion = AustrianState.w;
    final october = engine.occurrences(
      DateTime(2026, 10, 20),
      DateTime(2026, 11, 20),
    );
    expect(
      [for (final o in october) o.event.title],
      [
        'Nationalfeiertag',
        'Herbstferien',
        'Allerheiligen',
        'Allerseelen (schulfrei)',
        'Hl. Leopold (schulfrei)',
      ],
    );
    final autumn = october.firstWhere((o) => o.event.title == 'Herbstferien');
    expect(isSchoolHolidaySource(autumn.event.sourceId), isTrue);
    expect(isHolidaySource(autumn.event.sourceId), isTrue);
    expect(autumn.event.notes, contains('Wien'));
    // Christmas holidays reach into January from the year before.
    final january = engine.occurrences(
      DateTime(2027, 1, 4),
      DateTime(2027, 1, 5),
    );
    expect([for (final o in january) o.event.title], ['Weihnachtsferien']);

    // Switzerland: holidays of the canton, no school holidays.
    familyHolidayRegion = SwissCanton.ge;
    final september = engine.occurrences(
      DateTime(2026, 9, 1),
      DateTime(2026, 10, 1),
    );
    expect([for (final o in september) o.event.title], ['Genfer Bettag']);
    expect(isSchoolHolidaySource(september.single.event.sourceId), isFalse);
  });
}

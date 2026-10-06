import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

void main() {
  test('Easter', () {
    expect(easterSunday(2024), DateTime(2024, 3, 31));
    expect(easterSunday(2025), DateTime(2025, 4, 20));
    expect(easterSunday(2026), DateTime(2026, 4, 5));
    expect(easterSunday(2027), DateTime(2027, 3, 28));
  });

  test('NRW 2026', () {
    final days = {
      for (final h in germanHolidays(2026, GermanState.nw)) h.name: h.date,
    };
    expect(days, hasLength(11));
    expect(days['Karfreitag'], DateTime(2026, 4, 3));
    expect(days['Christi Himmelfahrt'], DateTime(2026, 5, 14));
    expect(days['Fronleichnam'], DateTime(2026, 6, 4));
    expect(days['Allerheiligen'], DateTime(2026, 11, 1));
    expect(days.containsKey('Reformationstag'), isFalse);
  });

  test('regional days', () {
    List<String> names(GermanState s, [int year = 2026]) => [
      for (final h in germanHolidays(year, s)) h.name,
    ];
    expect(names(GermanState.by), contains('Heilige Drei Könige'));
    expect(names(GermanState.be), contains('Internationaler Frauentag'));
    expect(names(GermanState.th), contains('Weltkindertag'));
    expect(names(GermanState.hh), contains('Reformationstag'));
    expect(names(GermanState.hh, 2017), isNot(contains('Reformationstag')));
    expect(
      names(GermanState.bb),
      containsAll(['Ostersonntag', 'Pfingstsonntag']),
    );
    final repentance = germanHolidays(
      2026,
      GermanState.sn,
    ).firstWhere((h) => h.name == 'Buß- und Bettag');
    expect(repentance.date, DateTime(2026, 11, 18));
    expect(repentance.date.weekday, DateTime.wednesday);
    expect(
      GermanState.parse('NW')!.schoolHolidaysUrl,
      endsWith('schulferien-nordrhein-westfalen.ics'),
    );
  });
}

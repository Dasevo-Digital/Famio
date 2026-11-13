import 'package:famio_server/src/calendar/school_holidays.dart';
import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// The public school holiday feed was found outdated in places: the KMK's
/// dates take over where they exist.
void main() {
  CalendarEvent day(String id, DateTime first, DateTime end) => CalendarEvent(
    id: id,
    title: id,
    start: first,
    end: end,
    allDay: true,
    sourceId: 'sub',
  );
  final from = DateTime.utc(2026, 1, 1);
  final to = DateTime.utc(2029, 1, 1);

  test('the feed of a state is recognised by its address', () {
    expect(
      schoolHolidayState(GermanState.mv.schoolHolidaysUrl),
      GermanState.mv,
    );
    expect(schoolHolidayState('https://example.org/ferien.ics'), isNull);
  });

  test('summer holidays that run into August stay (Bavaria)', () {
    final feed = [
      day('summer26', DateTime.utc(2026, 8, 3), DateTime.utc(2026, 9, 15)),
      // Shifted a little against the KMK's 2–7 November: replaced.
      day('autumn26', DateTime.utc(2026, 11, 3), DateTime.utc(2026, 11, 8)),
    ];
    final events = withOfficialSchoolHolidays(
      GermanState.by,
      feed,
      sourceId: 'sub',
      from: from,
      to: to,
    );
    final ids = events.map((e) => e.id).toList();
    expect(ids, contains('summer26'));
    expect(ids, isNot(contains('autumn26')));
    expect(
      events.where(
        (e) =>
            e.start.isBefore(DateTime.utc(2026, 8, 11)) &&
            e.end.isAfter(DateTime.utc(2026, 8, 10)),
      ),
      hasLength(1),
    );
  });

  test('official dates replace the feed for 2026/27, later ones stay', () {
    final feed = [
      day('summer26', DateTime.utc(2026, 7, 13), DateTime.utc(2026, 8, 23)),
      // Outdated: the KMK has 15–24 October.
      day('autumn26', DateTime.utc(2026, 10, 19), DateTime.utc(2026, 10, 25)),
      day('autumn27', DateTime.utc(2027, 10, 11), DateTime.utc(2027, 10, 16)),
    ];
    final events = withOfficialSchoolHolidays(
      GermanState.mv,
      feed,
      sourceId: 'sub',
      from: from,
      to: to,
    );
    final ids = events.map((e) => e.id).toList();
    expect(ids, contains('summer26'));
    expect(ids, contains('autumn27'));
    expect(ids, isNot(contains('autumn26')));
    final autumn = events.firstWhere(
      (e) => e.start == DateTime.utc(2026, 10, 15),
    );
    expect(autumn.end, DateTime.utc(2026, 10, 25));
    expect(autumn.allDay, isTrue);
    expect(autumn.title, 'Herbstferien Mecklenburg-Vorpommern 2026');
    final easter = events.firstWhere(
      (e) => e.start == DateTime.utc(2027, 3, 24),
    );
    expect(easter.end, DateTime.utc(2027, 4, 3));
    // Stable ids: a later import updates the same events.
    final again = withOfficialSchoolHolidays(
      GermanState.mv,
      feed,
      sourceId: 'sub',
      from: from,
      to: to,
    );
    expect(again.map((e) => e.id), ids);
  });

  test('a day the feed lacks is added, once', () {
    final events = withOfficialSchoolHolidays(
      GermanState.sh,
      const [],
      sourceId: 'sub',
      from: from,
      to: to,
    );
    expect(
      events.where((e) => e.start == DateTime.utc(2027, 5, 7)),
      hasLength(1),
    );
    expect(
      events.where((e) => e.start == DateTime.utc(2028, 5, 26)),
      hasLength(1),
    );
    final covered = withOfficialSchoolHolidays(
      GermanState.sh,
      [day('whitsun28', DateTime.utc(2028, 5, 26), DateTime.utc(2028, 5, 27))],
      sourceId: 'sub',
      from: from,
      to: to,
    );
    expect(
      covered.where((e) => e.start == DateTime.utc(2028, 5, 26)),
      hasLength(1),
    );
  });

  test('every state has the official school year', () {
    for (final state in GermanState.values) {
      final list = officialSchoolHolidays[state]!;
      expect(list.any((h) => h.kind == SchoolHolidayKind.summer), isTrue);
      for (final h in list) {
        expect(h.end.isAfter(h.first), isTrue, reason: state.code);
        expect(h.first.isBefore(officialSchoolHolidaysFrom), isFalse);
      }
    }
  });
}

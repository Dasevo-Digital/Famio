/// School holidays as the Kultusministerkonferenz publishes them, for the
/// school years it lists (first and last day of each period). They take the
/// place of the public feed's dates there: that feed reaches further ahead
/// but was found outdated in places. Update with the KMK table every year:
/// https://www.kmk.org/service/ferienregelung/ferienkalender.html
library;

import '../texts.dart';
import 'holidays.dart';

enum SchoolHolidayKind {
  autumn('Herbstferien'),
  christmas('Weihnachtsferien'),
  winter('Winterferien'),
  spring('Oster-/Frühjahrsferien'),
  whitsun('Himmelfahrts-/Pfingstferien'),
  summer('Sommerferien');

  const SchoolHolidayKind(this.title);

  /// As the imported feed names them (German, like the feed itself).
  final String title;
}

class SchoolHoliday {
  const SchoolHoliday.autumn(this._first, this._last)
    : kind = SchoolHolidayKind.autumn;
  const SchoolHoliday.christmas(this._first, this._last)
    : kind = SchoolHolidayKind.christmas;
  const SchoolHoliday.winter(this._first, this._last)
    : kind = SchoolHolidayKind.winter;
  const SchoolHoliday.spring(this._first, this._last)
    : kind = SchoolHolidayKind.spring;
  const SchoolHoliday.whitsun(this._first, this._last)
    : kind = SchoolHolidayKind.whitsun;
  const SchoolHoliday.summer(this._first, this._last)
    : kind = SchoolHolidayKind.summer;

  final SchoolHolidayKind kind;
  final String _first;
  final String _last;

  /// First day, as an all-day date (UTC midnight, like imported ones).
  DateTime get first => DateTime.parse('${_first}T00:00:00Z');

  /// The day after the last one: where the all-day event ends.
  DateTime get end {
    final last = DateTime.parse('${_last}T00:00:00Z');
    return DateTime.utc(last.year, last.month, last.day + 1);
  }
}

/// Where the official list starts: the school year 2026/27. Feed dates from
/// here up to the end of the last official period are replaced.
final officialSchoolHolidaysFrom = DateTime.utc(2026, 8);

/// KMK, "Ferien im Schuljahr 2026/2027" (Stand 09.10.2025).
const officialSchoolHolidays = <GermanState, List<SchoolHoliday>>{
  GermanState.bw: [
    SchoolHoliday.autumn('2026-10-26', '2026-10-31'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-09'),
    SchoolHoliday.spring('2027-03-25', '2027-03-25'),
    SchoolHoliday.spring('2027-03-30', '2027-04-03'),
    SchoolHoliday.whitsun('2027-05-18', '2027-05-29'),
    SchoolHoliday.summer('2027-07-29', '2027-09-11'),
  ],
  GermanState.by: [
    SchoolHoliday.autumn('2026-11-02', '2026-11-06'),
    SchoolHoliday.christmas('2026-12-24', '2027-01-08'),
    SchoolHoliday.spring('2027-02-08', '2027-02-12'),
    SchoolHoliday.spring('2027-03-22', '2027-04-02'),
    SchoolHoliday.whitsun('2027-05-18', '2027-05-28'),
    SchoolHoliday.summer('2027-08-02', '2027-09-13'),
  ],
  GermanState.be: [
    SchoolHoliday.autumn('2026-10-19', '2026-10-31'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-02'),
    SchoolHoliday.winter('2027-02-01', '2027-02-06'),
    SchoolHoliday.spring('2027-03-22', '2027-04-02'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-07'),
    SchoolHoliday.whitsun('2027-05-18', '2027-05-19'),
    SchoolHoliday.summer('2027-07-01', '2027-08-14'),
  ],
  GermanState.bb: [
    SchoolHoliday.autumn('2026-10-19', '2026-10-30'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-02'),
    SchoolHoliday.winter('2027-02-01', '2027-02-06'),
    SchoolHoliday.spring('2027-03-22', '2027-04-03'),
    SchoolHoliday.whitsun('2027-05-18', '2027-05-18'),
    SchoolHoliday.summer('2027-07-01', '2027-08-14'),
  ],
  GermanState.hb: [
    SchoolHoliday.autumn('2026-10-12', '2026-10-24'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-09'),
    SchoolHoliday.winter('2027-02-01', '2027-02-02'),
    SchoolHoliday.spring('2027-03-22', '2027-04-03'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-07'),
    SchoolHoliday.whitsun('2027-05-18', '2027-05-18'),
    SchoolHoliday.summer('2027-07-08', '2027-08-18'),
  ],
  GermanState.hh: [
    SchoolHoliday.autumn('2026-10-19', '2026-10-30'),
    SchoolHoliday.christmas('2026-12-21', '2027-01-01'),
    SchoolHoliday.winter('2027-01-29', '2027-01-29'),
    SchoolHoliday.spring('2027-03-01', '2027-03-12'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-14'),
    SchoolHoliday.summer('2027-07-01', '2027-08-11'),
  ],
  GermanState.he: [
    SchoolHoliday.autumn('2026-10-05', '2026-10-17'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-12'),
    SchoolHoliday.spring('2027-03-22', '2027-04-02'),
    SchoolHoliday.summer('2027-06-28', '2027-08-06'),
  ],
  GermanState.mv: [
    SchoolHoliday.autumn('2026-10-15', '2026-10-24'),
    SchoolHoliday.christmas('2026-12-21', '2027-01-02'),
    SchoolHoliday.winter('2027-02-08', '2027-02-19'),
    SchoolHoliday.spring('2027-03-24', '2027-04-02'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-07'),
    SchoolHoliday.whitsun('2027-05-14', '2027-05-18'),
    SchoolHoliday.summer('2027-07-05', '2027-08-14'),
  ],
  GermanState.ni: [
    SchoolHoliday.autumn('2026-10-12', '2026-10-24'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-09'),
    SchoolHoliday.winter('2027-02-01', '2027-02-02'),
    SchoolHoliday.spring('2027-03-22', '2027-04-03'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-07'),
    SchoolHoliday.whitsun('2027-05-18', '2027-05-18'),
    SchoolHoliday.summer('2027-07-08', '2027-08-18'),
  ],
  GermanState.nw: [
    SchoolHoliday.autumn('2026-10-17', '2026-10-31'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-06'),
    SchoolHoliday.spring('2027-03-22', '2027-04-03'),
    SchoolHoliday.whitsun('2027-05-18', '2027-05-18'),
    SchoolHoliday.summer('2027-07-19', '2027-08-31'),
  ],
  GermanState.rp: [
    SchoolHoliday.autumn('2026-10-05', '2026-10-16'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-08'),
    SchoolHoliday.spring('2027-03-22', '2027-04-02'),
    SchoolHoliday.summer('2027-06-28', '2027-08-06'),
  ],
  GermanState.sl: [
    SchoolHoliday.autumn('2026-10-05', '2026-10-16'),
    SchoolHoliday.christmas('2026-12-21', '2026-12-31'),
    SchoolHoliday.winter('2027-02-08', '2027-02-12'),
    SchoolHoliday.spring('2027-03-30', '2027-04-09'),
    SchoolHoliday.summer('2027-06-28', '2027-08-06'),
  ],
  GermanState.sn: [
    SchoolHoliday.autumn('2026-10-12', '2026-10-24'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-02'),
    SchoolHoliday.winter('2027-02-08', '2027-02-19'),
    SchoolHoliday.spring('2027-03-26', '2027-04-02'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-07'),
    SchoolHoliday.whitsun('2027-05-15', '2027-05-18'),
    SchoolHoliday.summer('2027-07-10', '2027-08-20'),
  ],
  GermanState.st: [
    SchoolHoliday.autumn('2026-10-19', '2026-10-30'),
    SchoolHoliday.christmas('2026-12-21', '2027-01-02'),
    SchoolHoliday.winter('2027-02-01', '2027-02-06'),
    SchoolHoliday.spring('2027-03-22', '2027-03-27'),
    SchoolHoliday.whitsun('2027-05-15', '2027-05-22'),
    SchoolHoliday.summer('2027-07-10', '2027-08-20'),
  ],
  GermanState.sh: [
    SchoolHoliday.autumn('2026-10-12', '2026-10-24'),
    SchoolHoliday.christmas('2026-12-21', '2027-01-06'),
    SchoolHoliday.spring('2027-03-30', '2027-04-10'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-07'),
    SchoolHoliday.summer('2027-07-03', '2027-08-14'),
  ],
  GermanState.th: [
    SchoolHoliday.autumn('2026-10-12', '2026-10-24'),
    SchoolHoliday.christmas('2026-12-23', '2027-01-02'),
    SchoolHoliday.winter('2027-02-01', '2027-02-06'),
    SchoolHoliday.spring('2027-03-22', '2027-04-03'),
    SchoolHoliday.whitsun('2027-05-07', '2027-05-07'),
    SchoolHoliday.summer('2027-07-10', '2027-08-20'),
  ],
};

/// Days the feed lacks beyond the official list, from the states' own
/// ordinances (Schleswig-Holstein, Landesverordnung über Ferientermine).
const schoolHolidayAdditions = <GermanState, List<SchoolHoliday>>{
  GermanState.sh: [SchoolHoliday.whitsun('2028-05-26', '2028-05-26')],
};

/// The state whose school holiday feed [url] is, if any.
GermanState? schoolHolidayState(String url) {
  final trimmed = url.trim();
  for (final s in GermanState.values) {
    if (s.schoolHolidaysUrl == trimmed) return s;
  }
  return null;
}

/// A school holiday or school-free day computed by rule (Austria).
class SchoolHolidayPeriod {
  const SchoolHolidayPeriod(this.first, this.last, this._title);

  /// First and last day, local midnight.
  final DateTime first;
  final DateTime last;
  final String _title;

  /// The title in the language of [sharedTexts].
  String get title => sharedText('SchoolHolidayPeriod|$_title', _title);

  @override
  String toString() =>
      '$_title ${first.toIso8601String().substring(0, 10)}–'
      '${last.toIso8601String().substring(0, 10)}';
}

/// Semester holidays a ministerial decree moved by one week (Schulzeitgesetz
/// § 2 Abs. 2a), by the February they fall in. 2027: Salzburg, Tirol and
/// Vorarlberg (BGBl. II Nr. 297/2025 and the decrees for Salzburg and Tirol;
/// BMB, Ferientermine 2026/27). Add new decrees here.
const _semesterMoved = <int, Set<AustrianState>>{
  2027: {AustrianState.s, AustrianState.t, AustrianState.v},
};

/// The school holidays and school-free days of [state] that begin in
/// [year], after the Schulzeitgesetz 1985 § 2 (RIS, as of 23.11.2026):
/// semester, Easter, Whitsun, summer, autumn and Christmas holidays, All
/// Souls' Day and the state's patron day (BMB, "Feiertage"). Single schools
/// may differ; decrees that move the semester holidays are in
/// [_semesterMoved].
List<SchoolHolidayPeriod> austrianSchoolHolidays(
  int year,
  AustrianState state,
) {
  DateTime day(int month, int d) => DateTime(year, month, d);
  DateTime plus(DateTime date, int days) =>
      DateTime(date.year, date.month, date.day + days);
  // The [n]th [weekday] of [month].
  DateTime nth(int month, int weekday, int n) {
    final first = day(month, 1);
    return day(month, 1 + (weekday - first.weekday) % 7 + 7 * (n - 1));
  }

  final east = {AustrianState.b, AustrianState.n, AustrianState.w};
  final easter = easterSunday(year);
  // Semester: one week from the first Monday in February in Lower Austria
  // and Vienna, the second in Burgenland, Carinthia, Salzburg, Tyrol and
  // Vorarlberg, the third in Upper Austria and Styria.
  final week = switch (state) {
    AustrianState.n || AustrianState.w => 1,
    AustrianState.o || AustrianState.st => 3,
    _ => 2,
  };
  final moved = _semesterMoved[year]?.contains(state) ?? false;
  final semester = nth(2, DateTime.monday, week + (moved ? 1 : 0));
  // Summer: from the Saturday between 28 June and 4 July in the east, 5 to
  // 11 July elsewhere, until the school year starts on the first (east) or
  // second Monday in September.
  final summerFrom = east.contains(state) ? day(6, 28) : day(7, 5);
  final summerStart = plus(
    summerFrom,
    (DateTime.saturday - summerFrom.weekday) % 7,
  );
  final schoolStarts = nth(9, DateTime.monday, east.contains(state) ? 1 : 2);
  final (patronDate, patronName) = switch (state) {
    AustrianState.b => (day(11, 11), 'Hl. Martin (schulfrei)'),
    AustrianState.k ||
    AustrianState.st ||
    AustrianState.t ||
    AustrianState.v => (day(3, 19), 'Hl. Josef (schulfrei)'),
    AustrianState.n ||
    AustrianState.w => (day(11, 15), 'Hl. Leopold (schulfrei)'),
    AustrianState.o => (day(5, 4), 'Hl. Florian (schulfrei)'),
    AustrianState.s => (day(9, 24), 'Hl. Rupert (schulfrei)'),
  };
  final list = [
    SchoolHolidayPeriod(semester, plus(semester, 5), 'Semesterferien'),
    SchoolHolidayPeriod(plus(easter, -8), plus(easter, 1), 'Osterferien'),
    SchoolHolidayPeriod(plus(easter, 48), plus(easter, 50), 'Pfingstferien'),
    SchoolHolidayPeriod(summerStart, plus(schoolStarts, -1), 'Sommerferien'),
    // Autumn holidays since the school year 2020/21.
    if (year >= 2020)
      SchoolHolidayPeriod(day(10, 27), day(10, 31), 'Herbstferien'),
    SchoolHolidayPeriod(day(11, 2), day(11, 2), 'Allerseelen (schulfrei)'),
    SchoolHolidayPeriod(patronDate, patronDate, patronName),
    SchoolHolidayPeriod(
      day(12, 24),
      DateTime(year + 1, 1, 6),
      'Weihnachtsferien',
    ),
  ];
  return list..sort((a, b) => a.first.compareTo(b.first));
}

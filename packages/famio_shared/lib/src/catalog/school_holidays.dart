/// School holidays as the Kultusministerkonferenz publishes them, for the
/// school years it lists (first and last day of each period). They take the
/// place of the public feed's dates there: that feed reaches further ahead
/// but was found outdated in places. Update with the KMK table every year:
/// https://www.kmk.org/service/ferienregelung/ferienkalender.html
library;

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

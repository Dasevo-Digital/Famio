/// Public holidays in Germany per federal state, computed offline (Easter
/// by the Gauss/Meeus algorithm), and the school holiday calendars a family
/// can subscribe to.
library;

import '../texts.dart';

/// A German federal state; [code] is stored in the server settings.
enum GermanState {
  bw('BW', 'Baden-Württemberg', 'baden-wuerttemberg'),
  by('BY', 'Bayern', 'bayern'),
  be('BE', 'Berlin', 'berlin'),
  bb('BB', 'Brandenburg', 'brandenburg'),
  hb('HB', 'Bremen', 'bremen'),
  hh('HH', 'Hamburg', 'hamburg'),
  he('HE', 'Hessen', 'hessen'),
  mv('MV', 'Mecklenburg-Vorpommern', 'mecklenburg-vorpommern'),
  ni('NI', 'Niedersachsen', 'niedersachsen'),
  nw('NW', 'Nordrhein-Westfalen', 'nordrhein-westfalen'),
  rp('RP', 'Rheinland-Pfalz', 'rheinland-pfalz'),
  sl('SL', 'Saarland', 'saarland'),
  sn('SN', 'Sachsen', 'sachsen'),
  st('ST', 'Sachsen-Anhalt', 'sachsen-anhalt'),
  sh('SH', 'Schleswig-Holstein', 'schleswig-holstein'),
  th('TH', 'Thüringen', 'thueringen');

  const GermanState(this.code, this._label, this._slug);

  final String code;
  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('GermanState.$name', _label);
  final String _slug;

  static GermanState? parse(Object? code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }

  /// School holidays of this state as an ICS subscription (public source,
  /// without warranty), for the server's calendar import.
  String get schoolHolidaysUrl =>
      'https://www.feiertage-deutschland.de/content/kalender-download/ics/'
      'schulferien-$_slug.ics';
}

class Holiday {
  const Holiday(this.date, this._name);

  /// Local midnight.
  final DateTime date;
  final String _name;
  String get name => sharedText('Holiday|$_name', _name);

  @override
  String toString() => '$name (${date.toIso8601String().substring(0, 10)})';
}

/// Easter Sunday of [year] (Gregorian calendar).
DateTime easterSunday(int year) {
  final a = year % 19;
  final b = year ~/ 100;
  final c = year % 100;
  final d = b ~/ 4;
  final e = b % 4;
  final f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4;
  final k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31;
  final day = (h + l - 7 * m + 114) % 31 + 1;
  return DateTime(year, month, day);
}

/// The statutory public holidays of [state] in [year], by date. Holidays
/// that only apply in some municipalities (e.g. Mariä Himmelfahrt in parts
/// of Bavaria, Fronleichnam in parts of Saxony and Thuringia) are left out.
List<Holiday> germanHolidays(int year, GermanState state) {
  final easter = easterSunday(year);
  DateTime fromEaster(int days) =>
      DateTime(easter.year, easter.month, easter.day + days);
  bool inState(Set<GermanState> states) => states.contains(state);
  // Buß- und Bettag: the Wednesday before 23 November.
  final nov22 = DateTime(year, 11, 22);
  final repentance = DateTime(
    year,
    11,
    22 - ((nov22.weekday - DateTime.wednesday) % 7),
  );
  final list = [
    Holiday(DateTime(year), 'Neujahr'),
    if (inState({GermanState.bw, GermanState.by, GermanState.st}))
      Holiday(DateTime(year, 1, 6), 'Heilige Drei Könige'),
    if (inState({GermanState.be}) || (state == GermanState.mv && year >= 2023))
      Holiday(DateTime(year, 3, 8), 'Internationaler Frauentag'),
    Holiday(fromEaster(-2), 'Karfreitag'),
    if (inState({GermanState.bb})) Holiday(easter, 'Ostersonntag'),
    Holiday(fromEaster(1), 'Ostermontag'),
    Holiday(DateTime(year, 5, 1), 'Tag der Arbeit'),
    Holiday(fromEaster(39), 'Christi Himmelfahrt'),
    if (inState({GermanState.bb})) Holiday(fromEaster(49), 'Pfingstsonntag'),
    Holiday(fromEaster(50), 'Pfingstmontag'),
    if (inState({
      GermanState.bw,
      GermanState.by,
      GermanState.he,
      GermanState.nw,
      GermanState.rp,
      GermanState.sl,
    }))
      Holiday(fromEaster(60), 'Fronleichnam'),
    if (inState({GermanState.sl}))
      Holiday(DateTime(year, 8, 15), 'Mariä Himmelfahrt'),
    if (state == GermanState.th && year >= 2019)
      Holiday(DateTime(year, 9, 20), 'Weltkindertag'),
    Holiday(DateTime(year, 10, 3), 'Tag der Deutschen Einheit'),
    if (inState({
          GermanState.bb,
          GermanState.mv,
          GermanState.sn,
          GermanState.st,
          GermanState.th,
        }) ||
        (year >= 2018 &&
            inState({
              GermanState.hb,
              GermanState.hh,
              GermanState.ni,
              GermanState.sh,
            })))
      Holiday(DateTime(year, 10, 31), 'Reformationstag'),
    if (inState({
      GermanState.bw,
      GermanState.by,
      GermanState.nw,
      GermanState.rp,
      GermanState.sl,
    }))
      Holiday(DateTime(year, 11, 1), 'Allerheiligen'),
    if (inState({GermanState.sn})) Holiday(repentance, 'Buß- und Bettag'),
    Holiday(DateTime(year, 12, 25), '1. Weihnachtstag'),
    Holiday(DateTime(year, 12, 26), '2. Weihnachtstag'),
  ];
  return list..sort((a, b) => a.date.compareTo(b.date));
}

/// Public holidays in Germany, Austria and Switzerland per federal state or
/// canton, computed offline (Easter by the Gauss/Meeus algorithm), and the
/// school holiday calendars a family can subscribe to.
library;

import '../texts.dart';

/// The country whose rules Famio follows for the family (server setting
/// `country`): emergency numbers, public holidays, and whether the German
/// check-up, vaccination and maternity rules apply. Unset means Germany.
enum FamilyCountry {
  de('DE', 'Deutschland'),
  at('AT', 'Österreich'),
  ch('CH', 'Schweiz');

  const FamilyCountry(this.code, this._label);

  final String code;
  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('FamilyCountry.$name', _label);

  static FamilyCountry? parse(Object? code) {
    for (final c in values) {
      if (c.code == code) return c;
    }
    return null;
  }

  /// The federal states or cantons with their own public holidays.
  List<HolidayRegion> get regions => switch (this) {
    de => GermanState.values,
    at => AustrianState.values,
    ch => SwissCanton.values,
  };
}

/// A part of a country with its own public holidays; [code] is stored in
/// the server settings (`holidayRegion`).
abstract interface class HolidayRegion {
  /// German states keep their old two-letter codes (`NW`); Austrian states
  /// and Swiss cantons use ISO 3166-2 (`AT-9`, `CH-ZH`), so an older app
  /// never mistakes Bern for Berlin.
  String get code;

  /// The label in the language of [sharedTexts].
  String get label;

  /// The German name, for texts that stay German.
  String get germanName;

  FamilyCountry get country;

  /// The public holidays in [year], by date.
  List<Holiday> holidays(int year);
}

/// The region stored under [code], in any of the three countries.
HolidayRegion? parseHolidayRegion(Object? code) =>
    GermanState.parse(code) ??
    AustrianState.parse(code) ??
    SwissCanton.parse(code);

/// A German federal state; [code] is stored in the server settings.
enum GermanState implements HolidayRegion {
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

  @override
  final String code;
  final String _label;

  /// The label in the language of [sharedTexts].
  @override
  String get label => sharedText('GermanState.$name', _label);

  /// The German name, for texts that stay German (imported calendars).
  @override
  String get germanName => _label;
  final String _slug;

  @override
  FamilyCountry get country => FamilyCountry.de;

  @override
  List<Holiday> holidays(int year) => germanHolidays(year, this);

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

/// An Austrian federal state (ISO 3166-2:AT).
enum AustrianState implements HolidayRegion {
  b('AT-1', 'Burgenland'),
  k('AT-2', 'Kärnten'),
  n('AT-3', 'Niederösterreich'),
  o('AT-4', 'Oberösterreich'),
  s('AT-5', 'Salzburg'),
  st('AT-6', 'Steiermark'),
  t('AT-7', 'Tirol'),
  v('AT-8', 'Vorarlberg'),
  w('AT-9', 'Wien');

  const AustrianState(this.code, this._label);

  @override
  final String code;
  final String _label;

  @override
  String get label => sharedText('AustrianState.$name', _label);

  @override
  String get germanName => _label;

  @override
  FamilyCountry get country => FamilyCountry.at;

  @override
  List<Holiday> holidays(int year) => austrianHolidays(year);

  static AustrianState? parse(Object? code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// The statutory public holidays in Austria (Arbeitsruhegesetz § 7 Abs. 2,
/// RIS, as of 23.11.2026), the same in every state. Good Friday has not been
/// one since 2019 (BGBl. I Nr. 22/2019). The states' patron days are only
/// school-free (see [austrianSchoolHolidays]), not general days off.
List<Holiday> austrianHolidays(int year) {
  final easter = easterSunday(year);
  DateTime fromEaster(int days) =>
      DateTime(easter.year, easter.month, easter.day + days);
  final list = [
    Holiday(DateTime(year), 'Neujahr'),
    Holiday(DateTime(year, 1, 6), 'Heilige Drei Könige'),
    Holiday(fromEaster(1), 'Ostermontag'),
    Holiday(DateTime(year, 5, 1), 'Staatsfeiertag'),
    Holiday(fromEaster(39), 'Christi Himmelfahrt'),
    Holiday(fromEaster(50), 'Pfingstmontag'),
    Holiday(fromEaster(60), 'Fronleichnam'),
    Holiday(DateTime(year, 8, 15), 'Mariä Himmelfahrt'),
    Holiday(DateTime(year, 10, 26), 'Nationalfeiertag'),
    Holiday(DateTime(year, 11, 1), 'Allerheiligen'),
    Holiday(DateTime(year, 12, 8), 'Mariä Empfängnis'),
    Holiday(DateTime(year, 12, 25), 'Weihnachten'),
    Holiday(DateTime(year, 12, 26), 'Stefanitag'),
  ];
  return list..sort((a, b) => a.date.compareTo(b.date));
}

/// A Swiss canton (ISO 3166-2:CH).
enum SwissCanton implements HolidayRegion {
  zh('CH-ZH', 'Zürich'),
  be('CH-BE', 'Bern'),
  lu('CH-LU', 'Luzern'),
  ur('CH-UR', 'Uri'),
  sz('CH-SZ', 'Schwyz'),
  ow('CH-OW', 'Obwalden'),
  nw('CH-NW', 'Nidwalden'),
  gl('CH-GL', 'Glarus'),
  zg('CH-ZG', 'Zug'),
  fr('CH-FR', 'Freiburg'),
  so('CH-SO', 'Solothurn'),
  bs('CH-BS', 'Basel-Stadt'),
  bl('CH-BL', 'Basel-Landschaft'),
  sh('CH-SH', 'Schaffhausen'),
  ar('CH-AR', 'Appenzell Ausserrhoden'),
  ai('CH-AI', 'Appenzell Innerrhoden'),
  sg('CH-SG', 'St. Gallen'),
  gr('CH-GR', 'Graubünden'),
  ag('CH-AG', 'Aargau'),
  tg('CH-TG', 'Thurgau'),
  ti('CH-TI', 'Tessin'),
  vd('CH-VD', 'Waadt'),
  vs('CH-VS', 'Wallis'),
  ne('CH-NE', 'Neuenburg'),
  ge('CH-GE', 'Genf'),
  ju('CH-JU', 'Jura');

  const SwissCanton(this.code, this._label);

  @override
  final String code;
  final String _label;

  @override
  String get label => sharedText('SwissCanton.$name', _label);

  @override
  String get germanName => _label;

  @override
  FamilyCountry get country => FamilyCountry.ch;

  @override
  List<Holiday> holidays(int year) => swissHolidays(year, this);

  static SwissCanton? parse(Object? code) {
    for (final c in values) {
      if (c.code == code) return c;
    }
    return null;
  }
}

/// The public holidays of [canton] in [year] that apply in the whole
/// canton, after the Federal Office of Justice's list "Gesetzliche Feiertage
/// und Tage, die in der Schweiz wie gesetzliche Feiertage behandelt werden"
/// (Stand 1.1.2011, both recognised and treated-like days). Days only some
/// municipalities keep (Fronleichnam etc. in parts of Fribourg, Josefstag in
/// some Solothurn villages, Mauritiustag in Appenzell's inner part) and the
/// half day on 1 May in Solothurn are left out, as are holidays that always
/// fall on a Sunday. Glarus follows its Ruhetagsgesetz of 2012, which no
/// longer has Berchtoldstag.
List<Holiday> swissHolidays(int year, SwissCanton canton) {
  final easter = easterSunday(year);
  DateTime fromEaster(int days) =>
      DateTime(easter.year, easter.month, easter.day + days);
  bool inCanton(Set<SwissCanton> cantons) => cantons.contains(canton);
  // Catholic holidays in the cantons that keep them throughout.
  const catholic = {
    SwissCanton.lu,
    SwissCanton.ur,
    SwissCanton.sz,
    SwissCanton.ow,
    SwissCanton.nw,
    SwissCanton.zg,
    SwissCanton.so,
    SwissCanton.ai,
    SwissCanton.ag,
    SwissCanton.ti,
    SwissCanton.vs,
    SwissCanton.ju,
  };
  final christmas = DateTime(year, 12, 25);
  final newYear = DateTime(year);
  // Stephanstag: not in Vaud, Geneva and Jura. Uri and the two Appenzell
  // skip it when Christmas is a Monday or Friday; Neuchâtel only keeps it
  // when Christmas is a Sunday (the same goes for 2 January).
  final stephen =
      !inCanton({SwissCanton.vd, SwissCanton.ge, SwissCanton.ju}) &&
      !(inCanton({SwissCanton.ur, SwissCanton.ar, SwissCanton.ai}) &&
          (christmas.weekday == DateTime.monday ||
              christmas.weekday == DateTime.friday)) &&
      !(canton == SwissCanton.ne && christmas.weekday != DateTime.sunday);
  final berchtold =
      inCanton({
        SwissCanton.zh,
        SwissCanton.be,
        SwissCanton.lu,
        SwissCanton.ow,
        SwissCanton.nw,
        SwissCanton.zg,
        SwissCanton.fr,
        SwissCanton.so,
        SwissCanton.sh,
        SwissCanton.sg,
        SwissCanton.ag,
        SwissCanton.tg,
        SwissCanton.vd,
        SwissCanton.vs,
        SwissCanton.ju,
      }) ||
      (canton == SwissCanton.ne && newYear.weekday == DateTime.sunday);
  // Monday after the third Sunday in September (Vaud).
  final sept1 = DateTime(year, 9);
  final firstSunday = DateTime(year, 9, 1 + (7 - sept1.weekday) % 7);
  final fastMonday = DateTime(year, 9, firstSunday.day + 15);
  // Thursday after the first Sunday in September (Geneva).
  final genevaFast = DateTime(year, 9, firstSunday.day + 4);
  final list = [
    Holiday(newYear, 'Neujahr'),
    if (berchtold) Holiday(DateTime(year, 1, 2), 'Berchtoldstag'),
    if (inCanton({SwissCanton.ur, SwissCanton.sz, SwissCanton.ti}))
      Holiday(DateTime(year, 1, 6), 'Heilige Drei Könige'),
    if (canton == SwissCanton.ne)
      Holiday(DateTime(year, 3, 1), 'Jahrestag der Republik Neuenburg'),
    if (inCanton({
      SwissCanton.ur,
      SwissCanton.sz,
      SwissCanton.nw,
      SwissCanton.ti,
      SwissCanton.vs,
    }))
      Holiday(DateTime(year, 3, 19), 'Josefstag'),
    if (canton == SwissCanton.gl)
      Holiday(_nafelserFahrt(year), 'Näfelser Fahrt'),
    if (!inCanton({SwissCanton.ti, SwissCanton.vs}))
      Holiday(fromEaster(-2), 'Karfreitag'),
    if (canton != SwissCanton.ne) Holiday(fromEaster(1), 'Ostermontag'),
    if (inCanton({
      SwissCanton.zh,
      SwissCanton.bs,
      SwissCanton.bl,
      SwissCanton.sh,
      SwissCanton.ag,
      SwissCanton.tg,
      SwissCanton.ti,
      SwissCanton.ne,
      SwissCanton.ju,
    }))
      Holiday(DateTime(year, 5, 1), 'Tag der Arbeit'),
    Holiday(fromEaster(39), 'Auffahrt'),
    if (canton != SwissCanton.ne) Holiday(fromEaster(50), 'Pfingstmontag'),
    if (inCanton(catholic)) Holiday(fromEaster(60), 'Fronleichnam'),
    if (canton == SwissCanton.ju)
      Holiday(DateTime(year, 6, 23), 'Gedenktag des Jura-Plebiszits'),
    if (canton == SwissCanton.ti)
      Holiday(DateTime(year, 6, 29), 'Peter und Paul'),
    Holiday(DateTime(year, 8, 1), 'Bundesfeier'),
    if (inCanton(catholic)) Holiday(DateTime(year, 8, 15), 'Mariä Himmelfahrt'),
    if (canton == SwissCanton.ge) Holiday(genevaFast, 'Genfer Bettag'),
    if (canton == SwissCanton.vd) Holiday(fastMonday, 'Bettagsmontag'),
    if (canton == SwissCanton.ow)
      Holiday(DateTime(year, 9, 25), 'Bruder-Klausen-Fest'),
    if (inCanton({...catholic, SwissCanton.gl, SwissCanton.sg}))
      Holiday(DateTime(year, 11, 1), 'Allerheiligen'),
    if (inCanton(catholic.difference({SwissCanton.so, SwissCanton.ju})))
      Holiday(DateTime(year, 12, 8), 'Mariä Empfängnis'),
    Holiday(christmas, 'Weihnachten'),
    if (stephen) Holiday(DateTime(year, 12, 26), 'Stephanstag'),
    if (canton == SwissCanton.ge)
      Holiday(DateTime(year, 12, 31), 'Wiederherstellung der Republik Genf'),
  ];
  return list..sort((a, b) => a.date.compareTo(b.date));
}

/// Näfelser Fahrt: the first Thursday in April, a week later when that
/// falls in Holy Week. The law gives no rule; this one matches the canton's
/// published dates for 2025 to 2028.
DateTime _nafelserFahrt(int year) {
  final april1 = DateTime(year, 4);
  var day = DateTime(year, 4, 1 + (DateTime.thursday - april1.weekday) % 7);
  final easter = easterSunday(year);
  final palmSunday = DateTime(easter.year, easter.month, easter.day - 7);
  if (day.isAfter(palmSunday) && day.isBefore(easter)) {
    day = DateTime(day.year, day.month, day.day + 7);
  }
  return day;
}

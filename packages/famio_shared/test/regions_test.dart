import 'package:famio_shared/famio_shared.dart';
import 'package:test/test.dart';

/// Holidays of Austria and Switzerland and the regions' codes (#586).
void main() {
  test('regions belong to their country and parse back', () {
    for (final country in FamilyCountry.values) {
      for (final region in country.regions) {
        expect(region.country, country);
        expect(parseHolidayRegion(region.code), region);
      }
    }
    // Bern is not Berlin: older apps only know the German codes.
    expect(GermanState.parse('CH-BE'), isNull);
    expect(parseHolidayRegion('BE'), GermanState.be);
    expect(parseHolidayRegion('CH-BE'), SwissCanton.be);
    expect(parseHolidayRegion('AT-9'), AustrianState.w);
    expect(FamilyCountry.parse('AT'), FamilyCountry.at);
    expect(FamilyCountry.parse('FR'), isNull);
  });

  test('Austria: the thirteen statutory days, no Good Friday', () {
    final days = {
      for (final h in AustrianState.w.holidays(2026)) h.name: h.date,
    };
    expect(days, hasLength(13));
    expect(days.containsKey('Karfreitag'), isFalse);
    expect(days['Staatsfeiertag'], DateTime(2026, 5));
    expect(days['Nationalfeiertag'], DateTime(2026, 10, 26));
    expect(days['Mariä Empfängnis'], DateTime(2026, 12, 8));
    expect(days['Fronleichnam'], DateTime(2026, 6, 4));
    expect(days['Stefanitag'], DateTime(2026, 12, 26));
    // The same in every state.
    for (final s in AustrianState.values) {
      expect(s.holidays(2026).length, 13, reason: s.code);
    }
  });

  group('Switzerland', () {
    Map<String, DateTime> days(SwissCanton c, [int year = 2026]) => {
      for (final h in c.holidays(year)) h.name: h.date,
    };

    test('only Neujahr, Auffahrt, Bundesfeier and Christmas everywhere', () {
      for (final c in SwissCanton.values) {
        expect(
          days(c).keys,
          containsAll(['Neujahr', 'Auffahrt', 'Bundesfeier', 'Weihnachten']),
          reason: c.code,
        );
      }
      expect(days(SwissCanton.zh)['Auffahrt'], DateTime(2026, 5, 14));
    });

    test('Zürich and Bern', () {
      expect(days(SwissCanton.zh).keys.toSet(), {
        'Neujahr',
        'Berchtoldstag',
        'Karfreitag',
        'Ostermontag',
        'Tag der Arbeit',
        'Auffahrt',
        'Pfingstmontag',
        'Bundesfeier',
        'Weihnachten',
        'Stephanstag',
      });
      expect(days(SwissCanton.be).containsKey('Tag der Arbeit'), isFalse);
    });

    test('catholic cantons, Ticino and Valais', () {
      final lu = days(SwissCanton.lu);
      expect(
        lu.keys,
        containsAll([
          'Fronleichnam',
          'Mariä Himmelfahrt',
          'Allerheiligen',
          'Mariä Empfängnis',
        ]),
      );
      for (final c in [SwissCanton.ti, SwissCanton.vs]) {
        expect(days(c).containsKey('Karfreitag'), isFalse, reason: c.code);
        expect(days(c)['Josefstag'], DateTime(2026, 3, 19), reason: c.code);
      }
      expect(days(SwissCanton.ti)['Peter und Paul'], DateTime(2026, 6, 29));
      // Partial days are left out: Fribourg's catholic days, Solothurn's
      // half day on 1 May and its 8 December.
      expect(days(SwissCanton.fr).containsKey('Fronleichnam'), isFalse);
      expect(days(SwissCanton.so).containsKey('Tag der Arbeit'), isFalse);
      expect(days(SwissCanton.so).containsKey('Mariä Empfängnis'), isFalse);
      expect(days(SwissCanton.so).containsKey('Fronleichnam'), isTrue);
    });

    test('the French-speaking cantons', () {
      final ge = days(SwissCanton.ge);
      expect(ge['Genfer Bettag'], DateTime(2026, 9, 10));
      expect(ge['Wiederherstellung der Republik Genf'], DateTime(2026, 12, 31));
      expect(ge.containsKey('Stephanstag'), isFalse);
      expect(days(SwissCanton.vd)['Bettagsmontag'], DateTime(2026, 9, 21));
      expect(days(SwissCanton.vd).containsKey('Stephanstag'), isFalse);
      final ne = days(SwissCanton.ne);
      expect(ne['Jahrestag der Republik Neuenburg'], DateTime(2026, 3));
      expect(ne.containsKey('Ostermontag'), isFalse);
      expect(ne.containsKey('Pfingstmontag'), isFalse);
      // 2 January and 26 December only after a Sunday 1 January/25 December.
      expect(ne.containsKey('Berchtoldstag'), isFalse);
      expect(days(SwissCanton.ne, 2023).containsKey('Berchtoldstag'), isTrue);
      expect(days(SwissCanton.ne, 2022).containsKey('Stephanstag'), isTrue);
      expect(
        days(SwissCanton.ju)['Gedenktag des Jura-Plebiszits'],
        DateTime(2026, 6, 23),
      );
    });

    test('Glarus: Näfelser Fahrt on the canton\'s published dates', () {
      for (final (year, date) in [
        (2025, DateTime(2025, 4, 3)),
        (2026, DateTime(2026, 4, 9)),
        (2027, DateTime(2027, 4, 1)),
        (2028, DateTime(2028, 4, 6)),
      ]) {
        expect(days(SwissCanton.gl, year)['Näfelser Fahrt'], date);
      }
      // No Berchtoldstag since the Ruhetagsgesetz of 2012.
      expect(days(SwissCanton.gl).containsKey('Berchtoldstag'), isFalse);
      expect(days(SwissCanton.gl).containsKey('Allerheiligen'), isTrue);
    });

    test('Stephanstag in Uri and Appenzell after a Monday or Friday', () {
      // 25 December 2026 is a Friday.
      for (final c in [SwissCanton.ur, SwissCanton.ar, SwissCanton.ai]) {
        expect(days(c).containsKey('Stephanstag'), isFalse, reason: c.code);
        expect(days(c, 2025).containsKey('Stephanstag'), isTrue);
      }
    });
  });

  group('Austrian school holidays', () {
    Map<String, (DateTime, DateTime)> periods(AustrianState s, int year) => {
      for (final p in austrianSchoolHolidays(year, s))
        p.title: (p.first, p.last),
    };

    test('school year 2026/27 as the ministry published it', () {
      for (final s in AustrianState.values) {
        final y26 = periods(s, 2026);
        final y27 = periods(s, 2027);
        expect(y26['Herbstferien'], (
          DateTime(2026, 10, 27),
          DateTime(2026, 10, 31),
        ));
        expect(y26['Weihnachtsferien'], (
          DateTime(2026, 12, 24),
          DateTime(2027, 1, 6),
        ));
        expect(y27['Osterferien'], (
          DateTime(2027, 3, 20),
          DateTime(2027, 3, 29),
        ));
        expect(y27['Pfingstferien'], (
          DateTime(2027, 5, 15),
          DateTime(2027, 5, 17),
        ));
        final east = {AustrianState.b, AustrianState.n, AustrianState.w};
        expect(
          y27['Sommerferien'],
          east.contains(s)
              ? (DateTime(2027, 7, 3), DateTime(2027, 9, 5))
              : (DateTime(2027, 7, 10), DateTime(2027, 9, 12)),
          reason: s.code,
        );
        final semesterStart = switch (s) {
          AustrianState.n || AustrianState.w => 1,
          AustrianState.b || AustrianState.k => 8,
          _ => 15,
        };
        expect(y27['Semesterferien'], (
          DateTime(2027, 2, semesterStart),
          DateTime(2027, 2, semesterStart + 5),
        ), reason: s.code);
      }
    });

    test('2028 by the law (Salzburg, Tyrol and Vorarlberg not moved)', () {
      expect(periods(AustrianState.t, 2028)['Semesterferien'], (
        DateTime(2028, 2, 14),
        DateTime(2028, 2, 19),
      ));
      expect(periods(AustrianState.w, 2028)['Sommerferien'], (
        DateTime(2028, 7),
        DateTime(2028, 9, 3),
      ));
      expect(periods(AustrianState.st, 2028)['Osterferien'], (
        DateTime(2028, 4, 8),
        DateTime(2028, 4, 17),
      ));
    });

    test('All Souls\' Day and the patron day are school-free', () {
      expect(periods(AustrianState.w, 2026)['Hl. Leopold (schulfrei)'], (
        DateTime(2026, 11, 15),
        DateTime(2026, 11, 15),
      ));
      expect(
        periods(AustrianState.o, 2026)['Hl. Florian (schulfrei)']!.$1,
        DateTime(2026, 5, 4),
      );
      expect(
        periods(AustrianState.k, 2026)['Allerseelen (schulfrei)']!.$1,
        DateTime(2026, 11, 2),
      );
    });
  });
}

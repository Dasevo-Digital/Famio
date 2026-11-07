import 'package:famio/src/data/event_extract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 6);

  List<(String, DateTime, DateTime, bool)> found(
    String text, {
    String? language,
  }) => [
    for (final e in extractEvents(text, now: now, language: language))
      (e.title, e.start, e.end, e.allDay),
  ];

  test('a letter from school', () {
    const letter = '''
Liebe Eltern,
am Freitag, 16.10., findet um 15:00 Uhr der Elternabend statt.
Laternenfest: 11. November, 17.30 - 19 Uhr
Herbstferien vom 19. bis 30. Oktober
Fotograf: Mittwoch 4.11.2026
''';
    expect(found(letter), [
      (
        'findet der Elternabend statt',
        DateTime(2026, 10, 16, 15),
        DateTime(2026, 10, 16, 16),
        false,
      ),
      ('Herbstferien', DateTime(2026, 10, 19), DateTime(2026, 10, 31), true),
      ('Fotograf', DateTime(2026, 11, 4), DateTime(2026, 11, 5), true),
      (
        'Laternenfest',
        DateTime(2026, 11, 11, 17, 30),
        DateTime(2026, 11, 11, 19),
        false,
      ),
    ]);
  });

  test('ranges, next year and the line before', () {
    expect(found('Klassenfahrt\n2.–6.3.'), [
      ('Klassenfahrt', DateTime(2027, 3, 2), DateTime(2027, 3, 7), true),
    ]);
    // A time is no date; "12.30 Uhr" alone gives nothing.
    expect(found('Mittag um 12.30 Uhr'), isEmpty);
    expect(found('Arzt 3.10.26 um 9 Uhr').single.$2, DateTime(2026, 10, 3, 9));
    expect(found('Kein Datum 31.2.'), isEmpty);
  });

  test('a letter in English', () {
    const letter = '''
Dear parents,
the parent evening is on Friday, October 16 at 3:00 pm.
Lantern festival: November 11, 5:30 - 7 pm
Autumn break from October 19 to 30
Photographer: Wed, 11/4/2026
Sports day on the 12th of December, 10 am – 12 pm
School trip
March 2-6
''';
    expect(found(letter), [
      (
        'parent evening is',
        DateTime(2026, 10, 16, 15),
        DateTime(2026, 10, 16, 16),
        false,
      ),
      ('Autumn break', DateTime(2026, 10, 19), DateTime(2026, 10, 31), true),
      ('Photographer', DateTime(2026, 11, 4), DateTime(2026, 11, 5), true),
      (
        'Lantern festival',
        DateTime(2026, 11, 11, 17, 30),
        DateTime(2026, 11, 11, 19),
        false,
      ),
      (
        'Sports day',
        DateTime(2026, 12, 12, 10),
        DateTime(2026, 12, 12, 12),
        false,
      ),
      ('School trip', DateTime(2027, 3, 2), DateTime(2027, 3, 7), true),
    ]);
  });

  test('a letter in Spanish', () {
    const letter = '''
Queridas familias:
la reunión de padres será el viernes 16 de octubre a las 18:00 h.
Fiesta de otoño: 11 de noviembre, de 17:30 a 19 h
Vacaciones del 19 al 30 de octubre
Fotógrafo: miércoles 4/11/2026
Excursión el 12 de diciembre a las 9 de la mañana
Teatro el 15 de enero a las 6 de la tarde
''';
    expect(found(letter), [
      (
        'reunión de padres será',
        DateTime(2026, 10, 16, 18),
        DateTime(2026, 10, 16, 19),
        false,
      ),
      ('Vacaciones', DateTime(2026, 10, 19), DateTime(2026, 10, 31), true),
      ('Fotógrafo', DateTime(2026, 11, 4), DateTime(2026, 11, 5), true),
      (
        'Fiesta de otoño',
        DateTime(2026, 11, 11, 17, 30),
        DateTime(2026, 11, 11, 19),
        false,
      ),
      (
        'Excursión',
        DateTime(2026, 12, 12, 9),
        DateTime(2026, 12, 12, 10),
        false,
      ),
      ('Teatro', DateTime(2027, 1, 15, 18), DateTime(2027, 1, 15, 19), false),
    ]);
  });

  group('photos: what belongs together stands on several lines', () {
    final november = DateTime(2026, 11, 7);
    List<EventSuggestion> read(String text) =>
        extractEvents(text, now: november, language: 'de');
    void expectOne(
      String text,
      String title,
      DateTime start, {
      DateTime? end,
      bool allDay = false,
    }) {
      final found = read(text);
      expect(found, hasLength(1), reason: text);
      expect(found.single.title, title);
      expect(found.single.start, start);
      expect(found.single.allDay, allDay);
      if (end != null) expect(found.single.end, end);
    }

    test('an invitation with one fact per line', () {
      expectOne(
        'Einladung zum Elternabend\n'
            'Datum: Donnerstag, 19.11.2026\n'
            'Uhrzeit: 19:30 Uhr\n'
            'Ort: Aula der Grundschule',
        'Einladung zum Elternabend',
        DateTime(2026, 11, 19, 19, 30),
      );
    });

    test('a time range on the next line, under a label', () {
      expectOne(
        'Kindergeburtstag bei Mia\n'
            'Wann: Samstag, 21. November\n'
            'von 14 bis 17 Uhr\n'
            'Wo: Spielplatz',
        'Kindergeburtstag bei Mia',
        DateTime(2026, 11, 21, 14),
        end: DateTime(2026, 11, 21, 17),
      );
    });

    test('a card from the doctor', () {
      expectOne(
        'Praxis Dr. Muster\nIhr nächster Termin\nDi 24.11.26\n10:15\n'
            'Bitte Karte mitbringen',
        'Ihr nächster Termin',
        DateTime(2026, 11, 24, 10, 15),
      );
    });

    test('the time may stand above the date', () {
      expectOne(
        'Sommerfest\n15:00 Uhr\nSamstag, 12.12.2026',
        'Sommerfest',
        DateTime(2026, 12, 12, 15),
      );
    });

    test('a weekday on its own line is no title', () {
      expectOne(
        'Weihnachtsfeier\nFreitag,\n18. Dezember\n15.30 Uhr',
        'Weihnachtsfeier',
        DateTime(2026, 12, 18, 15, 30),
      );
    });

    test('empty lines are skipped on the way to the title', () {
      expectOne(
        'Schulfest\n\n12.12.2026',
        'Schulfest',
        DateTime(2026, 12, 12),
        allDay: true,
      );
    });

    test('with nothing above, the title may follow the date', () {
      expectOne(
        'Samstag, 12.12.2026\nBasar im Gemeindehaus\n',
        'Basar im Gemeindehaus',
        DateTime(2026, 12, 12),
        allDay: true,
      );
    });

    test('a time belongs to its own date, not the one before', () {
      final found = read(
        'Laternenumzug\n13.11.2026\nAdventsbasar\n28.11.2026\n15 Uhr',
      );
      expect(found.map((e) => e.title), ['Laternenumzug', 'Adventsbasar']);
      expect(found.first.allDay, isTrue);
      expect(found.last.start, DateTime(2026, 11, 28, 15));
    });

    test('a sentence with an hour is no time of the date above', () {
      final found = read(
        'Elternsprechtag am 20.11.2026\n'
        'Bitte melden Sie sich bis 12 Uhr im Sekretariat an.',
      );
      expect(found.single.allDay, isTrue);
    });

    test('recognised text puts spaces into dates', () {
      expectOne(
        'Laternenumzug am 13. 11. 2026 um 17 Uhr',
        'Laternenumzug',
        DateTime(2026, 11, 13, 17),
      );
      expectOne(
        'Laternenumzug\nFreitag, 13.11. 2026\n17:00 Uhr',
        'Laternenumzug',
        DateTime(2026, 11, 13, 17),
      );
      expectOne(
        'Laternenumzug am 13. 11. um 17 Uhr',
        'Laternenumzug',
        DateTime(2026, 11, 13, 17),
      );
    });

    test('numbered things with spaces stay no dates', () {
      expect(read('Für die 1. 2. Klasse gibt es Saft.'), isEmpty);
    });

    test('other languages have their labels too', () {
      final found = extractEvents(
        'Parents evening\nDate: 19 November 2026\nTime: 7:30 pm',
        now: november,
        language: 'en',
      );
      expect(found.single.title, 'Parents evening');
      expect(found.single.start, DateTime(2026, 11, 19, 19, 30));
      final fiesta = extractEvents(
        'Fiesta de otoño\nFecha: 19 de noviembre de 2026\nHora: 18:00 h',
        now: november,
        language: 'es',
      );
      expect(fiesta.single.title, 'Fiesta de otoño');
      expect(fiesta.single.start, DateTime(2026, 11, 19, 18));
    });
  });

  test('ambiguities follow the language of the text', () {
    expect(guessLanguage('Liebe Eltern, am Freitag', fallback: 'en'), 'de');
    expect(guessLanguage('Dear parents, on Friday', fallback: 'de'), 'en');
    expect(
      guessLanguage('Queridas familias, el viernes', fallback: 'de'),
      'es',
    );
    expect(guessLanguage('12:00', fallback: 'es'), 'es');
    // Month first in English, day first otherwise.
    expect(
      found('Party 10/12/2026', language: 'en').single.$2,
      DateTime(2026, 10, 12),
    );
    expect(
      found('Fiesta 10/12/2026', language: 'es').single.$2,
      DateTime(2026, 12, 10),
    );
    expect(
      found('Party 25/12/2026', language: 'en').single.$2,
      DateTime(2026, 12, 25),
    );
    expect(found('Termin 2026-11-03').single.$2, DateTime(2026, 11, 3));
    // German "am": no a.m.; English: it is.
    expect(
      found('Treffen 4.11. um 12 Uhr am Bahnhof', language: 'de').single.$2,
      DateTime(2026, 11, 4, 12),
    );
    expect(
      found('Breakfast November 4 at 9 am', language: 'en').single.$2,
      DateTime(2026, 11, 4, 9),
    );
    expect(
      found('Dinner November 4, 7 PM', language: 'de').single.$2,
      DateTime(2026, 11, 4, 19),
    );
    expect(
      found('Things to do: Fri, 11/6/2026', language: 'en').single.$1,
      'Things to do',
    );
    expect(found('Fr 6.11. Laternenumzug').single.$1, 'Laternenumzug');
    // The examples the import screen shows.
    expect(found("Parents' evening on 10/16 at 7 p.m.").single, (
      "Parents' evening",
      DateTime(2026, 10, 16, 19),
      DateTime(2026, 10, 16, 20),
      false,
    ));
    expect(found('Reunión de padres el 16/10 a las 19:00').single, (
      'Reunión de padres',
      DateTime(2026, 10, 16, 19),
      DateTime(2026, 10, 16, 20),
      false,
    ));
    expect(found('Elternabend am 16.10. um 19 Uhr').single, (
      'Elternabend',
      DateTime(2026, 10, 16, 19),
      DateTime(2026, 10, 16, 20),
      false,
    ));
    // A year after the month is no day.
    expect(found('Im Mai 2027 vielleicht'), isEmpty);
    expect(found('half 1/2 cup'), isEmpty);
  });
}

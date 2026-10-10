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

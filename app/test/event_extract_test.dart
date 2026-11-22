import 'package:famio/src/data/event_extract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('school letters', () {
    final now = DateTime(2026, 11, 18);
    test('one trip and one deadline are different drafts', () {
      final extracted = extractLetter(
        'Klassenfahrt am 27.11.2026 um 8:30 Uhr. '
        'Bitte Einverständnis bis Freitag abgeben.',
        now: now,
      );
      expect(extracted.events.single.start, DateTime(2026, 11, 27, 8, 30));
      expect(extracted.events.single.title, contains('Klassenfahrt'));
      expect(extracted.tasks.single.title, 'Einverständnis abgeben');
      expect(extracted.tasks.single.due, DateTime(2026, 11, 20));
    });

    test('explicit English and Spanish dates are not appointments', () {
      for (final (text, due) in [
        (
          'Please return the consent form by November 20, 2026.',
          DateTime(2026, 11, 20),
        ),
        (
          'Por favor entregar la autorización antes del 21 de noviembre de 2026.',
          DateTime(2026, 11, 21),
        ),
      ]) {
        final extracted = extractLetter(text, now: now);
        expect(extracted.events, isEmpty);
        expect(extracted.tasks.single.due, due);
        expect(extracted.tasks.single.line, text);
      }
    });

    test('ambiguous weekdays stay editable without picking a deadline', () {
      final extracted = extractLetter(
        'Bitte Einverständnis bis\nnächsten Freitag abgeben.\n'
        'Bitte Einverständnis bis nächsten Freitag abgeben.',
        now: now,
      );
      expect(extracted.events, isEmpty);
      expect(extracted.tasks.single.title, 'Einverständnis abgeben');
      expect(extracted.tasks.single.due, isNull);
    });

    test('a comma before a request preserves the appointment and its time', () {
      final extracted = extractLetter(
        'Der Ausflug findet am 27.11.2026 um 8:30 Uhr statt, '
        'bitte geben Sie das Einverständnis bis 20.11.2026 ab.',
        now: now,
      );
      expect(extracted.events.single.start, DateTime(2026, 11, 27, 8, 30));
      expect(extracted.events.single.title, contains('Ausflug'));
      final task = extracted.tasks.single;
      expect(task.due, DateTime(2026, 11, 20));
      expect(task.title, isNot(contains('Ausflug')));
      expect(
        task.line,
        'bitte geben Sie das Einverständnis bis 20.11.2026 ab.',
      );
    });

    test('a request can start at the comma without a polite preface', () {
      final extracted = extractLetter(
        'Ausflug am Freitag, 27.11.2026 um 9 Uhr, '
        'Einverständnis bitte bis 20.11.2026 abgeben.',
        now: now,
      );
      expect(extracted.events.single.start, DateTime(2026, 11, 27, 9));
      expect(extracted.tasks.single.due, DateTime(2026, 11, 20));
      expect(extracted.tasks.single.line, startsWith('Einverständnis'));
    });

    test('a hand-in action on a date creates a task only for that date', () {
      for (final text in [
        'Bitte die Einverständniserklärung am 20.11.2026 abgeben.',
        'Reichen Sie das Formular am 20.11.2026 ein.',
      ]) {
        final extracted = extractLetter(
          'Ausflug am 27.11.2026 um 9 Uhr\n$text',
          now: now,
        );
        expect(extracted.events.single.start, DateTime(2026, 11, 27, 9));
        expect(extracted.tasks.single.due, DateTime(2026, 11, 20));
        expect(extracted.tasks.single.line, text);
      }
    });

    test('alternatives in a deadline leave the date unset', () {
      for (final (text, title) in [
        (
          'Bitte Einverständnis bis Freitag oder Montag abgeben.',
          'Einverständnis abgeben',
        ),
        (
          'Bitte Einverständnis am 20.11. oder 23.11. abgeben.',
          'Einverständnis abgeben',
        ),
        (
          'Please return the consent form by Friday or Monday.',
          'return the consent form',
        ),
        (
          'Bitte Einverständnis bis Freitag oder Montag abgeben oder zurücksenden.',
          'Einverständnis abgeben oder zurücksenden',
        ),
        (
          'Por favor entregar la autorización hasta el viernes o el lunes.',
          'entregar la autorización',
        ),
      ]) {
        final extracted = extractLetter(text, now: now);
        expect(extracted.events, isEmpty, reason: text);
        expect(extracted.tasks.single.title, title, reason: text);
        expect(extracted.tasks.single.due, isNull, reason: text);
      }
    });

    test('a choice of actions does not unset a single due date', () {
      final extracted = extractLetter(
        'Bitte Einverständnis bis Freitag abgeben oder zurücksenden.',
        now: now,
      );
      expect(extracted.tasks.single.due, DateTime(2026, 11, 20));
    });

    test('an appointment with a consent notice remains an appointment', () {
      for (final text in [
        'Elternabend am 27.11.2026 um 19 Uhr (mit Einverständniserklärung).',
        'Beim Elternabend am 27.11.2026 um 19 Uhr können Sie die Einverständniserklärung abgeben.',
      ]) {
        final extracted = extractLetter(text, now: now);
        expect(extracted.tasks, isEmpty, reason: text);
        expect(extracted.events.single.start, DateTime(2026, 11, 27, 19));
      }
    });

    test('ordinary invitations still use the existing appointment parser', () {
      const text = 'Elternabend am 27.11.2026 um 19 Uhr; Basar am 28.11.2026';
      final extracted = extractLetter(text, now: now);
      final ordinary = extractEvents(text, now: now);
      expect(extracted.tasks, isEmpty);
      expect(
        extracted.events.map((e) => (e.title, e.start, e.end, e.line)),
        ordinary.map((e) => (e.title, e.start, e.end, e.line)),
      );
    });

    test('an event time span remains an event', () {
      final extracted = extractLetter(
        'Elternabend am 27.11.2026 von 17 bis 19 Uhr',
        now: now,
      );
      expect(extracted.tasks, isEmpty);
      expect(extracted.events.single.start.hour, 17);
      expect(extracted.events.single.end.hour, 19);
    });

    test('the deadline is the day right after "bis", not a later date', () {
      final extracted = extractLetter(
        'Bitte geben Sie das Formular bis Freitag ab, '
        'damit wir den Ausflug am 27.11.2026 planen können.',
        now: now,
      );
      final task = extracted.tasks.single;
      expect(task.due, DateTime(2026, 11, 20));
      expect(task.title, 'geben Sie das Formular');
      final event = extracted.events.single;
      expect(event.title, 'Ausflug');
      expect(event.start, DateTime(2026, 11, 27));
      expect(event.allDay, isTrue);
    });

    test('an appointment after the deadline stays an appointment', () {
      for (final (text, taskTitle, start, eventTitle) in [
        (
          'Bitte unterschreiben und bis 20.11. zurückgeben: '
              'Theaterbesuch am 4.12.2026 um 10 Uhr',
          'unterschreiben und zurückgeben',
          DateTime(2026, 12, 4, 10),
          'Theaterbesuch',
        ),
        (
          'Bitte bis 20.11. das Geld abgeben und am 27.11.2026 um 8 Uhr '
              'pünktlich zum Ausflug kommen.',
          'das Geld abgeben',
          DateTime(2026, 11, 27, 8),
          'Ausflug',
        ),
        (
          'Bitte bis 20.11. zurückgeben. Der Ausflug ist am 27.11.2026.',
          'zurückgeben',
          DateTime(2026, 11, 27),
          'Ausflug',
        ),
      ]) {
        final extracted = extractLetter(text, now: now);
        final task = extracted.tasks.single;
        expect(task.due, DateTime(2026, 11, 20), reason: text);
        expect(task.title, taskTitle, reason: text);
        final event = extracted.events.single;
        expect(event.start, start, reason: text);
        expect(event.title, contains(eventTitle), reason: text);
      }
    });

    test('transfers with umlauts are actions with a deadline', () {
      for (final (text, title, due) in [
        (
          'Bitte das Geld bis 20.11.2026 überweisen.',
          'das Geld überweisen',
          DateTime(2026, 11, 20),
        ),
        (
          'Bitte überweisen Sie 12 € bis zum 1.12. auf das Konto der '
              'Klassenkasse.',
          'überweisen Sie 12 € auf das Konto der Klassenkasse',
          DateTime(2026, 12, 1),
        ),
      ]) {
        final extracted = extractLetter(text, now: now);
        expect(extracted.events, isEmpty, reason: text);
        expect(extracted.tasks.single.title, title, reason: text);
        expect(extracted.tasks.single.due, due, reason: text);
      }
    });

    test('"bis zum" leaves no preposition in the title', () {
      for (final (text, title) in [
        (
          'Bitte Einverständnis bis zum 20.11. abgeben.',
          'Einverständnis abgeben',
        ),
        (
          'Bitte Einverständnis bis zum 20.11.2026 abgeben.',
          'Einverständnis abgeben',
        ),
        (
          'Bitte geben Sie den Abschnitt bis zum 20. November zurück.',
          'geben Sie den Abschnitt zurück',
        ),
      ]) {
        final task = extractLetter(text, now: now).tasks.single;
        expect(task.title, title, reason: text);
        expect(task.due, DateTime(2026, 11, 20), reason: text);
      }
    });

    test('a time or an amount does not cut the deadline apart', () {
      for (final (text, title) in [
        (
          'Bitte das Formular bis 20.11., 12:00 Uhr abgeben.',
          'das Formular abgeben',
        ),
        // The title reads the amount as the quick entry does.
        ('Bitte bis 20.11. 12,50 € überweisen.', '12 50 € überweisen'),
      ]) {
        final extracted = extractLetter(text, now: now);
        expect(extracted.events, isEmpty, reason: text);
        expect(extracted.tasks.single.title, title, reason: text);
        expect(extracted.tasks.single.due, DateTime(2026, 11, 20));
      }
    });

    test('"by" without a day is no deadline', () {
      final extracted = extractLetter(
        'Pay by card at the Christmas market on 4 December 2026 at 3 pm.',
        now: now,
      );
      expect(extracted.tasks, isEmpty);
      expect(extracted.events.single.start, DateTime(2026, 12, 4, 15));
    });

    test('a weekday deadline is joined to its date', () {
      final task = extractLetter(
        'Bitte geben Sie die Rückmeldung bis spätestens Freitag, '
        'den 20.11.2026 ab.',
        now: now,
      ).tasks.single;
      expect(task.due, DateTime(2026, 11, 20));
      expect(task.title, 'geben Sie die Rückmeldung');
      final english = extractLetter(
        'Please return the consent form by November 20, 2026.',
        now: now,
      ).tasks.single;
      expect(english.title, 'return the consent form');
    });
  });

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
        'Der Elternabend',
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
        'Parent evening',
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
        'Reunión de padres',
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
        'Praxis Dr. Muster',
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

    test('a sentence goes on after the line break', () {
      final found = read(
        'unser diesjähriger Laternenumzug findet am Freitag, den\n'
        '13. November um 17 Uhr statt. Treffpunkt ist der Schulhof.\n'
        'Der Elternabend der Klasse 3b ist am 19.11.\n'
        'um 19:30 Uhr im Raum 12.',
      );
      expect(found.map((e) => e.title), [
        'Unser diesjähriger Laternenumzug',
        'Der Elternabend der Klasse 3b',
      ]);
      expect(found.first.start, DateTime(2026, 11, 13, 17));
      expect(found.last.start, DateTime(2026, 11, 19, 19, 30));
    });

    test('an abbreviation does not end the sentence', () {
      expectOne(
        'Termin bei Dr. Muster am 24.11. um 10:15',
        'Termin bei Dr. Muster',
        DateTime(2026, 11, 24, 10, 15),
      );
    });

    test('the month may come without its dot after a weekday', () {
      expectOne(
        'Termin bei Dr. Muster\nDi 24.11 um 10:15\nTel. 030/1234567',
        'Termin bei Dr. Muster',
        DateTime(2026, 11, 24, 10, 15),
      );
      expectOne(
        'Schwimmen am 24.11 ab 15 Uhr',
        'Schwimmen',
        DateTime(2026, 11, 24, 15),
      );
      // A time stays a time.
      expect(read('Treffen am 10.15 Uhr'), isEmpty);
      expect(read('Beginn um 10.11'), isEmpty);
    });

    test('a flyer: big title, then what stands around the date', () {
      expectOne(
        'Sommerfest\nEinlass ab\nSamstag\n14 Uhr\n12.12.2026\n'
            'Kita Sonnenschein, Hauptstr. 5',
        'Sommerfest',
        DateTime(2026, 12, 12, 14),
      );
    });

    test('a table read row by row', () {
      final found = read(
        'Termine im 1. Halbjahr\n'
        'Datum   Uhrzeit   Veranstaltung\n'
        '12.11.2026   19:00   Elternabend Klasse 3\n'
        '20.11.2026   15:30   Adventsbasar\n'
        '18.12.   Letzter Schultag',
      );
      expect(found.map((e) => e.title), [
        'Elternabend Klasse 3',
        'Adventsbasar',
        'Letzter Schultag',
      ]);
      expect(found[1].start, DateTime(2026, 11, 20, 15, 30));
      expect(found[2].allDay, isTrue);
    });

    test('the place comes along', () {
      final found = read(
        'Einladung zum Elternabend\nDatum: 19.11.2026\nUhrzeit: 19:30 Uhr\n'
        'Ort: Aula der Grundschule',
      );
      expect(found.single.location, 'Aula der Grundschule');
      final above = read('Sommerfest\nWo: Spielplatz\nWann: 12.12.2026');
      expect(above.single.location, 'Spielplatz');
      expect(read('Schulfest am 12.12.2026').single.location, isEmpty);
    });

    test('what stands between two dates belongs to the first', () {
      final found = read(
        'Basar am 12.12.2026\nOrt: Aula\n15 Uhr\nFlohmarkt am 13.12.2026',
      );
      expect(found.first.location, 'Aula');
      expect(found.first.start, DateTime(2026, 12, 12, 15));
      expect(found.last.location, isEmpty);
      expect(found.last.allDay, isTrue);
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

  group('what a title is not', () {
    test('a place: the event below it, the place stays the place', () {
      final e = extractEvents(
        'Im Kulturhaus\n21.11.2026, 19 Uhr\nKonzert des Schulchors',
        now: DateTime(2026, 11, 7),
        language: 'de',
      ).single;
      expect(e.title, 'Konzert des Schulchors');
      expect(e.location, 'Im Kulturhaus');
    });

    test('a place below the date is the place', () {
      final e = extractEvents(
        'Elternabend\nMittwoch, 18.11.2026 um 19 Uhr\n'
        'Turnhalle der Grundschule',
        now: DateTime(2026, 11, 7),
        language: 'de',
      ).single;
      expect(e.title, 'Elternabend');
      expect(e.location, 'Turnhalle der Grundschule');
    });

    test('nothing but a place: an appointment there', () {
      for (final text in [
        'Stadthalle\n14.11.2026, 19 Uhr',
        'Stadthalle, 14.11.2026, 19 Uhr',
      ]) {
        final e = extractEvents(
          text,
          now: DateTime(2026, 11, 7),
          language: 'de',
        ).single;
        expect(e.title, 'Termin', reason: text);
        expect(e.location, 'Stadthalle', reason: text);
      }
    });

    test('compounds are what they end in', () {
      final e = extractEvents(
        'Kindergartenfest\n14.11.2026\nFesthalle am Markt',
        now: DateTime(2026, 11, 7),
        language: 'de',
      ).single;
      expect(e.title, 'Kindergartenfest');
      expect(e.location, 'Festhalle am Markt');
    });

    test('an event in a place keeps its whole title', () {
      final e = extractEvents(
        'Wichtige Information\nSommerfest im Gemeindehaus\n14.11.2026',
        now: DateTime(2026, 11, 7),
        language: 'de',
      ).single;
      expect(e.title, 'Sommerfest im Gemeindehaus');
    });

    test('a reminder card: the practice, not "your next appointment"', () {
      final e = extractEvents(
        'Zahnarztpraxis Dr. Meier\nHauptstraße 5\n12345 Musterstadt\n'
        'Tel. 01234 56789\nIhr nächster Termin:\nDi. 17.11.2026\n14:30 Uhr',
        now: DateTime(2026, 11, 7),
        language: 'de',
      ).single;
      expect(e.title, 'Zahnarztpraxis Dr. Meier');
      expect(e.location, 'Hauptstraße 5, 12345 Musterstadt');
      expect((e.start.hour, e.start.minute), (14, 30));
    });

    test('small words stay inside names', () {
      final e = extractEvents(
        'Grundschule am Park\nFest am See\n14.11.2026 um 15 Uhr',
        now: DateTime(2026, 11, 7),
        language: 'de',
      ).single;
      expect(e.title, 'Fest am See');
      expect(e.location, 'Grundschule am Park');
    });

    test('a sentence after the date does not become the title', () {
      final e = extractEvents(
        'Theaterstück\n13.11.2026\nWir freuen uns auf ein schönes Fest!',
        now: DateTime(2026, 11, 7),
        language: 'de',
      ).single;
      expect(e.title, 'Theaterstück');
    });

    final november = DateTime(2026, 11, 7);
    void expectParts(String text, String title, String location) {
      final found = extractEvents(text, now: november, language: 'de');
      expect(found, hasLength(1), reason: text);
      expect(found.single.title, title, reason: text);
      expect(found.single.location, location, reason: text);
    }

    test('a form in two columns', () {
      expectParts(
        'Veranstaltung   Sommerfest\nOrt   Aula der Grundschule\n'
            'Datum   12.12.2026\nUhrzeit   15:00',
        'Sommerfest',
        'Aula der Grundschule',
      );
    });

    test('labels whose colon the recognition lost', () {
      expectParts(
        'Sommerfest\nOrt Aula\nDatum 12.12.2026\nUhrzeit 15:00',
        'Sommerfest',
        'Aula',
      );
      expectParts(
        'Sommerfest\nOrt. Aula\nDatum. 12.12.2026\nUhrzeit. 15:00',
        'Sommerfest',
        'Aula',
      );
    });

    test('a place between the title and the date', () {
      expectParts(
        'Kindergeburtstag\nTrampolinhalle Jump\nSamstag, 21.11.2026\n15 Uhr',
        'Kindergeburtstag',
        'Trampolinhalle Jump',
      );
      expectParts(
        'Ballett\nTanzschule Meier\nDi 24.11.2026 um 16 Uhr',
        'Ballett',
        'Tanzschule Meier',
      );
    });

    test('an address', () {
      expectParts(
        'Einladung zum Geburtstag\nHauptstraße 12\n12345 Musterstadt\n'
            'Samstag, 21.11.2026 um 15 Uhr',
        'Einladung zum Geburtstag',
        'Hauptstraße 12, 12345 Musterstadt',
      );
    });

    test('a phone number', () {
      expectParts(
        'Praxis Dr. Muster\nHauptstr. 5\n12345 Stadt\nTel. 030 1234567\n'
            'Di 24.11.2026 10:15 Uhr',
        'Praxis Dr. Muster',
        'Hauptstr. 5, 12345 Stadt',
      );
    });

    test('the place in the sentence of the date', () {
      expectParts(
        'Laternenfest\nAuf dem Schulhof am 13.11.2026 um 17 Uhr',
        'Laternenfest',
        'Auf dem Schulhof',
      );
      expectParts(
        'Im Kindergarten am 13.11.2026 um 17 Uhr',
        'Termin',
        'Im Kindergarten',
      );
    });

    test('a greeting', () {
      expectParts('Liebe Eltern,\nBasar\n12.12.2026', 'Basar', '');
      expectParts('Liebe Eltern,\n\n12.12.2026', 'Termin', '');
    });

    test('what is said outright wins, wherever it stands', () {
      expectParts(
        'Was: Sommerfest\nWann: 12.12.2026, 15 Uhr\nWo: Aula',
        'Sommerfest',
        'Aula',
      );
      expectParts(
        'Wo: Aula\nWann: 12.12.2026 15 Uhr\nWas: Sommerfest',
        'Sommerfest',
        'Aula',
      );
      expectParts(
        'Datum: 12.12.2026\nUhrzeit: 15 Uhr\nOrt: Aula\nThema: Elternabend',
        'Elternabend',
        'Aula',
      );
      expectParts('Was Sommerfest\nWann 12.12.2026', 'Sommerfest', '');
    });

    test('titles that start like a label stay titles', () {
      expectParts(
        'Tag der offenen Tür am 12.12.2026',
        'Tag der offenen Tür',
        '',
      );
      expectParts(
        'Termin bei Dr. Muster\n12.12.2026',
        'Termin bei Dr. Muster',
        '',
      );
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

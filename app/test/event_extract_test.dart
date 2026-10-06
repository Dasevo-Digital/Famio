import 'package:famio/src/data/event_extract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 6);

  List<(String, DateTime, DateTime, bool)> found(String text) => [
    for (final e in extractEvents(text, now: now))
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
        'findet der Elternabend statt.',
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
}

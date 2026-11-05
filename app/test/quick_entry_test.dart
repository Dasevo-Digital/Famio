import 'package:famio/src/data/event_extract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A Monday.
  final today = DateTime(2026, 11, 2);

  /// "title | days | time", e.g. "Kinderarzt | 5.11. | 16:00".
  String read(String text, {String? language, DateTime? on}) {
    final e = parseQuickEntry(text, today: on ?? today, language: language);
    String two(int n) => n.toString().padLeft(2, '0');
    final days = e.days.map((d) => '${d.day}.${d.month}.').join(' or ');
    final time = switch (e.time) {
      null => '-',
      (final h, final m, null, _) => '$h:${two(m)}',
      (final h, final m, final eh?, final em) =>
        '$h:${two(m)}-$eh:${two(em ?? 0)}',
    };
    return '${e.title} | ${days.isEmpty ? '-' : days} | $time';
  }

  test('a weekday with a time', () {
    expect(read('Donnerstag 16 Uhr Kinderarzt'), 'Kinderarzt | 5.11. | 16:00');
    expect(
      read('Kinderarzt am Donnerstag um 16:30'),
      'Kinderarzt | 5.11. | 16:30',
    );
    expect(read('Do 16 Uhr Kinderarzt'), 'Kinderarzt | 5.11. | 16:00');
    expect(
      read('Donnerstag 16-17 Uhr Kinderarzt'),
      'Kinderarzt | 5.11. | 16:00-17:00',
    );
    // A bare "um 16" counts as well.
    expect(read('Freitag um 9 Friseur'), 'Friseur | 6.11. | 9:00');
  });

  test('"nächsten Donnerstag" can mean two days: both are offered', () {
    expect(
      read('nächsten Donnerstag Elternabend'),
      'Elternabend | 5.11. or 12.11. | -',
    );
    expect(
      parseQuickEntry(
        'nächsten Donnerstag Elternabend',
        today: today,
      ).ambiguous,
      isTrue,
    );
    // "kommenden" is the next one.
    expect(read('kommenden Donnerstag Elternabend'), 'Elternabend | 5.11. | -');
    // Today's weekday: today or in a week.
    expect(read('Montag Turnen'), 'Turnen | 2.11. or 9.11. | -');
    expect(read('nächsten Montag Turnen'), 'Turnen | 9.11. | -');
  });

  test('today, tomorrow, the day after, in a few days', () {
    expect(read('morgen Müll rausbringen'), 'Müll rausbringen | 3.11. | -');
    expect(read('übermorgen um 9 Friseur'), 'Friseur | 4.11. | 9:00');
    // "heute Morgen" is this morning.
    expect(read('heute Morgen Bäcker'), 'Bäcker | 2.11. | -');
    expect(read('in 3 Tagen Paket abholen'), 'Paket abholen | 5.11. | -');
    expect(read('in zwei Wochen Zahnarzt'), 'Zahnarzt | 16.11. | -');
    expect(read('in einer Woche Zahnarzt'), 'Zahnarzt | 9.11. | -');
    // Across the end of a month.
    expect(
      read('morgen Zahnarzt', on: DateTime(2026, 11, 30)),
      'Zahnarzt | 1.12. | -',
    );
  });

  test('dates as in letters', () {
    expect(
      read('12.11. 14:30 Elterngespräch'),
      'Elterngespräch | 12.11. | 14:30',
    );
    final range = parseQuickEntry('Herbstferien 12.–16.11.', today: today);
    expect(range.days, [DateTime(2026, 11, 12)]);
    expect(range.lastDay, DateTime(2026, 11, 16));
    expect(range.title, 'Herbstferien');
  });

  test('English and Spanish', () {
    expect(
      read('next Friday 3 pm dentist', language: 'en'),
      'dentist | 6.11. or 13.11. | 15:00',
    );
    expect(
      read('tomorrow soccer practice', language: 'en'),
      'soccer practice | 3.11. | -',
    );
    expect(
      read('Thursday 4 pm dentist', language: 'en'),
      'dentist | 5.11. | 16:00',
    );
    expect(
      read('mañana a las 9 pediatra', language: 'es'),
      'pediatra | 3.11. | 9:00',
    );
    expect(
      read('jueves a las 16 pediatra', language: 'es'),
      'pediatra | 5.11. | 16:00',
    );
    expect(
      read('en 2 días recoger paquete', language: 'es'),
      'recoger paquete | 4.11. | -',
    );
    // "de la mañana" is the morning, not tomorrow.
    expect(
      read('a las 9 de la mañana desayuno', language: 'es'),
      'desayuno | - | 9:00',
    );
  });

  test('without a day: only a title and maybe a time', () {
    expect(read('Oma anrufen'), 'Oma anrufen | - | -');
    expect(read('16 Uhr Kinderarzt'), 'Kinderarzt | - | 16:00');
    // "So" and "Sa" inside a title stay words.
    expect(read('Ich mache das So'), 'Ich mache das So | - | -');
    expect(read(''), ' | - | -');
  });
}

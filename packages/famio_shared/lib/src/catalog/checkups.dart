import '../texts.dart';

/// An age as the Kinder-Richtlinie counts it, in days, weeks or months after
/// birth. The day of birth is the first day of life (§ 187 Abs. 2 BGB); a
/// week or month of life ends the day before the matching day, at the end
/// of a shorter month on its last day (§ 188 BGB).
class LifeAge {
  const LifeAge.days(this.amount) : _unit = _LifeUnit.day, extraDays = 0;
  const LifeAge.weeks(this.amount) : _unit = _LifeUnit.week, extraDays = 0;
  const LifeAge.months(this.amount, {this.extraDays = 0})
    : _unit = _LifeUnit.month;

  final int amount;
  final _LifeUnit _unit;

  /// Added after the months (half a month: 15 days).
  final int extraDays;

  /// The day a child born on [birth] reaches this age.
  DateTime after(DateTime birth) {
    final b = DateTime(birth.year, birth.month, birth.day);
    switch (_unit) {
      case _LifeUnit.day:
        return DateTime(b.year, b.month, b.day + amount);
      case _LifeUnit.week:
        return DateTime(b.year, b.month, b.day + 7 * amount);
      case _LifeUnit.month:
        final month = DateTime(b.year, b.month + amount);
        final length = DateTime(month.year, month.month + 1, 0).day;
        // Born on the 31st: a month of life ending in a shorter month ends
        // on its last day, the next one starts on the 1st.
        final reached = b.day <= length
            ? DateTime(month.year, month.month, b.day)
            : DateTime(month.year, month.month + 1);
        return DateTime(reached.year, reached.month, reached.day + extraDays);
    }
  }

  /// The last day before this age: where a window "until" it ends.
  DateTime lastDayBefore(DateTime birth) {
    final reached = after(birth);
    return DateTime(reached.year, reached.month, reached.day - 1);
  }
}

enum _LifeUnit { day, week, month }

/// Preventive check-ups from the German "gelbes Kinderuntersuchungsheft"
/// (G-BA Kinder-Richtlinie § 2). Each runs from [from] to the day before
/// [until]; the booklet also accepts it until the day before
/// [toleranceUntil].
class Checkup {
  const Checkup(
    this.id,
    this._title,
    this._window,
    this.from,
    this.until,
    this.toleranceUntil, {
    this.optional = false,
  });

  final String id;
  final String _title;
  String get title => sharedText('Checkup|$_title', _title);

  /// Human-readable window as printed in the booklet.
  final String _window;
  String get window => sharedText('Checkup|$_window', _window);

  /// The window: "4.–5. Lebenswoche" runs from 3 weeks of age until the day
  /// before 5 weeks.
  final LifeAge from;
  final LifeAge until;

  /// The end of the tolerance period, exclusive like [until].
  final LifeAge toleranceUntil;

  /// Not covered by every health insurance (U10, U11, J2).
  final bool optional;
}

const checkups = <Checkup>[
  Checkup(
    'U1',
    'U1 – Neugeborenen-Erstuntersuchung',
    'direkt nach der Geburt',
    LifeAge.days(0),
    LifeAge.days(1),
    LifeAge.days(1),
  ),
  Checkup(
    'U2',
    'U2 – Neugeborenen-Basisuntersuchung',
    '3.–10. Lebenstag',
    LifeAge.days(2),
    LifeAge.days(10),
    LifeAge.days(14),
  ),
  Checkup(
    'U3',
    'U3',
    '4.–5. Lebenswoche',
    LifeAge.weeks(3),
    LifeAge.weeks(5),
    LifeAge.weeks(8),
  ),
  // Tolerance "bis 4½. Lebensmonat": read as until 4 months and 15 days.
  Checkup(
    'U4',
    'U4',
    '3.–4. Lebensmonat',
    LifeAge.months(2),
    LifeAge.months(4),
    LifeAge.months(4, extraDays: 15),
  ),
  Checkup(
    'U5',
    'U5',
    '6.–7. Lebensmonat',
    LifeAge.months(5),
    LifeAge.months(7),
    LifeAge.months(8),
  ),
  Checkup(
    'U6',
    'U6',
    '10.–12. Lebensmonat',
    LifeAge.months(9),
    LifeAge.months(12),
    LifeAge.months(14),
  ),
  Checkup(
    'U7',
    'U7',
    '21.–24. Lebensmonat',
    LifeAge.months(20),
    LifeAge.months(24),
    LifeAge.months(27),
  ),
  Checkup(
    'U7a',
    'U7a',
    '34.–36. Lebensmonat',
    LifeAge.months(33),
    LifeAge.months(36),
    LifeAge.months(38),
  ),
  Checkup(
    'U8',
    'U8',
    '46.–48. Lebensmonat',
    LifeAge.months(45),
    LifeAge.months(48),
    LifeAge.months(50),
  ),
  Checkup(
    'U9',
    'U9 – vor der Einschulung',
    '60.–64. Lebensmonat',
    LifeAge.months(59),
    LifeAge.months(64),
    LifeAge.months(66),
  ),
  Checkup(
    'U10',
    'U10',
    '7–8 Jahre',
    LifeAge.months(84),
    LifeAge.months(96),
    LifeAge.months(96),
    optional: true,
  ),
  Checkup(
    'U11',
    'U11',
    '9–10 Jahre',
    LifeAge.months(108),
    LifeAge.months(120),
    LifeAge.months(120),
    optional: true,
  ),
  Checkup(
    'J1',
    'J1 – Jugenduntersuchung',
    '12–14 Jahre',
    LifeAge.months(144),
    LifeAge.months(168),
    LifeAge.months(180),
  ),
  Checkup(
    'J2',
    'J2',
    '16–17 Jahre',
    LifeAge.months(192),
    LifeAge.months(204),
    LifeAge.months(204),
    optional: true,
  ),
];

Checkup? checkupById(String? id) =>
    checkups.where((c) => c.id == id).firstOrNull;

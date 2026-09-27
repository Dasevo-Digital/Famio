/// Preventive check-ups from the German "gelbes Kinderuntersuchungsheft"
/// (G-BA Kinder-Richtlinie). Windows are given in days after birth; the
/// booklet also allows tolerance periods ([toleranceTo]).
class Checkup {
  const Checkup(
    this.id,
    this.title,
    this.window,
    this.fromDay,
    this.toDay,
    this.toleranceTo, {
    this.optional = false,
  });

  final String id;
  final String title;

  /// Human-readable window as printed in the booklet.
  final String window;
  final int fromDay;
  final int toDay;

  /// Last day still accepted (tolerance period).
  final int toleranceTo;

  /// Not covered by every health insurance (U10, U11, J2).
  final bool optional;
}

const _week = 7;
const _month = 30.4375;

int _m(num months) => (months * _month).round();

final checkups = <Checkup>[
  const Checkup(
    'U1',
    'U1 – Neugeborenen-Erstuntersuchung',
    'direkt nach der Geburt',
    0,
    0,
    0,
  ),
  const Checkup(
    'U2',
    'U2 – Neugeborenen-Basisuntersuchung',
    '3.–10. Lebenstag',
    2,
    9,
    13,
  ),
  const Checkup(
    'U3',
    'U3',
    '4.–5. Lebenswoche',
    3 * _week,
    5 * _week,
    8 * _week,
  ),
  Checkup('U4', 'U4', '3.–4. Lebensmonat', _m(2), _m(4), _m(4.5)),
  Checkup('U5', 'U5', '6.–7. Lebensmonat', _m(5), _m(7), _m(8)),
  Checkup('U6', 'U6', '10.–12. Lebensmonat', _m(9), _m(12), _m(14)),
  Checkup('U7', 'U7', '21.–24. Lebensmonat', _m(20), _m(24), _m(27)),
  Checkup('U7a', 'U7a', '34.–36. Lebensmonat', _m(33), _m(36), _m(38)),
  Checkup('U8', 'U8', '46.–48. Lebensmonat', _m(45), _m(48), _m(50)),
  Checkup(
    'U9',
    'U9 – vor der Einschulung',
    '60.–64. Lebensmonat',
    _m(59),
    _m(64),
    _m(66),
  ),
  Checkup('U10', 'U10', '7–8 Jahre', _m(84), _m(96), _m(96), optional: true),
  Checkup(
    'U11',
    'U11',
    '9–10 Jahre',
    _m(108),
    _m(120),
    _m(120),
    optional: true,
  ),
  Checkup(
    'J1',
    'J1 – Jugenduntersuchung',
    '12–14 Jahre',
    _m(144),
    _m(168),
    _m(180),
  ),
  Checkup('J2', 'J2', '16–17 Jahre', _m(192), _m(204), _m(204), optional: true),
];

Checkup? checkupById(String? id) =>
    checkups.where((c) => c.id == id).firstOrNull;

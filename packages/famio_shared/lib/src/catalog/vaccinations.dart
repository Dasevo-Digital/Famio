import '../texts.dart';

/// Standard childhood vaccinations after the STIKO schedule (Germany, as of
/// 2026), simplified to the recommended age of each dose. Orientation only:
/// the paediatrician and the vaccination record decide.
/// Sources: STIKO, Epidemiologisches Bulletin 4/2026
/// (https://www.rki.de/DE/Aktuelles/Publikationen/Epidemiologisches-Bulletin/2026/04_26.html),
/// https://www.rki.de/meningokokken-impfung-faq
class Vaccination {
  const Vaccination(
    this.id,
    this._title,
    this._dose,
    this.ageMonths, [
    this._note = '',
  ]);

  final String id;

  /// Disease(s) covered.
  final String _title;
  String get title => sharedText('Vaccination|$_title', _title);
  final String _dose;
  String get dose => sharedText('Vaccination|$_dose', _dose);

  /// Recommended age in months.
  final double ageMonths;
  final String _note;
  String get note => sharedText('Vaccination|$_note', _note);
}

const vaccinations = <Vaccination>[
  Vaccination(
    'rsv',
    'RSV (Antikörper-Prophylaxe)',
    'einmalig',
    0,
    'Geboren Oktober–März: bald nach der Geburt (U2). Geboren April–September: im Herbst vor der ersten RSV-Saison. Geboren Januar–März und noch ohne: im Herbst nachholen, bis zum 1. Geburtstag.',
  ),
  Vaccination(
    'rota_1',
    'Rotaviren',
    '1. Dosis',
    1.5,
    'Schluckimpfung ab 6 Wochen, Beginn spätestens mit 12 Wochen.',
  ),
  Vaccination('rota_2', 'Rotaviren', '2. Dosis', 2),
  Vaccination(
    'rota_3',
    'Rotaviren',
    '3. Dosis',
    3,
    'Je nach Impfstoff nötig; die Serie endet spätestens mit 24 bzw. 32 Wochen.',
  ),
  Vaccination(
    'six_1',
    'Sechsfach (Tetanus, Diphtherie, Keuchhusten, Hib, Polio, Hepatitis B)',
    '1. Dosis',
    2,
  ),
  Vaccination(
    'six_2',
    'Sechsfach (Tetanus, Diphtherie, Keuchhusten, Hib, Polio, Hepatitis B)',
    '2. Dosis',
    4,
  ),
  Vaccination(
    'six_3',
    'Sechsfach (Tetanus, Diphtherie, Keuchhusten, Hib, Polio, Hepatitis B)',
    '3. Dosis',
    11,
  ),
  Vaccination('pneumo_1', 'Pneumokokken', '1. Dosis', 2),
  Vaccination('pneumo_2', 'Pneumokokken', '2. Dosis', 4),
  Vaccination('pneumo_3', 'Pneumokokken', '3. Dosis', 11),
  Vaccination('menb_1', 'Meningokokken B', '1. Dosis', 2),
  Vaccination('menb_2', 'Meningokokken B', '2. Dosis', 4),
  Vaccination('menb_3', 'Meningokokken B', '3. Dosis', 12),
  Vaccination('mmrv_1', 'Masern, Mumps, Röteln, Windpocken', '1. Dosis', 11),
  Vaccination('menacwy', 'Meningokokken A, C, W, Y', 'einmalig', 144),
  Vaccination(
    'mmrv_2',
    'Masern, Mumps, Röteln, Windpocken',
    '2. Dosis',
    15,
    'Für Kita und Schule ist der Masernschutz Pflicht.',
  ),
  Vaccination(
    'tdap_1',
    'Tetanus, Diphtherie, Keuchhusten',
    'Auffrischung',
    60,
    'Mit 5–6 Jahren.',
  ),
  Vaccination(
    'hpv_1',
    'HPV (Humane Papillomviren)',
    '1. Dosis',
    108,
    'Mit 9–14 Jahren, für alle Kinder.',
  ),
  Vaccination(
    'hpv_2',
    'HPV (Humane Papillomviren)',
    '2. Dosis',
    114,
    'Mindestens 5 Monate nach der 1. Dosis.',
  ),
  Vaccination(
    'tdap_ipv',
    'Tetanus, Diphtherie, Keuchhusten, Polio',
    'Auffrischung',
    108,
    'Mit 9–16 Jahren.',
  ),
];

/// What the STIKO schedule adds to the recommended age of a dose.
class VaccinationRule {
  const VaccinationRule({
    this.fromDays,
    this.after,
    this.gapMonths = 0,
    this.gapDays = 0,
    this.untilDays,
  });

  /// The earliest age in days, where months are too coarse (6 weeks).
  final int? fromDays;

  /// The dose before; once it is recorded, this one comes at least
  /// [gapMonths] and [gapDays] later.
  final String? after;
  final int gapMonths;
  final int gapDays;

  /// The last age in days at which the dose is still given (Rotavirus).
  final int? untilDays;
}

/// Minimum intervals and age limits (STIKO-Impfkalender 2026).
const vaccinationRules = <String, VaccinationRule>{
  'rota_1': VaccinationRule(fromDays: 6 * 7, untilDays: 12 * 7),
  'rota_2': VaccinationRule(after: 'rota_1', gapDays: 28, untilDays: 32 * 7),
  'rota_3': VaccinationRule(after: 'rota_2', gapDays: 28, untilDays: 32 * 7),
  'six_2': VaccinationRule(after: 'six_1', gapMonths: 2),
  'six_3': VaccinationRule(after: 'six_2', gapMonths: 6),
  'pneumo_2': VaccinationRule(after: 'pneumo_1', gapMonths: 2),
  'pneumo_3': VaccinationRule(after: 'pneumo_2', gapMonths: 6),
  'menb_2': VaccinationRule(after: 'menb_1', gapMonths: 2),
  'menb_3': VaccinationRule(after: 'menb_2', gapMonths: 6),
  'mmrv_2': VaccinationRule(after: 'mmrv_1', gapDays: 28),
  'hpv_2': VaccinationRule(after: 'hpv_1', gapMonths: 5),
};

/// Labels for previously documented doses, outside today's recommendations.
const historicVaccinations = [
  Vaccination('menc', 'Meningokokken C', 'einmalig', 12),
];

Vaccination? vaccinationById(String? id) => vaccinations
    .followedBy(historicVaccinations)
    .where((v) => v.id == id)
    .firstOrNull;

/// Standard childhood vaccinations after the STIKO schedule (Germany, as of
/// 2025), simplified to the recommended age of each dose. Orientation only:
/// the paediatrician and the vaccination record decide.
class Vaccination {
  const Vaccination(
    this.id,
    this.title,
    this.dose,
    this.ageMonths, [
    this.note = '',
  ]);

  final String id;

  /// Disease(s) covered.
  final String title;
  final String dose;

  /// Recommended age in months.
  final double ageMonths;
  final String note;
}

const vaccinations = <Vaccination>[
  Vaccination(
    'rsv',
    'RSV (Antikörper-Prophylaxe)',
    'einmalig',
    0,
    'Vor bzw. in der ersten RSV-Saison (meist Oktober–März).',
  ),
  Vaccination(
    'rota_1',
    'Rotaviren',
    '1. Dosis',
    1.5,
    'Schluckimpfung ab 6 Wochen.',
  ),
  Vaccination('rota_2', 'Rotaviren', '2. Dosis', 2),
  Vaccination('rota_3', 'Rotaviren', '3. Dosis', 3, 'Je nach Impfstoff nötig.'),
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
  Vaccination('menc', 'Meningokokken C', 'einmalig', 12),
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

Vaccination? vaccinationById(String? id) =>
    vaccinations.where((v) => v.id == id).firstOrNull;

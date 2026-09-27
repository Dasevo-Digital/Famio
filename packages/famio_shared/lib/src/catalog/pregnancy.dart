/// Pregnancy week by week: typical size of the baby (rounded, from common
/// tables; crown-rump length until week 19, then head to heel) and a
/// comparison for the family.
class PregnancyWeek {
  const PregnancyWeek(
    this.week,
    this.like,
    this.lengthCm,
    this.weightG,
    this.info,
  );

  /// Completed weeks (SSW n+0).
  final int week;
  final String like;
  final double lengthCm;
  final int weightG;
  final String info;
}

const pregnancyWeeks = <PregnancyWeek>[
  PregnancyWeek(4, 'ein Mohnsamen', 0.1, 0, 'Die Einnistung ist geschafft.'),
  PregnancyWeek(5, 'ein Sesamkorn', 0.2, 0, 'Das Herz beginnt sich zu bilden.'),
  PregnancyWeek(
    6,
    'eine Linse',
    0.5,
    0,
    'Im Ultraschall ist oft schon der Herzschlag zu sehen.',
  ),
  PregnancyWeek(7, 'eine Blaubeere', 1, 1, 'Ärmchen und Beinchen knospen.'),
  PregnancyWeek(8, 'eine Himbeere', 1.6, 1, 'Finger und Zehen entstehen.'),
  PregnancyWeek(9, 'eine Kirsche', 2.3, 2, 'Alle Organe sind angelegt.'),
  PregnancyWeek(10, 'eine Erdbeere', 3.1, 4, 'Aus dem Embryo wird ein Fötus.'),
  PregnancyWeek(
    11,
    'eine Feige',
    4.1,
    7,
    'Das Baby bewegt sich schon – spüren kann man es noch nicht.',
  ),
  PregnancyWeek(
    12,
    'eine Limette',
    5.4,
    14,
    'Das erste Drittel ist bald geschafft.',
  ),
  PregnancyWeek(13, 'eine Zitrone', 7.4, 23, 'Das zweite Trimester beginnt.'),
  PregnancyWeek(
    14,
    'ein Pfirsich',
    8.7,
    43,
    'Das Baby kann schon Grimassen schneiden.',
  ),
  PregnancyWeek(15, 'ein Apfel', 10.1, 70, 'Die Haut ist noch ganz dünn.'),
  PregnancyWeek(
    16,
    'eine Avocado',
    11.6,
    100,
    'Manche spüren jetzt erste Bewegungen.',
  ),
  PregnancyWeek(
    17,
    'eine Birne',
    13,
    140,
    'Fettpolster beginnen sich zu bilden.',
  ),
  PregnancyWeek(
    18,
    'eine Paprika',
    14.2,
    190,
    'Das Baby hört erste Geräusche.',
  ),
  PregnancyWeek(19, 'eine Mango', 15.3, 240, 'Bergfest naht!'),
  PregnancyWeek(
    20,
    'eine Banane',
    25.6,
    300,
    'Halbzeit – ab jetzt wird von Kopf bis Fuß gemessen.',
  ),
  PregnancyWeek(21, 'eine Karotte', 26.7, 360, 'Tritte werden kräftiger.'),
  PregnancyWeek(22, 'eine Papaya', 27.8, 430, 'Das Baby erkennt Stimmen.'),
  PregnancyWeek(23, 'eine Grapefruit', 28.9, 500, 'Die Lunge reift.'),
  PregnancyWeek(
    24,
    'ein Maiskolben',
    30,
    600,
    'Ab jetzt hat ein Frühchen gute Chancen.',
  ),
  PregnancyWeek(
    25,
    'ein Blumenkohl',
    34.6,
    660,
    'Das Baby hat einen Schlaf-Wach-Rhythmus.',
  ),
  PregnancyWeek(26, 'ein Salatkopf', 35.6, 760, 'Die Augen öffnen sich.'),
  PregnancyWeek(27, 'ein Brokkoli', 36.6, 875, 'Das zweite Trimester endet.'),
  PregnancyWeek(
    28,
    'eine Aubergine',
    37.6,
    1000,
    'Das letzte Drittel beginnt.',
  ),
  PregnancyWeek(
    29,
    'ein Butternusskürbis',
    38.6,
    1150,
    'Muskeln und Lunge reifen weiter.',
  ),
  PregnancyWeek(30, 'ein Kohlkopf', 39.9, 1300, 'Das Gehirn wächst schnell.'),
  PregnancyWeek(31, 'eine Kokosnuss', 41.1, 1500, 'Es wird eng im Bauch.'),
  PregnancyWeek(
    32,
    'ein Hokkaido-Kürbis',
    42.4,
    1700,
    'Die meisten Babys drehen sich jetzt mit dem Kopf nach unten.',
  ),
  PregnancyWeek(
    33,
    'eine Ananas',
    43.7,
    1900,
    'Die Knochen härten aus – bis auf den Schädel.',
  ),
  PregnancyWeek(
    34,
    'eine Honigmelone',
    45,
    2100,
    'Zeit, die Kliniktasche zu packen.',
  ),
  PregnancyWeek(
    35,
    'eine Galiamelone',
    46.2,
    2400,
    'Das Baby legt vor allem an Gewicht zu.',
  ),
  PregnancyWeek(
    36,
    'ein Römersalat',
    47.4,
    2600,
    'Ab jetzt heißt es: bereit sein.',
  ),
  PregnancyWeek(
    37,
    'ein Mangold',
    48.6,
    2900,
    'Ab 37+0 gilt das Baby als reif geboren.',
  ),
  PregnancyWeek(
    38,
    'eine Lauchstange',
    49.8,
    3100,
    'Jeden Tag kann es losgehen.',
  ),
  PregnancyWeek(
    39,
    'eine kleine Wassermelone',
    50.7,
    3300,
    'Die Käseschmiere wird weniger.',
  ),
  PregnancyWeek(
    40,
    'ein Kürbis',
    51.2,
    3500,
    'Der errechnete Termin ist da – nur wenige Babys kommen genau heute.',
  ),
];

PregnancyWeek? pregnancyWeek(int week) =>
    week < 4 ? null : pregnancyWeeks[(week.clamp(4, 40)) - 4];

/// Appointments and to-dos during a pregnancy (Mutterschafts-Richtlinien,
/// STIKO); windows in completed weeks.
class PregnancyTask {
  const PregnancyTask(
    this.id,
    this.title,
    this.fromWeek,
    this.toWeek,
    this.info,
  );

  final String id;
  final String title;
  final int fromWeek;
  final int toWeek;
  final String info;
}

const pregnancyTasks = <PregnancyTask>[
  PregnancyTask(
    'midwife',
    'Hebamme suchen',
    5,
    12,
    'Hebammen sind oft früh ausgebucht – für Vorsorge und Wochenbett am besten gleich nach dem positiven Test anfragen.',
  ),
  PregnancyTask(
    'us1',
    '1. Ultraschall-Screening',
    9,
    12,
    'Mutterpass: 9+0 bis 12+6.',
  ),
  PregnancyTask(
    'course',
    'Geburtsvorbereitungskurs anmelden',
    18,
    24,
    'Der Kurs selbst liegt meist zwischen SSW 25 und 35.',
  ),
  PregnancyTask(
    'us2',
    '2. Ultraschall-Screening',
    19,
    22,
    'Mutterpass: 19+0 bis 22+6.',
  ),
  PregnancyTask(
    'ogtt',
    'Zuckertest (Glukose)',
    24,
    27,
    'Test auf Schwangerschaftsdiabetes: 24+0 bis 27+6.',
  ),
  PregnancyTask(
    'pertussis',
    'Keuchhusten-Impfung',
    28,
    32,
    'STIKO: zu Beginn des letzten Drittels – schützt das Baby in den ersten Monaten.',
  ),
  PregnancyTask(
    'us3',
    '3. Ultraschall-Screening',
    29,
    32,
    'Mutterpass: 29+0 bis 32+6.',
  ),
  PregnancyTask(
    'clinic',
    'In der Geburtsklinik anmelden',
    30,
    35,
    'Oft mit Vorgespräch und Kreißsaalführung.',
  ),
  PregnancyTask(
    'pediatrician',
    'Kinderarzt suchen',
    30,
    36,
    'Für die U2 und die weiteren Vorsorgen.',
  ),
  PregnancyTask('bag', 'Kliniktasche packen', 34, 36, 'Siehe Checkliste.'),
  PregnancyTask(
    'maternity',
    'Mutterschaftsgeld beantragen',
    33,
    34,
    'Bei der Krankenkasse, mit Bescheinigung über den Termin (frühestens 7 Wochen vor ET). Mutterschutz beginnt 6 Wochen vor ET.',
  ),
];

class ChecklistItem {
  const ChecklistItem(this.id, this.title);

  final String id;
  final String title;
}

class Checklist {
  const Checklist(this.id, this.title, this.items);

  final String id;
  final String title;
  final List<ChecklistItem> items;
}

const pregnancyChecklists = <Checklist>[
  Checklist('bag', 'Kliniktasche', [
    ChecklistItem('bag.docs', 'Mutterpass, Versichertenkarte, Personalausweis'),
    ChecklistItem(
      'bag.family',
      'Familienstammbuch bzw. Geburts-/Heiratsurkunde',
    ),
    ChecklistItem('bag.clothes', 'Bequeme Kleidung, Bademantel, Hausschuhe'),
    ChecklistItem(
      'bag.nursing',
      'Still-BH, Stilleinlagen, Wochenbett-Unterhosen',
    ),
    ChecklistItem('bag.care', 'Kulturbeutel, Haargummi, Lippenpflege'),
    ChecklistItem('bag.snacks', 'Snacks und Getränke für die Geburt'),
    ChecklistItem('bag.charger', 'Handy-Ladekabel'),
    ChecklistItem(
      'bag.baby',
      'Babykleidung für die Heimfahrt (Body, Strampler, Mütze, Jäckchen)',
    ),
    ChecklistItem('bag.seat', 'Babyschale fürs Auto (einbauen üben!)'),
  ]),
  Checklist('gear', 'Erstausstattung', [
    ChecklistItem('gear.bed', 'Beistellbett oder Babybett mit fester Matratze'),
    ChecklistItem('gear.sleep', 'Schlafsäcke (keine Decke, kein Kissen)'),
    ChecklistItem('gear.pram', 'Kinderwagen oder Trage'),
    ChecklistItem('gear.bodies', 'Bodys und Strampler (Gr. 50/56 und 62)'),
    ChecklistItem('gear.diapers', 'Windeln, Feuchttücher oder Waschlappen'),
    ChecklistItem('gear.changing', 'Wickelunterlage, Wundschutzcreme'),
    ChecklistItem('gear.bath', 'Badethermometer, Kapuzenhandtuch'),
    ChecklistItem('gear.thermo', 'Fieberthermometer'),
  ]),
  Checklist('after', 'Nach der Geburt', [
    ChecklistItem(
      'after.registry',
      'Geburt beim Standesamt anzeigen (innerhalb einer Woche; oft über die Klinik)',
    ),
    ChecklistItem('after.insurance', 'Baby bei der Krankenkasse anmelden'),
    ChecklistItem(
      'after.childbenefit',
      'Kindergeld bei der Familienkasse beantragen',
    ),
    ChecklistItem(
      'after.parentalbenefit',
      'Elterngeld beantragen (rückwirkend nur 3 Monate)',
    ),
    ChecklistItem(
      'after.employer',
      'Arbeitgeber informieren, Elternzeit anmelden (7 Wochen vorher)',
    ),
    ChecklistItem('after.u2', 'Termin für die U2 (3.–10. Lebenstag)'),
    ChecklistItem('after.midwife', 'Wochenbett-Hebamme bestätigen'),
  ]),
];

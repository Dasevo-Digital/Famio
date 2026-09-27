/// Developmental milestones with the age window (in months) in which most
/// children reach them. Orientation only – children develop at their own pace.
///
/// Gross motor windows follow the WHO Motor Development Study (2006); the
/// others are typical ranges from paediatric guidance (e.g. "Grenzsteine der
/// Entwicklung"). Never use them to diagnose anything.
enum MilestoneArea {
  motor('Bewegung'),
  fineMotor('Hände & Geschick'),
  language('Sprache'),
  social('Gefühle & Miteinander'),
  selfCare('Selbstständigkeit'),
  body('Körper');

  const MilestoneArea(this.label);

  final String label;
}

class Milestone {
  const Milestone(
    this.id,
    this.area,
    this.title,
    this.fromMonth,
    this.toMonth, [
    this.hint = '',
  ]);

  final String id;
  final MilestoneArea area;
  final String title;

  /// Window in which most children reach it, in months of age.
  final double fromMonth;
  final double toMonth;
  final String hint;
}

const milestones = <Milestone>[
  // Bewegung (WHO-Zeitfenster für die sechs großen motorischen Meilensteine)
  Milestone(
    'head_lift',
    MilestoneArea.motor,
    'Hebt in Bauchlage kurz den Kopf',
    1,
    3,
  ),
  Milestone('head_control', MilestoneArea.motor, 'Hält den Kopf sicher', 3, 5),
  Milestone(
    'roll_over',
    MilestoneArea.motor,
    'Dreht sich vom Rücken auf den Bauch',
    4,
    7,
  ),
  Milestone('sit', MilestoneArea.motor, 'Sitzt frei ohne Stütze', 4, 9),
  Milestone(
    'crawl',
    MilestoneArea.motor,
    'Krabbelt auf Händen und Knien',
    5,
    13.5,
    'Manche Kinder lassen das Krabbeln ganz aus – das ist normal.',
  ),
  Milestone(
    'stand_support',
    MilestoneArea.motor,
    'Steht mit Festhalten',
    5,
    11.5,
  ),
  Milestone('cruise', MilestoneArea.motor, 'Läuft an Möbeln entlang', 6, 14),
  Milestone('stand_alone', MilestoneArea.motor, 'Steht frei', 7, 17),
  Milestone('walk', MilestoneArea.motor, 'Erste freie Schritte', 8, 18),
  Milestone(
    'stairs',
    MilestoneArea.motor,
    'Geht Treppen mit Festhalten',
    16,
    26,
  ),
  Milestone('run', MilestoneArea.motor, 'Rennt', 18, 26),
  Milestone('jump', MilestoneArea.motor, 'Springt mit beiden Beinen', 24, 36),
  Milestone(
    'balance_bike',
    MilestoneArea.motor,
    'Fährt Laufrad oder Dreirad',
    30,
    48,
  ),
  Milestone(
    'one_leg',
    MilestoneArea.motor,
    'Steht kurz auf einem Bein',
    36,
    54,
  ),
  Milestone(
    'bike',
    MilestoneArea.motor,
    'Fährt Fahrrad ohne Stützräder',
    48,
    84,
  ),
  Milestone('swim', MilestoneArea.motor, 'Schwimmt (Seepferdchen)', 48, 96),
  // Hände & Geschick
  Milestone(
    'grasp',
    MilestoneArea.fineMotor,
    'Greift gezielt nach Dingen',
    3,
    6,
  ),
  Milestone(
    'hand_to_hand',
    MilestoneArea.fineMotor,
    'Gibt Dinge von einer Hand in die andere',
    5,
    8,
  ),
  Milestone(
    'pincer',
    MilestoneArea.fineMotor,
    'Pinzettengriff mit Daumen und Zeigefinger',
    9,
    13,
  ),
  Milestone(
    'tower',
    MilestoneArea.fineMotor,
    'Baut einen Turm aus Klötzen',
    15,
    24,
  ),
  Milestone('scribble', MilestoneArea.fineMotor, 'Kritzelt mit Stift', 12, 20),
  Milestone('circle', MilestoneArea.fineMotor, 'Malt einen Kreis', 30, 42),
  Milestone(
    'scissors',
    MilestoneArea.fineMotor,
    'Schneidet mit der Kinderschere',
    36,
    60,
  ),
  Milestone(
    'person',
    MilestoneArea.fineMotor,
    'Malt einen Menschen mit Kopf, Armen und Beinen',
    42,
    66,
  ),
  // Sprache
  Milestone('coo', MilestoneArea.language, 'Gurrt und macht Vokal-Laute', 1, 4),
  Milestone(
    'babble',
    MilestoneArea.language,
    'Brabbelt Silbenketten („ba-ba-ba“)',
    5,
    10,
  ),
  Milestone(
    'first_word',
    MilestoneArea.language,
    'Erstes Wort mit Bedeutung',
    9,
    15,
  ),
  Milestone(
    'two_words',
    MilestoneArea.language,
    'Zweiwortsätze („Mama Auto“)',
    18,
    27,
  ),
  Milestone(
    'sentences',
    MilestoneArea.language,
    'Spricht in kurzen Sätzen',
    27,
    40,
  ),
  Milestone('why', MilestoneArea.language, 'Stellt „Warum?“-Fragen', 30, 48),
  Milestone(
    'story',
    MilestoneArea.language,
    'Erzählt kleine Geschichten',
    42,
    60,
  ),
  Milestone('read', MilestoneArea.language, 'Liest erste Wörter', 60, 84),
  // Gefühle & Miteinander
  Milestone('smile', MilestoneArea.social, 'Erstes soziales Lächeln', 1, 3),
  Milestone('laugh', MilestoneArea.social, 'Lacht laut', 3, 6),
  Milestone('stranger', MilestoneArea.social, 'Fremdelt', 6, 12),
  Milestone('wave', MilestoneArea.social, 'Winkt „Tschüss“', 8, 14),
  Milestone(
    'pretend',
    MilestoneArea.social,
    'Als-ob-Spiel (füttert die Puppe)',
    18,
    30,
  ),
  Milestone(
    'play_together',
    MilestoneArea.social,
    'Spielt gemeinsam mit anderen Kindern',
    30,
    48,
  ),
  Milestone(
    'friend',
    MilestoneArea.social,
    'Hat eine beste Freundin / einen besten Freund',
    36,
    60,
  ),
  // Selbstständigkeit
  Milestone('cup', MilestoneArea.selfCare, 'Trinkt aus dem Becher', 10, 18),
  Milestone(
    'spoon',
    MilestoneArea.selfCare,
    'Isst selbst mit dem Löffel',
    15,
    24,
  ),
  Milestone('dry_day', MilestoneArea.selfCare, 'Tagsüber trocken', 24, 42),
  Milestone(
    'dry_night',
    MilestoneArea.selfCare,
    'Nachts trocken',
    30,
    72,
    'Nachts trocken zu werden dauert oft deutlich länger als tagsüber.',
  ),
  Milestone('dress', MilestoneArea.selfCare, 'Zieht sich allein an', 42, 60),
  Milestone('shoes', MilestoneArea.selfCare, 'Bindet Schuhe selbst', 60, 84),
  // Körper
  Milestone('first_tooth', MilestoneArea.body, 'Erster Zahn', 4, 12),
  Milestone(
    'sleep_through',
    MilestoneArea.body,
    'Schläft (meist) durch',
    4,
    24,
  ),
  Milestone('loose_tooth', MilestoneArea.body, 'Erster Wackelzahn', 60, 84),
];

Milestone? milestoneById(String? id) =>
    milestones.where((m) => m.id == id).firstOrNull;

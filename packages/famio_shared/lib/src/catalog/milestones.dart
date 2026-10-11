import '../texts.dart';
import 'growth_reference.dart';

/// Developmental milestones with the age window (in months) in which most
/// children reach them. Orientation only – children develop at their own pace.
///
/// Gross motor windows follow the WHO Motor Development Study (2006); the
/// others are typical ranges from paediatric guidance (e.g. "Grenzsteine der
/// Entwicklung", the CDC milestone checklists of 2022). Puberty follows the
/// usual reference ranges (AWMF guidelines on early and late puberty,
/// KiGGS for the first period). Never use them to diagnose anything.
enum MilestoneArea {
  senses('Sehen & Hören'),
  motor('Bewegung'),
  fineMotor('Hände & Geschick'),
  language('Sprache'),
  thinking('Denken & Verstehen'),
  social('Gefühle & Miteinander'),
  selfCare('Selbstständigkeit'),
  body('Körper'),
  puberty('Pubertät');

  const MilestoneArea(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('MilestoneArea.$name', _label);
}

class Milestone {
  const Milestone(
    this.id,
    this.area,
    this._title,
    this.fromMonth,
    this.toMonth, {
    this._hint = '',
    this.only,
    this.female,
    this.male,
  });

  final String id;
  final MilestoneArea area;
  final String _title;
  String get title => sharedText('Milestone|$_title', _title);

  /// Window in which most children reach it, in months of age.
  final double fromMonth;
  final double toMonth;
  final String _hint;
  String get hint => sharedText('Milestone|$_hint', _hint);

  /// Only for children of this sex (some signs of puberty); null: for all.
  final ChildSex? only;

  /// Windows (from, to) of girls and boys where they differ; a child without
  /// a recorded sex gets [fromMonth]–[toMonth], which spans both.
  final (double, double)? female;
  final (double, double)? male;

  /// This milestone with the window for a child of [sex].
  Milestone forSex(ChildSex? sex) {
    final window = switch (sex) {
      ChildSex.female => female,
      ChildSex.male => male,
      null => null,
    };
    if (window == null) return this;
    return Milestone(
      id,
      area,
      _title,
      window.$1,
      window.$2,
      hint: _hint,
      only: only,
    );
  }
}

/// The milestones of a child of [sex] (null: not recorded), with the
/// windows for that sex.
List<Milestone> milestonesFor(ChildSex? sex) => [
  for (final m in milestones)
    if (m.only == null || sex == null || m.only == sex) m.forSex(sex),
];

const milestones = <Milestone>[
  // Sehen & Hören
  Milestone(
    'faces',
    MilestoneArea.senses,
    'Schaut Gesichter aufmerksam an',
    0,
    1,
    hint: 'Neugeborene sehen in 20–30 cm Abstand am schärfsten.',
  ),
  Milestone(
    'follow_eyes',
    MilestoneArea.senses,
    'Folgt einem Gesicht mit den Augen',
    1,
    3,
  ),
  Milestone(
    'turn_to_sound',
    MilestoneArea.senses,
    'Dreht den Kopf zu Geräuschen',
    3,
    6,
  ),
  Milestone(
    'own_name',
    MilestoneArea.senses,
    'Reagiert auf den eigenen Namen',
    5,
    10,
  ),
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
    hint: 'Manche Kinder lassen das Krabbeln ganz aus – das ist normal.',
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
  Milestone(
    'forearm_support',
    MilestoneArea.motor,
    'Stützt sich in Bauchlage auf die Unterarme',
    2,
    4,
  ),
  Milestone(
    'stairs_alternate',
    MilestoneArea.motor,
    'Geht Treppen im Wechselschritt',
    30,
    48,
  ),
  Milestone(
    'catch_ball',
    MilestoneArea.motor,
    'Fängt einen großen Ball',
    36,
    54,
  ),
  Milestone('hop', MilestoneArea.motor, 'Hüpft auf einem Bein', 48, 66),
  Milestone('skip_rope', MilestoneArea.motor, 'Springt Seil', 72, 96),
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
  Milestone(
    'looks_at_hands',
    MilestoneArea.fineMotor,
    'Öffnet die Fäustchen und betrachtet die Hände',
    2,
    4,
  ),
  Milestone(
    'handedness',
    MilestoneArea.fineMotor,
    'Bevorzugt eine Hand',
    24,
    72,
    hint:
        'Ob rechts oder links, zeigt sich oft erst mit vier bis sechs Jahren sicher.',
  ),
  Milestone(
    'write_name',
    MilestoneArea.fineMotor,
    'Schreibt den eigenen Namen',
    54,
    78,
  ),
  Milestone(
    'write_sentences',
    MilestoneArea.fineMotor,
    'Schreibt Wörter und kurze Sätze',
    72,
    96,
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
  Milestone('understands_no', MilestoneArea.language, 'Versteht „Nein“', 9, 14),
  Milestone(
    'points',
    MilestoneArea.language,
    'Zeigt mit dem Finger auf Dinge',
    10,
    16,
  ),
  Milestone(
    'body_parts',
    MilestoneArea.language,
    'Zeigt auf Körperteile, wenn man fragt',
    15,
    24,
  ),
  Milestone(
    'fifty_words',
    MilestoneArea.language,
    'Spricht etwa 50 Wörter',
    18,
    24,
    hint:
        'Spricht ein Kind mit zwei Jahren deutlich weniger, bei der U7 ansprechen.',
  ),
  Milestone(
    'understood',
    MilestoneArea.language,
    'Ist auch für Fremde meist gut zu verstehen',
    30,
    48,
  ),
  Milestone(
    'all_sounds',
    MilestoneArea.language,
    'Spricht alle Laute richtig',
    48,
    72,
    hint: 'Lispeln ist bis etwa fünf Jahre oft noch normal.',
  ),
  Milestone(
    'reads_fluently',
    MilestoneArea.language,
    'Liest flüssig und versteht das Gelesene',
    84,
    108,
  ),
  // Denken & Verstehen
  Milestone(
    'object_permanence',
    MilestoneArea.thinking,
    'Sucht Dinge, die vor seinen Augen versteckt wurden',
    7,
    12,
  ),
  Milestone(
    'mirror',
    MilestoneArea.thinking,
    'Erkennt sich im Spiegel',
    15,
    24,
  ),
  Milestone('colours', MilestoneArea.thinking, 'Benennt Farben', 36, 54),
  Milestone(
    'other_minds',
    MilestoneArea.thinking,
    'Versteht, dass andere etwas anderes denken und wissen',
    42,
    60,
  ),
  Milestone('count_ten', MilestoneArea.thinking, 'Zählt bis zehn', 48, 66),
  Milestone(
    'yesterday_tomorrow',
    MilestoneArea.thinking,
    'Versteht gestern, heute und morgen',
    48,
    72,
  ),
  Milestone(
    'left_right',
    MilestoneArea.thinking,
    'Unterscheidet rechts und links',
    60,
    84,
  ),
  Milestone(
    'clock',
    MilestoneArea.thinking,
    'Liest die Uhrzeit auf einer Zeigeruhr',
    72,
    108,
  ),
  Milestone(
    'abstract',
    MilestoneArea.thinking,
    'Denkt abstrakt und in Möglichkeiten („Was wäre, wenn …“)',
    132,
    180,
  ),
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
  Milestone('peekaboo', MilestoneArea.social, 'Spielt „Kuckuck“', 6, 12),
  Milestone(
    'comforts',
    MilestoneArea.social,
    'Bemerkt, wenn andere traurig sind, und tröstet',
    18,
    30,
  ),
  Milestone(
    'takes_turns',
    MilestoneArea.social,
    'Hält sich an Spielregeln und wartet, bis es dran ist',
    42,
    66,
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
    hint: 'Nachts trocken zu werden dauert oft deutlich länger als tagsüber.',
  ),
  Milestone('dress', MilestoneArea.selfCare, 'Zieht sich allein an', 42, 60),
  Milestone('shoes', MilestoneArea.selfCare, 'Bindet Schuhe selbst', 60, 84),
  Milestone(
    'wash_hands',
    MilestoneArea.selfCare,
    'Wäscht und trocknet die Hände allein',
    30,
    54,
  ),
  Milestone(
    'brush_teeth',
    MilestoneArea.selfCare,
    'Putzt sich selbst die Zähne',
    36,
    60,
    hint:
        'Nachputzen, bis das Kind flüssig schreiben kann – etwa bis acht Jahre.',
  ),
  Milestone(
    'school_way',
    MilestoneArea.selfCare,
    'Geht allein zur Schule',
    72,
    120,
    hint:
        'Tempo und Entfernung von Autos schätzen Kinder erst mit etwa acht bis zehn Jahren sicher ein.',
  ),
  Milestone(
    'bike_traffic',
    MilestoneArea.selfCare,
    'Fährt allein mit dem Rad im Straßenverkehr',
    96,
    132,
    hint:
        'In Deutschland fahren Kinder bis acht Jahre auf dem Gehweg; die Radfahrprüfung gibt es meist in der 4. Klasse.',
  ),
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
  Milestone(
    'umbilical',
    MilestoneArea.body,
    'Nabelschnurrest fällt ab',
    0.2,
    0.7,
  ),
  Milestone(
    'birth_weight_back',
    MilestoneArea.body,
    'Hat das Geburtsgewicht wieder erreicht',
    0.25,
    0.5,
    hint: 'In den ersten Tagen nehmen Neugeborene etwas ab – das ist normal.',
  ),
  Milestone(
    'small_fontanelle',
    MilestoneArea.body,
    'Kleine Fontanelle am Hinterkopf geschlossen',
    0,
    2,
    hint: 'Oft ist sie schon bei der Geburt fast zu.',
  ),
  Milestone(
    'weight_double',
    MilestoneArea.body,
    'Geburtsgewicht verdoppelt',
    4,
    6,
  ),
  Milestone(
    'eye_colour',
    MilestoneArea.body,
    'Augenfarbe steht fest',
    6,
    12,
    hint: 'Bei manchen ändert sie sich bis ins dritte Lebensjahr.',
  ),
  Milestone(
    'big_fontanelle',
    MilestoneArea.body,
    'Große Fontanelle geschlossen',
    9,
    24,
    hint:
        'Die weiche Stelle oben am Kopf; die Kinderarztpraxis tastet sie bei den U-Untersuchungen ab.',
  ),
  Milestone(
    'weight_triple',
    MilestoneArea.body,
    'Geburtsgewicht verdreifacht',
    10,
    14,
  ),
  Milestone(
    'milk_teeth',
    MilestoneArea.body,
    'Alle 20 Milchzähne sind da',
    24,
    36,
  ),
  Milestone(
    'no_nap',
    MilestoneArea.body,
    'Braucht keinen Mittagsschlaf mehr',
    36,
    60,
  ),
  Milestone(
    'six_year_molar',
    MilestoneArea.body,
    'Erster bleibender Backenzahn (Sechsjahrmolar)',
    66,
    84,
    hint:
        'Er wächst hinter den Milchzähnen, ohne dass einer ausfällt – und wird leicht übersehen.',
  ),
  Milestone(
    'last_milk_tooth',
    MilestoneArea.body,
    'Letzter Milchzahn fällt aus',
    120,
    156,
  ),
  Milestone(
    'twelve_year_molar',
    MilestoneArea.body,
    'Zweite bleibende Backenzähne (Zwölfjahrmolaren)',
    132,
    156,
  ),
  Milestone(
    'final_height',
    MilestoneArea.body,
    'Endgröße erreicht',
    168,
    228,
    female: (168, 204),
    male: (192, 228),
    hint: 'Die Wachstumsfugen schließen sich; danach wächst man kaum noch.',
  ),
  Milestone(
    'wisdom_teeth',
    MilestoneArea.body,
    'Weisheitszähne',
    204,
    300,
    hint: 'Bei manchen kommen sie nie oder bleiben im Kiefer.',
  ),
  // Pubertät
  Milestone(
    'deodorant',
    MilestoneArea.puberty,
    'Braucht das erste Deo',
    96,
    144,
    hint:
        'Stärkerer Schweißgeruch kommt oft schon vor den sichtbaren Zeichen '
        'der Pubertät.',
  ),
  Milestone(
    'breasts',
    MilestoneArea.puberty,
    'Die Brust beginnt zu wachsen',
    96,
    156,
    only: ChildSex.female,
    hint:
        'Meist das erste sichtbare Zeichen der Pubertät. Beginnt sie vor dem '
        '8. Geburtstag oder bis zum 13. noch nicht, in der Kinderarztpraxis '
        'ansprechen.',
  ),
  Milestone(
    'growth_spurt',
    MilestoneArea.puberty,
    'Wachstumsschub der Pubertät',
    120,
    192,
    female: (120, 168),
    male: (144, 192),
    hint: 'Im stärksten Jahr wachsen viele 8 bis 10 cm.',
  ),
  Milestone(
    'first_period',
    MilestoneArea.puberty,
    'Erste Periode',
    120,
    180,
    only: ChildSex.female,
    hint: 'Meist etwa zwei Jahre nach Beginn der Brustentwicklung.',
  ),
  Milestone(
    'voice_break',
    MilestoneArea.puberty,
    'Stimmbruch',
    132,
    180,
    only: ChildSex.male,
    hint: 'Die Stimme kippt oft monatelang, bevor sie tiefer bleibt.',
  ),
  Milestone(
    'first_beard',
    MilestoneArea.puberty,
    'Erster Bartflaum',
    156,
    216,
    only: ChildSex.male,
  ),
];

Milestone? milestoneById(String? id) =>
    milestones.where((m) => m.id == id).firstOrNull;

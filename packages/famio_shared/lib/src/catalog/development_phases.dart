import '../texts.dart';
import 'growth_reference.dart';

/// Phases of development that explain what is going on rather than being
/// ticked off: what a newborn sees and hears, the autonomy phase, the stages
/// of puberty. Windows in months of age; orientation only, never a
/// diagnosis.
///
/// Senses follow paediatric guidance on vision and hearing in the first year
/// (kindergesundheit-info.de, AAP/AAO); the puberty windows follow the usual
/// reference ranges (start 8–13 years in girls, 9–14 in boys, AWMF
/// guidelines) and the common split of adolescence into early, middle and
/// late.
class DevelopmentPhase {
  const DevelopmentPhase(
    this.id,
    this._title,
    this.fromMonth,
    this.toMonth,
    this._info, {
    this.female,
    this.male,
  });

  final String id;
  final String _title;
  String get title => sharedText('Phase|$_title', _title);

  /// Typical window in months of age.
  final double fromMonth;
  final double toMonth;
  final String _info;
  String get info => sharedText('Phase|$_info', _info);

  /// Windows (from, to) of girls and boys where they differ; a child without
  /// a recorded sex gets [fromMonth]–[toMonth], which spans both.
  final (double, double)? female;
  final (double, double)? male;

  /// Whether the phase depends on the sex of the child.
  bool get bySex => female != null || male != null;

  /// This phase with the window for a child of [sex].
  DevelopmentPhase forSex(ChildSex? sex) {
    final window = switch (sex) {
      ChildSex.female => female,
      ChildSex.male => male,
      null => null,
    };
    if (window == null) return this;
    return DevelopmentPhase(id, _title, window.$1, window.$2, _info);
  }
}

/// The phases of a child of [sex] (null: not recorded), in order.
List<DevelopmentPhase> developmentPhasesFor(ChildSex? sex) => [
  for (final p in developmentPhases) p.forSex(sex),
];

const developmentPhases = <DevelopmentPhase>[
  DevelopmentPhase(
    'see_newborn',
    'Sehen: Gesichter auf Armlänge',
    0,
    2,
    'Neugeborene sehen in etwa 20 bis 30 Zentimetern Abstand am schärfsten – '
        'so weit wie bis zum Gesicht, wenn man sie im Arm hält. Alles weiter '
        'Entfernte bleibt verschwommen. Am liebsten schauen sie in Gesichter '
        'und auf starke Hell-Dunkel-Kontraste.',
  ),
  DevelopmentPhase(
    'hear_newborn',
    'Hören: von Anfang an',
    0,
    4,
    'Hören kann das Baby schon im Bauch, die Stimme der Mutter erkennt es '
        'gleich nach der Geburt wieder. Laute Geräusche erschrecken es, ruhige '
        'Stimmen beruhigen. Ab etwa drei bis vier Monaten dreht es den Kopf zu '
        'Geräuschen. Ob das Gehör gesund ist, prüft das Hörscreening in den '
        'ersten Lebenstagen.',
  ),
  DevelopmentPhase(
    'reflexes',
    'Reflexe des Neugeborenen',
    0,
    6,
    'Neugeborene greifen fest zu, wenn man ihre Handfläche berührt, suchen mit dem Mund nach der Brust und reißen bei Schreck die Arme auseinander (Moro-Reflex). Diese angeborenen Reflexe verschwinden in den ersten Monaten und machen bewussten Bewegungen Platz; die Kinderarztpraxis prüft sie bei den U-Untersuchungen.',
  ),
  DevelopmentPhase(
    'crying',
    'Viel Weinen in den ersten Wochen',
    0.5,
    4,
    'Viele Babys weinen in den ersten Wochen viel, oft am Abend. Am meisten meist um die sechste Woche, danach wird es weniger, bei den meisten bis zum dritten oder vierten Monat. Ein Baby niemals schütteln: Wenn die Nerven blank liegen, das Baby sicher ins Bettchen legen und kurz durchatmen. Hilfe gibt es in der Kinderarztpraxis und in Schreiambulanzen.',
  ),
  DevelopmentPhase(
    'see_colours',
    'Sehen: Farben, Bewegung, Tiefe',
    2,
    6,
    'Das Baby folgt Gesichtern und Spielzeug mit den Augen, beide Augen '
        'arbeiten immer besser zusammen. Farben unterscheidet es nach und '
        'nach, kräftige wie Rot zuerst. Mit etwa drei bis fünf Monaten beginnt '
        'das räumliche Sehen: Jetzt greift es gezielt nach Dingen.',
  ),
  DevelopmentPhase(
    'teething',
    'Zahnen',
    4,
    30,
    'Bis zum dritten Geburtstag kommen 20 Milchzähne, meist zuerst die unteren Schneidezähne. Sabbern, Kauen und unruhige Nächte sind häufig. Hohes Fieber oder Durchfall kommen nicht vom Zahnen und gehören ärztlich angeschaut.',
  ),
  DevelopmentPhase(
    'see_far',
    'Sehen: auch in die Ferne',
    6,
    12,
    'Vertraute Menschen erkennt das Baby jetzt auch quer durch den Raum, und '
        'es verfolgt schnelle Bewegungen. So scharf wie Erwachsene sieht ein '
        'Kind aber erst im Vorschulalter; ob beide Augen gut sehen, wird bei '
        'den U-Untersuchungen geprüft.',
  ),
  DevelopmentPhase(
    'vocabulary',
    'Wortschatzspurt',
    18,
    30,
    'Zwischen anderthalb und zweieinhalb Jahren lernen viele Kinder plötzlich jeden Tag neue Wörter und fangen an, sie zu kombinieren. Vorlesen, Bilderbücher anschauen und viel miteinander reden geben jetzt besonders viel Futter.',
  ),
  DevelopmentPhase(
    'autonomy',
    'Autonomiephase („Trotzphase“)',
    18,
    48,
    'Das Kind entdeckt seinen eigenen Willen, kann starke Gefühle aber noch '
        'kaum steuern – Wutanfälle gehören dazu und sind kein '
        'Erziehungsfehler. Ruhe, klare und liebevolle Grenzen und kleine '
        'Wahlmöglichkeiten („die rote oder die blaue Jacke?“) helfen. Meist '
        'klingt die Phase bis etwa vier Jahre ab.',
  ),
  DevelopmentPhase(
    'magic',
    'Magisches Denken',
    30,
    72,
    'Fantasie und Wirklichkeit verschwimmen: Kuscheltiere haben Gefühle, '
        'unter dem Bett kann ein Monster wohnen, und vielleicht hat der eigene '
        'Wunsch den Regen gemacht. Ängste aus dieser Welt sind echt; sie '
        'brauchen Trost, nicht den Satz „Das gibt es doch gar nicht“. '
        'Mitspielen ist erlaubt.',
  ),
  DevelopmentPhase(
    'loose_tooth',
    '„Wackelzahnpubertät“',
    60,
    84,
    'Zwischen fünf und sieben Jahren werden viele Kinder wieder launischer, '
        'widersprechen mehr und sind schnell gekränkt. Sie wollen groß sein '
        'und brauchen doch viel Nähe; der Wechsel in die Schule kostet '
        'zusätzlich Kraft. Mit der echten Pubertät hat das nichts zu tun – die '
        'Phase geht vorbei.',
  ),
  DevelopmentPhase(
    'prepuberty',
    'Vorpubertät',
    96,
    144,
    'Der Körper stellt sich hormonell um, bevor man viel davon sieht: '
        'stärkerer Schweißgeruch, fettigere Haut und Haare, '
        'Stimmungsschwankungen. Freundinnen und Freunde werden wichtiger, '
        'Eltern manchmal peinlich. Ein guter Zeitpunkt, offen über die '
        'kommenden Veränderungen zu sprechen.',
    female: (96, 132),
    male: (108, 144),
  ),
  DevelopmentPhase(
    'puberty_early',
    'Pubertät: Beginn',
    120,
    168,
    'Der Körper verändert sich sichtbar, und das Kind wächst schnell. Bei '
        'Mädchen beginnt die Pubertät meist zwischen 8 und 13, bei Jungen '
        'zwischen 9 und 14 Jahren. Viele fühlen sich jetzt unsicher im '
        'eigenen Körper und vergleichen sich ständig. Es hilft, über Periode, '
        'Stimmbruch und Gefühle zu sprechen, bevor sie da sind.',
    female: (120, 156),
    male: (132, 168),
  ),
  DevelopmentPhase(
    'puberty_middle',
    'Pubertät: Mitte',
    156,
    204,
    'Die Suche nach dem eigenen Ich steht im Vordergrund: Abgrenzung von den '
        'Eltern, Streit um Regeln, erste Liebe, Ausprobieren. Das Gehirn baut '
        'um; Gefühle sind stark, die Selbstkontrolle reift erst später. '
        'Verlässlichkeit, Interesse und Vertrauen helfen mehr als Kontrolle.',
    female: (156, 192),
    male: (168, 204),
  ),
  DevelopmentPhase(
    'puberty_late',
    'Spätpubertät',
    192,
    240,
    'Der Körper ist weitgehend erwachsen, das Denken planvoller, und das '
        'Verhältnis zu den Eltern wird ebenbürtiger. Ganz fertig ist das '
        'Gehirn noch nicht: Vor allem Planung und Selbststeuerung reifen bis '
        'Mitte zwanzig.',
    female: (192, 228),
    male: (204, 240),
  ),
  DevelopmentPhase(
    'young_adult',
    'Junge Erwachsene',
    216,
    300,
    'Mit 18 ist das Kind volljährig, die Entwicklung geht aber weiter: Ausbildung oder Studium, vielleicht der Auszug, eigene Beziehungen. Eltern werden vom Bestimmer zum Ratgeber – wenn sie gefragt werden.',
  ),
];

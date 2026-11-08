import '../sync_record.dart';
import '../texts.dart';
import 'chat.dart' show FileRef;

/// What a [ChildLog] records.
enum LogKind {
  /// Nursing on one [BreastSide]; a running timer while [ChildLog.end] is
  /// null.
  breast('Stillen'),

  /// Bottle with [ChildLog.milk] and [ChildLog.amountMl].
  bottle('Fläschchen'),
  solids('Beikost'),
  pumping('Abpumpen'),

  /// Sleep; running while [ChildLog.end] is null.
  sleep('Schlaf'),
  diaper('Windel'),
  temperature('Temperatur'),
  medication('Medikament'),
  symptom('Symptom'),
  bath('Baden'),

  /// Something to drink besides milk: [ChildLog.drink] and
  /// [ChildLog.amountMl].
  drink('Getränk'),

  /// Time outdoors; running while [ChildLog.end] is null.
  walk('Spaziergang');

  const LogKind(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('LogKind.$name', _label);

  /// Kinds measured as a duration (start/stop).
  bool get timed => this == breast || this == sleep || this == walk;
}

enum BreastSide {
  left('links'),
  right('rechts');

  const BreastSide(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('BreastSide.$name', _label);
}

enum MilkKind {
  breastMilk('Muttermilch'),
  formula('Pre-Milch'),
  other('Andere');

  const MilkKind(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('MilkKind.$name', _label);
}

enum DiaperKind {
  wet('Pipi'),
  dirty('Kacka'),
  both('Pipi + Kacka');

  const DiaperKind(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('DiaperKind.$name', _label);

  /// The diaper had stool in it, so [ChildLog.stool] may describe it.
  bool get poo => this != wet;
}

/// How the stool in a diaper looked, from hard to watery (the four
/// consistencies of the Amsterdam Infant Stool Scale).
enum StoolKind {
  hard('hart'),
  formed('geformt'),
  soft('breiig'),
  watery('Durchfall');

  const StoolKind(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('StoolKind.$name', _label);
}

/// What a [LogKind.drink] entry was.
enum DrinkKind {
  water('Wasser'),
  tea('Tee'),
  juice('Saft'),
  milk('Milch'),
  other('Anderes');

  const DrinkKind(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('DrinkKind.$name', _label);
}

/// The colour of the stool. Pale (whitish, grey, clay) is listed because
/// the stool colour card of the child health booklet asks about it.
enum StoolColor {
  yellow('gelb', 0xFFE3B21C),
  green('grün', 0xFF6E8F2C),
  brown('braun', 0xFF7A4A28),
  black('schwarz', 0xFF1F1B1A),
  red('rot', 0xFFC62828),
  pale('weißlich/grau', 0xFFDAD5C8);

  const StoolColor(this._label, this.argb);

  final String _label;

  /// The swatch shown next to the label.
  final int argb;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('StoolColor.$name', _label);
}

/// How much stool there was.
enum StoolAmount {
  little('wenig'),
  normal('normal'),
  much('viel');

  const StoolAmount(this._label);

  final String _label;

  /// The label in the language of [sharedTexts].
  String get label => sharedText('StoolAmount.$name', _label);
}

/// One entry of a child's daily log (feeding, sleep, diaper, fever …),
/// stored in `Collections.childLogs`. Health data: visible to the child's
/// guardians like the other child records.
class ChildLog {
  const ChildLog({
    required this.id,
    required this.childId,
    required this.kind,
    required this.start,
    this.end,
    this.side,
    this.milk,
    this.amountMl,
    this.drink,
    this.diaper,
    this.stool,
    this.stoolColor,
    this.stoolAmount,
    this.temperatureC,
    this.medication = '',
    this.dose = '',
    this.minIntervalHours,
    this.symptom = '',
    this.note = '',
    this.remindAt,
    this.photos = const [],
    this.by,
  });

  factory ChildLog.fromRecord(SyncRecord r) {
    T? pick<T extends Enum>(List<T> values, Object? name) =>
        values.where((v) => v.name == name).firstOrNull;
    return ChildLog(
      id: r.id,
      childId: r.data['childId'] as String? ?? '',
      kind: pick(LogKind.values, r.data['kind']) ?? LogKind.symptom,
      start: _time(r.data['start']) ?? DateTime(2000),
      end: _time(r.data['end']),
      side: pick(BreastSide.values, r.data['side']),
      milk: pick(MilkKind.values, r.data['milk']),
      amountMl: (r.data['amountMl'] as num?)?.toInt(),
      drink: pick(DrinkKind.values, r.data['drink']),
      diaper: pick(DiaperKind.values, r.data['diaper']),
      stool: pick(StoolKind.values, r.data['stool']),
      stoolColor: pick(StoolColor.values, r.data['stoolColor']),
      stoolAmount: pick(StoolAmount.values, r.data['stoolAmount']),
      temperatureC: (r.data['temperatureC'] as num?)?.toDouble(),
      medication: r.data['medication'] as String? ?? '',
      dose: r.data['dose'] as String? ?? '',
      minIntervalHours: (r.data['minIntervalHours'] as num?)?.toDouble(),
      symptom: r.data['symptom'] as String? ?? '',
      note: r.data['note'] as String? ?? '',
      remindAt: _time(r.data['remindAt']),
      photos: [
        for (final f in r.data['photos'] as List? ?? const [])
          ?FileRef.fromJson(f),
      ],
      by: r.data['by'] as String?,
    );
  }

  final String id;
  final String childId;
  final LogKind kind;
  final DateTime start;

  /// End of a timed entry; null while the timer runs.
  final DateTime? end;
  final BreastSide? side;
  final MilkKind? milk;
  final int? amountMl;
  final DrinkKind? drink;
  final DiaperKind? diaper;

  /// How the stool looked; only for diapers with stool, null when nobody
  /// said.
  final StoolKind? stool;
  final StoolColor? stoolColor;
  final StoolAmount? stoolAmount;
  final double? temperatureC;

  /// Name of the medicine and the dose as given by doctor or leaflet;
  /// Famio never suggests doses.
  final String medication;
  final String dose;

  /// Minimum hours until the next dose of the same medicine (from doctor or
  /// leaflet), for the "next dose not before" hint and reminder.
  final double? minIntervalHours;
  final String symptom;
  final String note;

  /// Reminder for the guardians (next feeding, next dose possible).
  final DateTime? remindAt;

  /// Photos, e.g. of a rash or of the stool, to show the doctor.
  final List<FileRef> photos;

  /// Member who logged it.
  final String? by;

  bool get running => kind.timed && end == null;

  /// Duration of a timed entry (up to [now] while running).
  Duration duration([DateTime? now]) => kind.timed
      ? (end ?? now ?? DateTime.now()).difference(start)
      : Duration.zero;

  ChildLog copyWith({
    DateTime? start,
    DateTime? end,
    bool clearEnd = false,
    BreastSide? side,
    MilkKind? milk,
    int? amountMl,
    DrinkKind? drink,
    DiaperKind? diaper,
    StoolKind? stool,
    bool clearStool = false,
    StoolColor? stoolColor,
    StoolAmount? stoolAmount,
    double? temperatureC,
    String? medication,
    String? dose,
    double? minIntervalHours,
    String? symptom,
    String? note,
    DateTime? remindAt,
    bool clearRemind = false,
    List<FileRef>? photos,
  }) => ChildLog(
    id: id,
    childId: childId,
    kind: kind,
    start: start ?? this.start,
    end: clearEnd ? null : end ?? this.end,
    side: side ?? this.side,
    milk: milk ?? this.milk,
    amountMl: amountMl ?? this.amountMl,
    drink: drink ?? this.drink,
    diaper: diaper ?? this.diaper,
    stool: clearStool ? null : stool ?? this.stool,
    stoolColor: clearStool ? null : stoolColor ?? this.stoolColor,
    stoolAmount: clearStool ? null : stoolAmount ?? this.stoolAmount,
    temperatureC: temperatureC ?? this.temperatureC,
    medication: medication ?? this.medication,
    dose: dose ?? this.dose,
    minIntervalHours: minIntervalHours ?? this.minIntervalHours,
    symptom: symptom ?? this.symptom,
    note: note ?? this.note,
    remindAt: clearRemind ? null : remindAt ?? this.remindAt,
    photos: photos ?? this.photos,
    by: by,
  );

  Map<String, Object?> toData() => {
    'childId': childId,
    'kind': kind.name,
    'start': _iso(start),
    'end': ?_iso(end),
    'side': ?side?.name,
    'milk': ?milk?.name,
    'amountMl': ?amountMl,
    'drink': ?drink?.name,
    'diaper': ?diaper?.name,
    'stool': ?stool?.name,
    'stoolColor': ?stoolColor?.name,
    'stoolAmount': ?stoolAmount?.name,
    'temperatureC': ?temperatureC,
    if (medication.isNotEmpty) 'medication': medication,
    if (dose.isNotEmpty) 'dose': dose,
    'minIntervalHours': ?minIntervalHours,
    if (symptom.isNotEmpty) 'symptom': symptom,
    if (note.isNotEmpty) 'note': note,
    'remindAt': ?_iso(remindAt),
    if (photos.isNotEmpty) 'photos': [for (final f in photos) f.toJson()],
    'by': ?by,
  };
}

DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();

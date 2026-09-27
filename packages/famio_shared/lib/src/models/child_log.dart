import '../sync_record.dart';

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
  bath('Baden');

  const LogKind(this.label);

  final String label;

  /// Kinds measured as a duration (start/stop).
  bool get timed => this == breast || this == sleep;
}

enum BreastSide {
  left('links'),
  right('rechts');

  const BreastSide(this.label);

  final String label;
}

enum MilkKind {
  breastMilk('Muttermilch'),
  formula('Pre-Milch'),
  other('Andere');

  const MilkKind(this.label);

  final String label;
}

enum DiaperKind {
  wet('nass'),
  dirty('voll'),
  both('nass + voll');

  const DiaperKind(this.label);

  final String label;
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
    this.diaper,
    this.temperatureC,
    this.medication = '',
    this.dose = '',
    this.minIntervalHours,
    this.symptom = '',
    this.note = '',
    this.remindAt,
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
      diaper: pick(DiaperKind.values, r.data['diaper']),
      temperatureC: (r.data['temperatureC'] as num?)?.toDouble(),
      medication: r.data['medication'] as String? ?? '',
      dose: r.data['dose'] as String? ?? '',
      minIntervalHours: (r.data['minIntervalHours'] as num?)?.toDouble(),
      symptom: r.data['symptom'] as String? ?? '',
      note: r.data['note'] as String? ?? '',
      remindAt: _time(r.data['remindAt']),
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
  final DiaperKind? diaper;
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
    DiaperKind? diaper,
    double? temperatureC,
    String? medication,
    String? dose,
    double? minIntervalHours,
    String? symptom,
    String? note,
    DateTime? remindAt,
    bool clearRemind = false,
  }) => ChildLog(
    id: id,
    childId: childId,
    kind: kind,
    start: start ?? this.start,
    end: clearEnd ? null : end ?? this.end,
    side: side ?? this.side,
    milk: milk ?? this.milk,
    amountMl: amountMl ?? this.amountMl,
    diaper: diaper ?? this.diaper,
    temperatureC: temperatureC ?? this.temperatureC,
    medication: medication ?? this.medication,
    dose: dose ?? this.dose,
    minIntervalHours: minIntervalHours ?? this.minIntervalHours,
    symptom: symptom ?? this.symptom,
    note: note ?? this.note,
    remindAt: clearRemind ? null : remindAt ?? this.remindAt,
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
    'diaper': ?diaper?.name,
    'temperatureC': ?temperatureC,
    if (medication.isNotEmpty) 'medication': medication,
    if (dose.isNotEmpty) 'dose': dose,
    'minIntervalHours': ?minIntervalHours,
    if (symptom.isNotEmpty) 'symptom': symptom,
    if (note.isNotEmpty) 'note': note,
    'remindAt': ?_iso(remindAt),
    'by': ?by,
  };
}

DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();

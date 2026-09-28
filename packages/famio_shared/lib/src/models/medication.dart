import '../sync_record.dart';

/// A medication plan (`Collections.medications`): what, when, for whom and
/// how much is left. Famio never suggests doses – [dose] is whatever the
/// doctor or package insert says, typed in by the family.
///
/// Health data: only [careIds] see it (enforced by the server via
/// `visibleTo`) and get its reminders.
class Medication {
  const Medication({
    required this.id,
    required this.name,
    this.personName = '',
    this.dose = '',
    this.perDose = 1,
    this.times = const [],
    this.weekdays = const {},
    required this.start,
    this.end,
    this.stock,
    this.stockAt,
    this.refillDays = 7,
    this.notes = '',
    this.careIds = const [],
    this.asNeeded = false,
  });

  factory Medication.fromRecord(SyncRecord r) => Medication(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    personName: r.data['personName'] as String? ?? '',
    dose: r.data['dose'] as String? ?? '',
    perDose: (r.data['perDose'] as num?)?.toDouble() ?? 1,
    times: [for (final t in r.data['times'] as List? ?? []) t as String],
    weekdays: {
      for (final d in r.data['weekdays'] as List? ?? []) (d as num).toInt(),
    },
    start: _day(r.data['start']) ?? DateTime(2026),
    end: _day(r.data['end']),
    stock: (r.data['stock'] as num?)?.toDouble(),
    stockAt: DateTime.tryParse(r.data['stockAt'] as String? ?? '')?.toLocal(),
    refillDays: (r.data['refillDays'] as num?)?.toInt() ?? 7,
    notes: r.data['notes'] as String? ?? '',
    careIds: [for (final m in r.data['careIds'] as List? ?? []) m as String],
    asNeeded: r.data['asNeeded'] as bool? ?? false,
  );

  final String id;
  final String name;

  /// Who takes it ("Mia", "Oma").
  final String personName;

  /// As prescribed, e.g. "1 Tablette" – free text.
  final String dose;

  /// Units taken from [stock] per intake.
  final double perDose;

  /// `HH:mm` of the intakes; empty with [asNeeded].
  final List<String> times;

  /// 1 = Monday; empty means every day.
  final Set<int> weekdays;
  final DateTime start;

  /// Last day, inclusive; null while ongoing.
  final DateTime? end;

  /// Units in stock when counted at [stockAt]; null = not tracked.
  final double? stock;
  final DateTime? stockAt;

  /// Warn this many days before the stock runs out.
  final int refillDays;
  final String notes;

  /// Members who see the plan and are reminded.
  final List<String> careIds;

  /// Only when needed (no schedule, no reminders).
  final bool asNeeded;

  bool activeOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    if (d.isBefore(start)) return false;
    if (end != null && d.isAfter(end!)) return false;
    return weekdays.isEmpty || weekdays.contains(day.weekday);
  }

  /// Scheduled intakes on [day], in time order.
  List<DateTime> dosesOn(DateTime day) {
    if (asNeeded || !activeOn(day)) return const [];
    return [
      for (final t in times) ?_time(day, t),
    ]..sort();
  }

  /// Units left after [taken] intakes since [stockAt]; null if untracked.
  double? left(int taken) => stock == null ? null : stock! - taken * perDose;

  /// Units used per week by the plan.
  double get weeklyUse => asNeeded
      ? 0
      : times.length * perDose * (weekdays.isEmpty ? 7 : weekdays.length);

  /// Days the rest lasts; null if untracked or not scheduled.
  int? daysLeft(int taken) {
    final rest = left(taken);
    if (rest == null || weeklyUse == 0) return null;
    return (rest / (weeklyUse / 7)).floor().clamp(0, 99999);
  }

  /// Id of the intake record of the dose at [at].
  String intakeId(DateTime at) =>
      'mi-$id-${at.year}${_two(at.month)}${_two(at.day)}${_two(at.hour)}${_two(at.minute)}';

  Map<String, Object?> toData() => {
    'name': name,
    'personName': personName,
    'dose': dose,
    'perDose': perDose,
    'times': times,
    'weekdays': weekdays.toList()..sort(),
    'start': _key(start),
    'end': end == null ? null : _key(end!),
    'stock': stock,
    'stockAt': stockAt?.toUtc().toIso8601String(),
    'refillDays': refillDays,
    'notes': notes,
    'careIds': careIds,
    'asNeeded': asNeeded,
    SyncRecord.visibilityKey: careIds.isEmpty ? null : careIds,
  };
}

/// A dose taken (or skipped), in `Collections.medicationIntakes`, with the
/// plan's audience.
class MedicationIntake {
  const MedicationIntake({
    required this.id,
    required this.medicationId,
    required this.at,
    required this.byId,
    this.scheduled,
    this.skipped = false,
  });

  factory MedicationIntake.fromRecord(SyncRecord r) => MedicationIntake(
    id: r.id,
    medicationId: r.data['medicationId'] as String? ?? '',
    at:
        DateTime.tryParse(r.data['at'] as String? ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(r.updatedAt),
    byId: r.data['byId'] as String? ?? r.updatedBy ?? '',
    scheduled: DateTime.tryParse(
      r.data['scheduled'] as String? ?? '',
    )?.toLocal(),
    skipped: r.data['skipped'] as bool? ?? false,
  );

  final String id;
  final String medicationId;

  /// When it was taken (or marked skipped).
  final DateTime at;
  final String byId;

  /// The planned time; null for as-needed doses.
  final DateTime? scheduled;
  final bool skipped;

  Map<String, Object?> toData({List<String>? visibleTo}) => {
    'medicationId': medicationId,
    'at': at.toUtc().toIso8601String(),
    'byId': byId,
    'scheduled': scheduled?.toUtc().toIso8601String(),
    'skipped': skipped,
    SyncRecord.visibilityKey: visibleTo,
  };
}

String _two(int n) => n.toString().padLeft(2, '0');

String _key(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

DateTime? _time(DateTime day, String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
  if (h == null || m == null || h > 23 || m > 59) return null;
  return DateTime(day.year, day.month, day.day, h, m);
}

DateTime? _day(Object? v) {
  if (v is! String) return null;
  final d = DateTime.tryParse(v);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

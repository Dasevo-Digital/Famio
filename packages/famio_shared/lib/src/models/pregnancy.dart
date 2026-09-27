import '../sync_record.dart';

/// A pregnancy followed by the family, stored in `Collections.pregnancies`.
/// Health data: visible to [guardianIds] only (like children).
class Pregnancy {
  const Pregnancy({
    required this.id,
    required this.dueDate,
    this.name = '',
    this.motherId,
    this.guardianIds = const [],
    this.done = const {},
    this.contractions = const [],
    this.childId,
    this.note = '',
  });

  factory Pregnancy.fromRecord(SyncRecord r) => Pregnancy(
    id: r.id,
    dueDate: _date(r.data['dueDate']) ?? DateTime(2000),
    name: r.data['name'] as String? ?? '',
    motherId: r.data['motherId'] as String?,
    guardianIds: [
      for (final g in r.data['guardianIds'] as List? ?? const []) g as String,
    ],
    done: {for (final d in r.data['done'] as List? ?? const []) d as String},
    contractions: [
      for (final c in r.data['contractions'] as List? ?? const [])
        Contraction.fromJson((c as Map).cast()),
    ],
    childId: r.data['childId'] as String?,
    note: r.data['note'] as String? ?? '',
  );

  final String id;

  /// Estimated date of delivery (ET).
  final DateTime dueDate;

  /// Working title of the baby, e.g. "Krümel".
  final String name;
  final String? motherId;

  /// Members who see it; empty means everyone.
  final List<String> guardianIds;

  /// Ids of done appointments and checklist items.
  final Set<String> done;

  /// Timed contractions, oldest first.
  final List<Contraction> contractions;

  /// The child once the baby is born.
  final String? childId;
  final String note;

  bool get born => childId != null;

  /// First day of the last period, from which weeks are counted.
  DateTime get start =>
      DateTime(dueDate.year, dueDate.month, dueDate.day - 280);

  /// Completed weeks and days ("24+3") on [at].
  (int weeks, int days) weekOn(DateTime at) {
    // In UTC: a day across a DST change has 23 or 25 hours locally.
    final d = DateTime.utc(
      at.year,
      at.month,
      at.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    return d < 0 ? (0, 0) : (d ~/ 7, d % 7);
  }

  /// The day at [weeks]+[days].
  DateTime dayOf(int weeks, [int days = 0]) =>
      DateTime(start.year, start.month, start.day + weeks * 7 + days);

  Pregnancy copyWith({
    DateTime? dueDate,
    String? name,
    String? motherId,
    List<String>? guardianIds,
    Set<String>? done,
    List<Contraction>? contractions,
    String? childId,
    String? note,
  }) => Pregnancy(
    id: id,
    dueDate: dueDate ?? this.dueDate,
    name: name ?? this.name,
    motherId: motherId ?? this.motherId,
    guardianIds: guardianIds ?? this.guardianIds,
    done: done ?? this.done,
    contractions: contractions ?? this.contractions,
    childId: childId ?? this.childId,
    note: note ?? this.note,
  );

  Map<String, Object?> toData() => {
    'dueDate': _day(dueDate),
    'name': name,
    'motherId': motherId,
    'guardianIds': guardianIds,
    'done': done.toList()..sort(),
    'contractions': [for (final c in contractions) c.toJson()],
    'childId': childId,
    'note': note,
  };
}

class Contraction {
  const Contraction(this.start, [this.end]);

  factory Contraction.fromJson(Map<String, Object?> json) => Contraction(
    DateTime.fromMillisecondsSinceEpoch((json['s'] as num).toInt()),
    json['e'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((json['e'] as num).toInt()),
  );

  final DateTime start;
  final DateTime? end;

  Duration? get length => end?.difference(start);

  Map<String, Object?> toJson() => {
    's': start.millisecondsSinceEpoch,
    'e': ?end?.millisecondsSinceEpoch,
  };
}

DateTime? _date(Object? v) {
  final d = v is String ? DateTime.tryParse(v) : null;
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

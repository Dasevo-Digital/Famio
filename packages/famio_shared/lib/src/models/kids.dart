import '../catalog/growth_reference.dart';
import '../sync_record.dart';
import 'chat.dart';

/// A child followed in the development timeline, stored in
/// `Collections.children`. Children need no account of their own.
class Child {
  const Child({
    required this.id,
    required this.name,
    required this.birthDate,
    this.color,
    this.photo,
    this.guardianIds = const [],
    this.sex,
    this.emergency = const EmergencyInfo(),
  });

  factory Child.fromRecord(SyncRecord r) => Child(
    id: r.id,
    name: r.data['name'] as String? ?? '',
    birthDate: _date(r.data['birthDate']) ?? DateTime(2000),
    color: r.data['color'] as int?,
    photo: FileRef.fromJson(r.data['photo']),
    guardianIds: [
      for (final g in r.data['guardianIds'] as List? ?? const []) g as String,
    ],
    sex: ChildSex.values.where((v) => v.name == r.data['sex']).firstOrNull,
    emergency: EmergencyInfo.fromJson(r.data['emergency']),
  );

  final String id;
  final String name;
  final DateTime birthDate;
  final int? color;
  final FileRef? photo;

  /// Members reminded of check-ups and vaccinations; empty means everyone.
  final List<String> guardianIds;

  /// For the WHO growth percentiles; unknown shows no percentiles.
  final ChildSex? sex;

  /// Shown on the emergency page (offline).
  final EmergencyInfo emergency;

  /// The date [months] after birth (day clamped to the month's length).
  DateTime ageDate(num months) {
    final whole = months.floor();
    final base = DateTime(birthDate.year, birthDate.month + whole);
    final lastDay = DateTime(base.year, base.month + 1, 0).day;
    final date = DateTime(
      base.year,
      base.month,
      birthDate.day.clamp(1, lastDay),
    );
    final fraction = months - whole;
    return fraction == 0
        ? date
        : date.add(Duration(days: (fraction * 30.4).round()));
  }

  /// Completed months of age at [at].
  int ageInMonths(DateTime at) {
    var months = (at.year - birthDate.year) * 12 + at.month - birthDate.month;
    if (at.day < birthDate.day) months--;
    return months < 0 ? 0 : months;
  }

  Map<String, Object?> toData() => {
    'name': name,
    'birthDate': _day(birthDate),
    'color': color,
    'photo': photo?.toJson(),
    'guardianIds': guardianIds,
    'sex': sex?.name,
    'emergency': emergency.toJson(),
  };
}

/// What helpers need in an emergency: allergies, illnesses, medicines,
/// blood group, insurance and the pediatrician.
class EmergencyInfo {
  const EmergencyInfo({
    this.bloodType = '',
    this.allergies = '',
    this.conditions = '',
    this.medications = '',
    this.insurance = '',
    this.insuranceNumber = '',
    this.doctorContactId,
    this.note = '',
  });

  factory EmergencyInfo.fromJson(Object? json) {
    if (json is! Map) return const EmergencyInfo();
    String text(String key) => json[key] as String? ?? '';
    return EmergencyInfo(
      bloodType: text('bloodType'),
      allergies: text('allergies'),
      conditions: text('conditions'),
      medications: text('medications'),
      insurance: text('insurance'),
      insuranceNumber: text('insuranceNumber'),
      doctorContactId: json['doctorContactId'] as String?,
      note: text('note'),
    );
  }

  final String bloodType;
  final String allergies;

  /// Chronic illnesses, e.g. asthma, epilepsy, heart defect.
  final String conditions;

  /// Regular medicines.
  final String medications;
  final String insurance;
  final String insuranceNumber;

  /// The pediatrician in `Collections.contacts`.
  final String? doctorContactId;
  final String note;

  bool get isEmpty =>
      bloodType.isEmpty &&
      allergies.isEmpty &&
      conditions.isEmpty &&
      medications.isEmpty &&
      insurance.isEmpty &&
      insuranceNumber.isEmpty &&
      doctorContactId == null &&
      note.isEmpty;

  Map<String, Object?> toJson() => {
    'bloodType': bloodType,
    'allergies': allergies,
    'conditions': conditions,
    'medications': medications,
    'insurance': insurance,
    'insuranceNumber': insuranceNumber,
    'doctorContactId': doctorContactId,
    'note': note,
  };
}

enum ChildEntryKind { milestone, memory, measurement, checkup, vaccination }

/// Something that happened, stored in `Collections.childEntries`: a reached
/// milestone, a memory, a measurement, a done check-up or vaccination.
class ChildEntry {
  const ChildEntry({
    required this.id,
    required this.childId,
    required this.kind,
    required this.date,
    this.refId,
    this.title = '',
    this.note = '',
    this.photos = const [],
    this.heightCm,
    this.weightKg,
    this.headCm,
    this.dateUnknown = false,
  });

  factory ChildEntry.fromRecord(SyncRecord r) => ChildEntry(
    id: r.id,
    childId: r.data['childId'] as String? ?? '',
    kind:
        ChildEntryKind.values
            .where((k) => k.name == r.data['kind'])
            .firstOrNull ??
        ChildEntryKind.memory,
    date: _date(r.data['date']) ?? DateTime(2000),
    refId: r.data['refId'] as String?,
    title: r.data['title'] as String? ?? '',
    note: r.data['note'] as String? ?? '',
    photos: [
      for (final p in r.data['photos'] as List? ?? const [])
        ?FileRef.fromJson(p),
    ],
    heightCm: (r.data['heightCm'] as num?)?.toDouble(),
    weightKg: (r.data['weightKg'] as num?)?.toDouble(),
    headCm: (r.data['headCm'] as num?)?.toDouble(),
    dateUnknown: r.data['dateUnknown'] as bool? ?? false,
  );

  final String id;
  final String childId;
  final ChildEntryKind kind;
  final DateTime date;

  /// Catalog id for milestones, check-ups and vaccinations.
  final String? refId;
  final String title;
  final String note;
  final List<FileRef> photos;
  final double? heightCm;
  final double? weightKg;
  final double? headCm;

  /// Recorded afterwards without knowing the day (e.g. older check-ups);
  /// [date] then holds the recommended date.
  final bool dateUnknown;

  Map<String, Object?> toData() => {
    'childId': childId,
    'kind': kind.name,
    'date': _day(date),
    'refId': refId,
    'title': title,
    'note': note,
    'photos': [for (final p in photos) p.toJson()],
    'heightCm': heightCm,
    'weightKg': weightKg,
    'headCm': headCm,
    if (dateUnknown) 'dateUnknown': true,
  };
}

DateTime? _date(Object? v) {
  final d = v is String ? DateTime.tryParse(v) : null;
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
